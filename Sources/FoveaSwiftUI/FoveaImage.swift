import FoveaCore
import ImageCraftCore
import SwiftUI

public enum FoveaImagePhase {
  case empty
  case loading
  case preview(DecodedImage)
  case success(DecodedImage)
  case failure(PipelineFailure)
  case cancelled

  public var kind: FoveaImagePhaseKind {
    switch self {
    case .empty: .empty
    case .loading: .loading
    case .preview: .preview
    case .success: .success
    case .failure: .failure
    case .cancelled: .cancelled
    }
  }
}

public enum FoveaImagePhaseKind: String, Codable, Hashable, Sendable {
  case empty
  case loading
  case preview
  case success
  case failure
  case cancelled
}

public enum FoveaImageAccessibility {
  case decorative
  case label(Text)
}

public enum FoveaImageRetentionPolicy: String, Codable, Hashable, Sendable {
  case clearImmediately
  case retainSuccessfulImageUntilReplacement
}

public struct FoveaImageLoadingPolicy: Hashable, Sendable {
  public let placeholderDelayNanoseconds: UInt64
  public let retention: FoveaImageRetentionPolicy

  public init(
    placeholderDelayNanoseconds: UInt64 = 16_000_000,
    retention: FoveaImageRetentionPolicy = .clearImmediately
  ) {
    self.placeholderDelayNanoseconds = placeholderDelayNanoseconds
    self.retention = retention
  }

  public static let `default` = FoveaImageLoadingPolicy()
}

public enum FoveaImageResolvedTransition: Equatable, Sendable {
  case identity
  case opacity(duration: Double)
}

public struct FoveaImageTransitionPolicy: Hashable, Sendable {
  public let opacityDuration: Double

  public init(opacityDuration: Double = 0.2) {
    self.opacityDuration = max(0, opacityDuration)
  }

  public static let `default` = FoveaImageTransitionPolicy()

  public func resolved(reduceMotion: Bool) -> FoveaImageResolvedTransition {
    guard !reduceMotion, opacityDuration > 0 else { return .identity }
    return .opacity(duration: opacityDuration)
  }
}

public struct FoveaImageFailureContext {
  public let failure: PipelineFailure
  public let recoveryAction: FoveaImageRecoveryAction
  private let retryAction: @MainActor () -> Void

  package init(
    failure: PipelineFailure,
    recoveryAction: FoveaImageRecoveryAction,
    retryAction: @escaping @MainActor () -> Void
  ) {
    self.failure = failure
    self.recoveryAction = recoveryAction
    self.retryAction = retryAction
  }

  @MainActor
  public func retry() {
    guard recoveryAction == .retry else { return }
    retryAction()
  }
}

public enum FoveaSwiftUIImageFailurePolicy {
  public static func action(for failure: PipelineFailure) -> FoveaImageRecoveryAction {
    failure.imageRecoveryAction
  }
}

@MainActor
package final class FoveaImageModel: ObservableObject {
  @Published package private(set) var phase: FoveaImagePhase = .empty
  package private(set) var requestGeneration: UInt64 = 0
  private var activeIdentity: String?
  private var latestPreviewQuality: UInt16?

  package init() {}

  package func load(
    request: ImageRequest,
    loader: any ImageLoading,
    policy: FoveaImageLoadingPolicy = .default,
    force: Bool = false
  ) async {
    let identity = request.displayIdentity
    if !force, activeIdentity == identity { return }

    requestGeneration &+= 1
    let generation = requestGeneration
    activeIdentity = identity
    latestPreviewQuality = nil
    if policy.retention == .clearImmediately || !isSuccessful {
      phase = .empty
    }

    let loadingIndicator = Task { [weak self] in
      guard policy.placeholderDelayNanoseconds > 0 else {
        self?.showLoading(generation: generation, identity: identity)
        return
      }
      try? await Task.sleep(nanoseconds: policy.placeholderDelayNanoseconds)
      guard !Task.isCancelled else { return }
      self?.showLoading(generation: generation, identity: identity)
    }
    defer { loadingIndicator.cancel() }

    do {
      if let progressive = loader as? any ProgressiveImageLoading {
        try await consume(
          progressive.events(for: request),
          generation: generation,
          identity: identity
        )
      } else {
        let image = try await loader.image(for: request)
        guard isCurrent(generation: generation, identity: identity) else { return }
        phase = .success(image)
      }
    } catch let failure as PipelineFailure {
      guard isCurrent(generation: generation, identity: identity) else { return }
      phase = failure.disposition == .cancelled ? .cancelled : .failure(failure)
    } catch is CancellationError {
      guard isCurrent(generation: generation, identity: identity) else { return }
      phase = .cancelled
    } catch {
      guard isCurrent(generation: generation, identity: identity) else { return }
      phase = .failure(
        PipelineFailure(
          category: .internalFailure,
          stage: .pipeline,
          disposition: .terminal,
          reasonCode: "unexpected-ui-error"
        )
      )
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
    guard activeIdentity != identity else { return }
    requestGeneration &+= 1
    activeIdentity = nil
    latestPreviewQuality = nil
    if retention == .clearImmediately || !isSuccessful {
      phase = .empty
    }
  }

  package func invalidate() {
    requestGeneration &+= 1
    activeIdentity = nil
    latestPreviewQuality = nil
    phase = .empty
  }

  private func consume(
    _ events: AsyncThrowingStream<ImageLoadingEvent, Error>,
    generation: UInt64,
    identity: String
  ) async throws {
    for try await event in events {
      try Task.checkCancellation()
      guard isCurrent(generation: generation, identity: identity) else { return }
      switch event {
      case .preview(let image, let quality):
        guard latestPreviewQuality.map({ quality > $0 }) ?? true else { continue }
        latestPreviewQuality = quality
        phase = .preview(image)
      case .final(let image):
        latestPreviewQuality = nil
        phase = .success(image)
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

  private func showLoading(generation: UInt64, identity: String) {
    guard isCurrent(generation: generation, identity: identity) else { return }
    if case .empty = phase { phase = .loading }
  }
}

@MainActor
package final class FoveaGeometryRequestModel: ObservableObject {
  @Published package private(set) var request: ImageRequest?
  private var resolver: TargetGeometryResolver

  package init(policy: TargetGeometryPolicy = .coreV1) {
    self.resolver = TargetGeometryResolver(policy: policy)
  }

  package func update(
    widthPoints: Double,
    heightPoints: Double,
    scale: Double,
    contentMode: ImageContentMode,
    isStable: Bool,
    requestBuilder: (ResolvedImageTarget) throws -> ImageRequest
  ) throws {
    guard
      let target = try resolver.resolve(
        widthPoints: widthPoints,
        heightPoints: heightPoints,
        scale: scale,
        contentMode: contentMode,
        isStable: isStable
      )
    else {
      request = nil
      return
    }
    let next: ImageRequest
    do {
      next = try requestBuilder(target)
    } catch {
      request = nil
      throw error
    }
    if request?.displayIdentity != next.displayIdentity {
      request = next
    }
  }

  package func reset() {
    resolver.reset()
    request = nil
  }
}

private struct FoveaGeometryTaskIdentity: Hashable {
  let widthPoints: Double
  let heightPoints: Double
  let scale: Double
  let contentMode: ImageContentMode
  let isStable: Bool
}

public struct FoveaImage<Placeholder: View, Failure: View>: View {
  private let request: ImageRequest
  private let loader: any ImageLoading
  private let accessibility: FoveaImageAccessibility
  private let loadingPolicy: FoveaImageLoadingPolicy
  private let transitionPolicy: FoveaImageTransitionPolicy
  private let placeholder: () -> Placeholder
  private let failure: (FoveaImageFailureContext) -> Failure
  @StateObject private var model = FoveaImageModel()
  @State private var retryGeneration: UInt64 = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(
    request: ImageRequest,
    loader: any ImageLoading,
    accessibility: FoveaImageAccessibility,
    loadingPolicy: FoveaImageLoadingPolicy = .default,
    transitionPolicy: FoveaImageTransitionPolicy = .default,
    @ViewBuilder placeholder: @escaping () -> Placeholder,
    @ViewBuilder failure: @escaping (FoveaImageFailureContext) -> Failure
  ) {
    self.request = request
    self.loader = loader
    self.accessibility = accessibility
    self.loadingPolicy = loadingPolicy
    self.transitionPolicy = transitionPolicy
    self.placeholder = placeholder
    self.failure = failure
  }

  public var body: some View {
    content
      .transition(resolvedTransition)
      .animation(resolvedAnimation, value: model.phase.kind)
      .task(id: taskIdentity) {
        await model.load(request: request, loader: loader, policy: loadingPolicy)
      }
      .onChange(of: requestIdentity) { identity in
        model.prepareForIdentityChange(to: identity, retention: loadingPolicy.retention)
      }
      .onDisappear { model.invalidate() }
  }

  @ViewBuilder
  private var content: some View {
    switch model.phase {
    case .empty, .loading, .cancelled:
      placeholder()
    case .preview(let decoded), .success(let decoded):
      renderedImage(decoded)
    case .failure(let error):
      failure(
        FoveaImageFailureContext(
          failure: error,
          recoveryAction: FoveaSwiftUIImageFailurePolicy.action(for: error),
          retryAction: retry
        )
      )
    }
  }

  @ViewBuilder
  private func renderedImage(_ decoded: DecodedImage) -> some View {
    switch accessibility {
    case .decorative:
      Image(decorative: decoded.cgImage, scale: 1).resizable()
    case .label(let label):
      Image(decoded.cgImage, scale: 1, label: label).resizable()
    }
  }

  private var resolvedTransition: AnyTransition {
    switch transitionPolicy.resolved(reduceMotion: reduceMotion) {
    case .identity: .identity
    case .opacity: .opacity
    }
  }

  private var resolvedAnimation: Animation? {
    switch transitionPolicy.resolved(reduceMotion: reduceMotion) {
    case .identity: nil
    case .opacity(let duration): .easeInOut(duration: duration)
    }
  }

  private var requestIdentity: String { request.displayIdentity }
  private var taskIdentity: String { "\(requestIdentity)|retry:\(retryGeneration)" }

  @MainActor
  private func retry() {
    retryGeneration &+= 1
  }
}

public struct FoveaResponsiveImage<Placeholder: View, Failure: View>: View {
  private let loader: any ImageLoading
  private let accessibility: FoveaImageAccessibility
  private let contentMode: ImageContentMode
  private let geometryIsStable: Bool
  private let loadingPolicy: FoveaImageLoadingPolicy
  private let transitionPolicy: FoveaImageTransitionPolicy
  private let requestBuilder: @MainActor (ResolvedImageTarget) throws -> ImageRequest
  private let placeholder: () -> Placeholder
  private let failure: (FoveaImageFailureContext) -> Failure
  @StateObject private var geometryModel: FoveaGeometryRequestModel
  @Environment(\.displayScale) private var displayScale

  public init(
    loader: any ImageLoading,
    accessibility: FoveaImageAccessibility,
    contentMode: ImageContentMode = .fit,
    geometryPolicy: TargetGeometryPolicy = .coreV1,
    geometryIsStable: Bool = true,
    loadingPolicy: FoveaImageLoadingPolicy = .default,
    transitionPolicy: FoveaImageTransitionPolicy = .default,
    requestBuilder: @escaping @MainActor (ResolvedImageTarget) throws -> ImageRequest,
    @ViewBuilder placeholder: @escaping () -> Placeholder,
    @ViewBuilder failure: @escaping (FoveaImageFailureContext) -> Failure
  ) {
    self.loader = loader
    self.accessibility = accessibility
    self.contentMode = contentMode
    self.geometryIsStable = geometryIsStable
    self.loadingPolicy = loadingPolicy
    self.transitionPolicy = transitionPolicy
    self.requestBuilder = requestBuilder
    self.placeholder = placeholder
    self.failure = failure
    _geometryModel = StateObject(
      wrappedValue: FoveaGeometryRequestModel(policy: geometryPolicy)
    )
  }

  public var body: some View {
    GeometryReader { proxy in
      Group {
        if let request = geometryModel.request {
          FoveaImage(
            request: request,
            loader: loader,
            accessibility: accessibility,
            loadingPolicy: loadingPolicy,
            transitionPolicy: transitionPolicy,
            placeholder: placeholder,
            failure: failure
          )
        } else {
          placeholder()
        }
      }
      .task(id: taskIdentity(for: proxy.size)) {
        try? geometryModel.update(
          widthPoints: proxy.size.width,
          heightPoints: proxy.size.height,
          scale: displayScale,
          contentMode: contentMode,
          isStable: geometryIsStable,
          requestBuilder: requestBuilder
        )
      }
      .onDisappear { geometryModel.reset() }
    }
  }

  private func taskIdentity(for size: CGSize) -> FoveaGeometryTaskIdentity {
    FoveaGeometryTaskIdentity(
      widthPoints: size.width,
      heightPoints: size.height,
      scale: displayScale,
      contentMode: contentMode,
      isStable: geometryIsStable
    )
  }
}

extension FoveaImage where Placeholder == ProgressView<EmptyView, EmptyView>, Failure == EmptyView {
  public init(
    request: ImageRequest,
    loader: any ImageLoading,
    accessibility: FoveaImageAccessibility,
    loadingPolicy: FoveaImageLoadingPolicy = .default,
    transitionPolicy: FoveaImageTransitionPolicy = .default
  ) {
    self.init(
      request: request,
      loader: loader,
      accessibility: accessibility,
      loadingPolicy: loadingPolicy,
      transitionPolicy: transitionPolicy
    ) {
      ProgressView()
    } failure: { _ in
      EmptyView()
    }
  }
}
