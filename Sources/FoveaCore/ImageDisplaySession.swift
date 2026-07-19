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
  package private(set) var requestGeneration: UInt64 = 0

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
    if !force, activeIdentity == identity { return }

    requestGeneration &+= 1
    let generation = requestGeneration
    activeIdentity = identity
    latestPreviewQuality = nil
    if retention == .clearImmediately || !isSuccessful {
      publish(.empty, onChange: onChange)
    }

    let loadingIndicator = Task { [weak self] in
      guard placeholderDelayNanoseconds > 0 else {
        self?.showLoading(generation: generation, identity: identity, onChange: onChange)
        return
      }
      try? await Task.sleep(nanoseconds: placeholderDelayNanoseconds)
      guard !Task.isCancelled else { return }
      self?.showLoading(generation: generation, identity: identity, onChange: onChange)
    }
    defer { loadingIndicator.cancel() }

    do {
      if let progressive = loader as? any ProgressiveImageLoading {
        try await consume(
          progressive.events(for: request),
          generation: generation,
          identity: identity,
          onChange: onChange
        )
      } else {
        let image = try await loader.image(for: request)
        guard isCurrent(generation: generation, identity: identity) else { return }
        publish(.success(image), onChange: onChange)
      }
    } catch let failure as PipelineFailure {
      guard isCurrent(generation: generation, identity: identity) else { return }
      publish(
        failure.disposition == .cancelled ? .cancelled : .failure(failure),
        onChange: onChange
      )
    } catch is CancellationError {
      guard isCurrent(generation: generation, identity: identity) else { return }
      publish(.cancelled, onChange: onChange)
    } catch {
      guard isCurrent(generation: generation, identity: identity) else { return }
      publish(
        .failure(
          PipelineFailure(
            category: .internalFailure,
            stage: .pipeline,
            disposition: .terminal,
            reasonCode: "unexpected-ui-error"
          )
        ),
        onChange: onChange
      )
    }
  }

  package func prepareForIdentityChange(
    to identity: String,
    retention: ImageDisplayRetention,
    onChange: @escaping @MainActor (ImageDisplaySessionPhase) -> Void
  ) {
    guard activeIdentity != identity else { return }
    requestGeneration &+= 1
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
    requestGeneration &+= 1
    activeIdentity = nil
    latestPreviewQuality = nil
    if clear { publish(.empty, onChange: onChange) }
  }

  private func consume(
    _ events: AsyncThrowingStream<ImageLoadingEvent, Error>,
    generation: UInt64,
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

  private func isCurrent(generation: UInt64, identity: String) -> Bool {
    requestGeneration == generation && activeIdentity == identity
  }

  private func showLoading(
    generation: UInt64,
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
    phase = next
    onChange(next)
  }
}
