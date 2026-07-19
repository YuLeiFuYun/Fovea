import FoveaCore
import ImageCraftCore
import SwiftUI

public enum FoveaImagePhase {
  case empty
  case loading
  case success(DecodedImage)
  case failure(PipelineFailure)
  case cancelled

  public var kind: FoveaImagePhaseKind {
    switch self {
    case .empty: .empty
    case .loading: .loading
    case .success: .success
    case .failure: .failure
    case .cancelled: .cancelled
    }
  }
}

public enum FoveaImagePhaseKind: String, Codable, Hashable, Sendable {
  case empty
  case loading
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

public enum FoveaImageRecoveryAction: String, Codable, Hashable, Sendable {
  case retry
  case reauthenticate
  case none
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

extension PipelineFailure {
  public var imageRecoveryAction: FoveaImageRecoveryAction {
    if category == .namespaceRevoked || category == .authorization {
      return .reauthenticate
    }
    if category == .securityLimit || disposition == .terminal {
      return .none
    }
    if disposition == .retryable || disposition == .cacheDegraded {
      return .retry
    }
    return .none
  }
}

@MainActor
package final class FoveaImageModel: ObservableObject {
  @Published package private(set) var phase: FoveaImagePhase = .empty
  package private(set) var requestGeneration: UInt64 = 0
  private var activeIdentity: String?

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
      let image = try await loader.image(for: request)
      guard isCurrent(generation: generation, identity: identity) else { return }
      phase = .success(image)
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
    if retention == .clearImmediately || !isSuccessful {
      phase = .empty
    }
  }

  package func invalidate() {
    requestGeneration &+= 1
    activeIdentity = nil
    phase = .empty
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

public struct FoveaImage<Placeholder: View, Failure: View>: View {
  private let request: ImageRequest
  private let loader: any ImageLoading
  private let accessibility: FoveaImageAccessibility
  private let loadingPolicy: FoveaImageLoadingPolicy
  private let placeholder: () -> Placeholder
  private let failure: (FoveaImageFailureContext) -> Failure
  @StateObject private var model = FoveaImageModel()
  @State private var retryGeneration: UInt64 = 0

  public init(
    request: ImageRequest,
    loader: any ImageLoading,
    accessibility: FoveaImageAccessibility,
    loadingPolicy: FoveaImageLoadingPolicy = .default,
    @ViewBuilder placeholder: @escaping () -> Placeholder,
    @ViewBuilder failure: @escaping (FoveaImageFailureContext) -> Failure
  ) {
    self.request = request
    self.loader = loader
    self.accessibility = accessibility
    self.loadingPolicy = loadingPolicy
    self.placeholder = placeholder
    self.failure = failure
  }

  public var body: some View {
    content
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
    case .success(let decoded):
      renderedImage(decoded)
    case .failure(let error):
      failure(
        FoveaImageFailureContext(
          failure: error,
          recoveryAction: error.imageRecoveryAction,
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

  private var requestIdentity: String { request.displayIdentity }
  private var taskIdentity: String { "\(requestIdentity)|retry:\(retryGeneration)" }

  @MainActor
  private func retry() {
    retryGeneration &+= 1
  }
}

extension FoveaImage where Placeholder == ProgressView<EmptyView, EmptyView>, Failure == EmptyView {
  public init(
    request: ImageRequest,
    loader: any ImageLoading,
    accessibility: FoveaImageAccessibility,
    loadingPolicy: FoveaImageLoadingPolicy = .default
  ) {
    self.init(
      request: request,
      loader: loader,
      accessibility: accessibility,
      loadingPolicy: loadingPolicy
    ) {
      ProgressView()
    } failure: { _ in
      EmptyView()
    }
  }
}
