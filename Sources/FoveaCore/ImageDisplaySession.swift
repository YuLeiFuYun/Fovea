import Foundation
import ImageCraftCore

package enum ImageDisplayRetention: Sendable {
    case clearImmediately
    case retainSuccessfulImageUntilReplacement
}

package enum ImageDisplaySessionPhase: Sendable {
    case empty
    case loading
    case preview(DecodedImage)
    case success(DecodedImage)
    case failure(PipelineFailure)
    case cancelled
}

/// 在所有 UI 适配器之间共享请求身份、渐进质量和迟到结果拒绝规则。
/// 该类型不持有平台视图，也不创建非结构化加载任务；具体视图负责其任务生命周期。
@MainActor
package final class ImageDisplaySession {
    package private(set) var phase: ImageDisplaySessionPhase = .empty
    package private(set) var requestGeneration = UUID()

    private var activeIdentity: String?
    private var latestPreviewQuality: UInt16?

    package init() {}

    package func isCurrentIdentity(_ identity: String) -> Bool {
        activeIdentity == identity
    }

    package func load(
        request: ImageRequest,
        loader: any ImageLoading,
        placeholderDelayNanoseconds: UInt64,
        retention: ImageDisplayRetention,
        force: Bool = false,
        onChange: @escaping @MainActor (ImageDisplaySessionPhase) -> Void
    ) async {
        let identity = request.displayIdentity
        guard shouldStart(identity: identity, force: force) else { return }

        let generation = beginLoad(
            identity: identity,
            retention: retention,
            showsLoadingImmediately: placeholderDelayNanoseconds == 0,
            onChange: onChange
        )
        let loadingIndicator = makeLoadingIndicator(
            delayNanoseconds: placeholderDelayNanoseconds,
            generation: generation,
            identity: identity,
            onChange: onChange
        )
        defer { loadingIndicator?.cancel() }

        do {
            try await performLoad(
                request: request,
                loader: loader,
                generation: generation,
                identity: identity,
                onChange: onChange
            )
        } catch {
            guard isCurrent(generation: generation, identity: identity) else { return }
            publish(phase(for: error), onChange: onChange)
        }
    }

    package func prepareForIdentityChange(
        to identity: String,
        retention: ImageDisplayRetention,
        onChange: @escaping @MainActor (ImageDisplaySessionPhase) -> Void
    ) {
        guard activeIdentity != identity else { return }
        requestGeneration = UUID()
        activeIdentity = nil
        latestPreviewQuality = nil
        if retention == .clearImmediately || !isSuccessful {
            publish(.empty, onChange: onChange)
        }
    }

    package func invalidate(
        clear: Bool = true,
        onChange: @escaping @MainActor (ImageDisplaySessionPhase) -> Void
    ) {
        requestGeneration = UUID()
        activeIdentity = nil
        latestPreviewQuality = nil
        if clear { publish(.empty, onChange: onChange) }
    }

    private func shouldStart(identity: String, force: Bool) -> Bool {
        guard !force, activeIdentity == identity else { return true }
        if case .cancelled = phase {
            // 视图离开层级导致的取消必须允许同一身份在重新出现时恢复加载。
            return true
        }
        return false
    }

    private func beginLoad(
        identity: String,
        retention: ImageDisplayRetention,
        showsLoadingImmediately: Bool,
        onChange: @escaping @MainActor (ImageDisplaySessionPhase) -> Void
    ) -> UUID {
        requestGeneration = UUID()
        activeIdentity = identity
        latestPreviewQuality = nil
        if retention == .clearImmediately || !isSuccessful {
            publish(showsLoadingImmediately ? .loading : .empty, onChange: onChange)
        }
        return requestGeneration
    }

    private func makeLoadingIndicator(
        delayNanoseconds: UInt64,
        generation: UUID,
        identity: String,
        onChange: @escaping @MainActor (ImageDisplaySessionPhase) -> Void
    ) -> Task<Void, Never>? {
        guard delayNanoseconds > 0 else { return nil }
        return Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            self?.showLoading(generation: generation, identity: identity, onChange: onChange)
        }
    }

    private func performLoad(
        request: ImageRequest,
        loader: any ImageLoading,
        generation: UUID,
        identity: String,
        onChange: @escaping @MainActor (ImageDisplaySessionPhase) -> Void
    ) async throws {
        if let progressive = loader as? any ProgressiveImageLoading {
            try await consume(
                progressive.events(for: request),
                generation: generation,
                identity: identity,
                onChange: onChange
            )
            return
        }

        let image = try await loader.image(for: request)
        guard isCurrent(generation: generation, identity: identity) else { return }
        publish(.success(image), onChange: onChange)
    }

    private func phase(for error: any Error) -> ImageDisplaySessionPhase {
        if let failure = error as? PipelineFailure {
            return failure.disposition == .cancelled ? .cancelled : .failure(failure)
        }
        if error is CancellationError {
            return .cancelled
        }
        return .failure(
            PipelineFailure(
                category: .internalFailure,
                stage: .pipeline,
                disposition: .terminal,
                reasonCode: "unexpected-ui-error"
            )
        )
    }

    private func consume(
        _ events: AsyncThrowingStream<ImageLoadingEvent, Error>,
        generation: UUID,
        identity: String,
        onChange: @escaping @MainActor (ImageDisplaySessionPhase) -> Void
    ) async throws {
        for try await event in events {
            try Task.checkCancellation()
            guard isCurrent(generation: generation, identity: identity) else { return }
            switch event {
            case .preview(let image, let quality):
                guard latestPreviewQuality.map({ quality > $0 }) ?? true else { continue }
                latestPreviewQuality = quality
                publish(.preview(image), onChange: onChange)
            case .final(let image):
                latestPreviewQuality = nil
                publish(.success(image), onChange: onChange)
                return
            }
        }
        throw PipelineFailure.incompleteProgressiveStream
    }

    private var isSuccessful: Bool {
        if case .success = phase { return true }
        return false
    }

    private func isCurrent(generation: UUID, identity: String) -> Bool {
        requestGeneration == generation && activeIdentity == identity
    }

    private func showLoading(
        generation: UUID,
        identity: String,
        onChange: @escaping @MainActor (ImageDisplaySessionPhase) -> Void
    ) {
        guard isCurrent(generation: generation, identity: identity) else { return }
        if case .empty = phase { publish(.loading, onChange: onChange) }
    }

    private func publish(
        _ next: ImageDisplaySessionPhase,
        onChange: @escaping @MainActor (ImageDisplaySessionPhase) -> Void
    ) {
        guard !Self.hasSamePayloadFreePhase(phase, next) else { return }
        phase = next
        onChange(next)
    }

    private static func hasSamePayloadFreePhase(
        _ lhs: ImageDisplaySessionPhase,
        _ rhs: ImageDisplaySessionPhase
    ) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty), (.loading, .loading), (.cancelled, .cancelled):
            true
        default:
            false
        }
    }
}
