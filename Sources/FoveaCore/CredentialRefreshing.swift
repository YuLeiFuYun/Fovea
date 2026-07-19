import Foundation
import ImageCraftCore

public struct CredentialRefreshResult: Sendable {
  public let credentialGeneration: CredentialGeneration
  public let headers: [String: String]
  public let credentialHeaderNames: Set<String>
  public let headerVariantFingerprints: [String: HeaderVariantFingerprint]

  public init(
    credentialGeneration: CredentialGeneration,
    headers: [String: String],
    credentialHeaderNames: Set<String> = [],
    headerVariantFingerprints: [String: HeaderVariantFingerprint] = [:]
  ) {
    self.credentialGeneration = credentialGeneration
    self.headers = headers
    self.credentialHeaderNames = credentialHeaderNames
    self.headerVariantFingerprints = headerVariantFingerprints
  }
}

public protocol CredentialRefreshing: Sendable {
  func refreshCredentials(
    namespace: SecurityNamespaceID,
    authorizationContext: AuthorizationContextID,
    currentGeneration: CredentialGeneration
  ) async throws -> CredentialRefreshResult
}

private struct CredentialRefreshKey: Hashable, Sendable {
  let namespace: SecurityNamespaceID
  let authorizationContext: AuthorizationContextID
  let currentGeneration: CredentialGeneration
}

private enum CredentialRefreshTaskContext {
  @TaskLocal static var activeKeys: Set<CredentialRefreshKey> = []
}

private actor CredentialRefreshCoordinator {
  private let registry = SharedTaskRegistry<CredentialRefreshKey, CredentialRefreshResult>()

  func refresh(
    key: CredentialRefreshKey,
    priority: ImageRequestPriority,
    operation: @escaping @Sendable () async throws -> CredentialRefreshResult
  ) async throws -> CredentialRefreshResult {
    guard !CredentialRefreshTaskContext.activeKeys.contains(key) else {
      throw PipelineFailure.authorization(reasonCode: "credential-refresh-reentrancy")
    }

    let subscription = await registry.subscribe(key: key, priority: priority) { _ in
      try await CredentialRefreshTaskContext.$activeKeys.withValue(
        CredentialRefreshTaskContext.activeKeys.union([key])
      ) {
        try await operation()
      }
    }
    return try await withTaskCancellationHandler {
      do {
        let result = try await subscription.value()
        try Task.checkCancellation()
        await subscription.cancel()
        return result
      } catch {
        await subscription.cancel()
        if error is CancellationError {
          throw PipelineFailure.cancelled(stage: .requestValidation)
        }
        if let failure = error as? PipelineFailure { throw failure }
        throw PipelineFailure.authorization(reasonCode: "credential-refresh-failed")
      }
    } onCancel: {
      Task { await subscription.cancel() }
    }
  }
}

public final class RefreshingImageLoader: ImageLoading, Sendable {
  private let base: any ImageLoading
  private let refresher: any CredentialRefreshing
  private let coordinator = CredentialRefreshCoordinator()

  public init(
    base: any ImageLoading,
    refresher: any CredentialRefreshing
  ) {
    self.base = base
    self.refresher = refresher
  }

  public func image(for request: ImageRequest) async throws -> DecodedImage {
    do {
      return try await base.image(for: request)
    } catch let failure as PipelineFailure {
      guard failure.statusCode == 401,
        let currentGeneration = request.credentialGeneration,
        request.authorizationContext != .public
      else {
        throw failure
      }

      let key = CredentialRefreshKey(
        namespace: request.namespace,
        authorizationContext: request.authorizationContext,
        currentGeneration: currentGeneration
      )
      let refreshed = try await coordinator.refresh(
        key: key,
        priority: request.priority
      ) { [refresher] in
        try await refresher.refreshCredentials(
          namespace: request.namespace,
          authorizationContext: request.authorizationContext,
          currentGeneration: currentGeneration
        )
      }
      guard refreshed.credentialGeneration.value > currentGeneration.value else {
        throw PipelineFailure.authorization(reasonCode: "credential-generation-not-advanced")
      }
      let authorized = try request.replacingCredentials(refreshed)
      return try await base.image(for: authorized)
    }
  }
}
