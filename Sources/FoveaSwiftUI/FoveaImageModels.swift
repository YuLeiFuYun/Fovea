import FoveaCore
import ImageCraftCore
import SwiftUI

/// 把核心显示会话的状态机桥接为 SwiftUI 可观察状态。
/// 请求身份、显式 loadToken 与保留策略共同决定是否重载；视图重绘本身不得重复取图。
@MainActor
package final class FoveaImageModel: ObservableObject {
    @Published package private(set) var phase: FoveaImagePhase = .empty
    package var requestGeneration: UUID { session.requestGeneration }

    private let session = ImageDisplaySession()
    private var lastLoadToken: UUID?

    package init() {}

    package func load(
        request: ImageRequest,
        loader: any ImageLoading,
        policy: FoveaImageLoadingPolicy = .default,
        loadToken: UUID? = nil,
        force: Bool = false
    ) async {
        let tokenForcesReload: Bool
        if let loadToken {
            tokenForcesReload = lastLoadToken != nil && lastLoadToken != loadToken
            lastLoadToken = loadToken
        } else {
            tokenForcesReload = false
        }
        await session.load(
            request: request,
            loader: loader,
            placeholderDelayNanoseconds: policy.placeholderDelayNanoseconds,
            retention: policy.retention.coreRetention,
            force: force || tokenForcesReload
        ) { [weak self] phase in
            self?.phase = Self.swiftUIPhase(phase)
        }
    }

    package func retry(
        request: ImageRequest,
        loader: any ImageLoading,
        policy: FoveaImageLoadingPolicy = .default
    ) async {
        await load(request: request, loader: loader, policy: policy, force: true)
    }

    package func prepareForIdentityChange(
        to identity: String,
        retention: FoveaImageRetentionPolicy
    ) {
        session.prepareForIdentityChange(to: identity, retention: retention.coreRetention) {
            [weak self] phase in
            self?.phase = Self.swiftUIPhase(phase)
        }
    }

    package func invalidate() {
        session.invalidate { [weak self] phase in
            self?.phase = Self.swiftUIPhase(phase)
        }
    }

    private static func swiftUIPhase(_ phase: ImageDisplaySessionPhase) -> FoveaImagePhase {
        switch phase {
        case .empty: .empty
        case .loading: .loading
        case .preview(let image): .preview(image)
        case .success(let image): .success(image)
        case .failure(let failure): .failure(failure)
        case .cancelled: .cancelled
        }
    }
}

extension FoveaImageRetentionPolicy {
    package var coreRetention: ImageDisplayRetention {
        switch self {
        case .clearImmediately: .clearImmediately
        case .retainSuccessfulImageUntilReplacement: .retainSuccessfulImageUntilReplacement
        }
    }
}

@MainActor
package final class FoveaGeometryRequestModel: ObservableObject {
    @Published package private(set) var request: ImageRequest?
    @Published package private(set) var failure: PipelineFailure?
    private var resolver: TargetGeometryResolver

    package init(policy: TargetGeometryPolicy = .current) {
        self.resolver = TargetGeometryResolver(policy: policy)
    }

    package func update(
        widthPoints: Double,
        heightPoints: Double,
        scale: Double,
        contentMode: ImageContentMode,
        isStable: Bool,
        requestBuilder: (ResolvedImageTarget) throws -> ImageRequest
    ) {
        let target: ResolvedImageTarget?
        do {
            target = try resolver.resolve(
                widthPoints: widthPoints,
                heightPoints: heightPoints,
                scale: scale,
                contentMode: contentMode,
                isStable: isStable
            )
        } catch let pipelineFailure as PipelineFailure {
            publishFailure(pipelineFailure)
            return
        } catch let geometryError as TargetGeometryError {
            publishFailure(PipelineFailure.imageCraft(geometryError, stage: .requestValidation))
            return
        } catch let imageError as ImageCraftError {
            publishFailure(PipelineFailure.imageCraft(imageError, stage: .requestValidation))
            return
        } catch {
            publishFailure(Self.requestBuilderFailure)
            return
        }
        guard let target else {
            request = nil
            failure = nil
            return
        }

        let next: ImageRequest
        do {
            next = try requestBuilder(target)
        } catch let pipelineFailure as PipelineFailure {
            publishFailure(pipelineFailure)
            return
        } catch let imageError as ImageCraftError {
            publishFailure(PipelineFailure.imageCraft(imageError, stage: .requestValidation))
            return
        } catch {
            publishFailure(Self.requestBuilderFailure)
            return
        }

        failure = nil
        if request?.displayIdentity != next.displayIdentity {
            request = next
        }
    }

    package func reset() {
        resolver.reset()
        request = nil
        failure = nil
    }

    private func publishFailure(_ next: PipelineFailure) {
        request = nil
        failure = next
    }

    private static let requestBuilderFailure = PipelineFailure(
        category: .internalFailure,
        stage: .requestValidation,
        disposition: .terminal,
        reasonCode: "responsive-request-builder-failed"
    )
}

/// 将响应式几何解析与图像显示会话融合为一个 SwiftUI 生命周期对象。
/// 单一模型避免每个列表单元同时创建几何模型、图像模型和两层 `.task`。
@MainActor
package final class FoveaResponsiveImageModel: ObservableObject {
    @Published package private(set) var phase: FoveaImagePhase = .empty

    private var resolver: TargetGeometryResolver
    private let session = ImageDisplaySession()
    private var lastRetryGeneration: UUID?

    package init(policy: TargetGeometryPolicy = .current) {
        self.resolver = TargetGeometryResolver(policy: policy)
    }

    package func updateAndLoad(
        widthPoints: Double,
        heightPoints: Double,
        scale: Double,
        contentMode: ImageContentMode,
        isStable: Bool,
        retryGeneration: UUID,
        loader: any ImageLoading,
        loadingPolicy: FoveaImageLoadingPolicy,
        requestBuilder: (ResolvedImageTarget) throws -> ImageRequest
    ) async {
        let forcesReload = lastRetryGeneration != nil && lastRetryGeneration != retryGeneration
        lastRetryGeneration = retryGeneration

        let target: ResolvedImageTarget
        do {
            guard
                let resolved = try resolver.resolve(
                    widthPoints: widthPoints,
                    heightPoints: heightPoints,
                    scale: scale,
                    contentMode: contentMode,
                    isStable: isStable
                )
            else {
                session.invalidate(clear: false) { _ in }
                publish(.empty)
                return
            }
            target = resolved
        } catch let failure as PipelineFailure {
            publishRequestFailure(failure)
            return
        } catch let geometryError as TargetGeometryError {
            publishRequestFailure(
                PipelineFailure.imageCraft(geometryError, stage: .requestValidation))
            return
        } catch let error as ImageCraftError {
            publishRequestFailure(PipelineFailure.imageCraft(error, stage: .requestValidation))
            return
        } catch {
            publishRequestFailure(Self.requestBuilderFailure)
            return
        }

        let request: ImageRequest
        do {
            request = try requestBuilder(target)
        } catch let failure as PipelineFailure {
            publishRequestFailure(failure)
            return
        } catch let error as ImageCraftError {
            publishRequestFailure(PipelineFailure.imageCraft(error, stage: .requestValidation))
            return
        } catch {
            publishRequestFailure(Self.requestBuilderFailure)
            return
        }

        session.prepareForIdentityChange(
            to: request.displayIdentity,
            retention: loadingPolicy.retention.coreRetention
        ) { [weak self] phase in
            self?.phase = Self.swiftUIPhase(phase)
        }
        await session.load(
            request: request,
            loader: loader,
            placeholderDelayNanoseconds: loadingPolicy.placeholderDelayNanoseconds,
            retention: loadingPolicy.retention.coreRetention,
            force: forcesReload
        ) { [weak self] phase in
            self?.phase = Self.swiftUIPhase(phase)
        }
    }

    private func publishRequestFailure(_ failure: PipelineFailure) {
        session.invalidate(clear: false) { _ in }
        publish(.failure(failure))
    }

    private func publish(_ next: FoveaImagePhase) {
        guard phase.kind != next.kind else { return }
        phase = next
    }

    private static func swiftUIPhase(_ phase: ImageDisplaySessionPhase) -> FoveaImagePhase {
        switch phase {
        case .empty: .empty
        case .loading: .loading
        case .preview(let image): .preview(image)
        case .success(let image): .success(image)
        case .failure(let failure): .failure(failure)
        case .cancelled: .cancelled
        }
    }

    private static let requestBuilderFailure = PipelineFailure(
        category: .internalFailure,
        stage: .requestValidation,
        disposition: .terminal,
        reasonCode: "responsive-request-builder-failed"
    )
}
