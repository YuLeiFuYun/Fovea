import Foundation
import FoveaHTTP
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

private struct CredentialRefreshScope: Hashable, Sendable {
  let namespace: SecurityNamespaceID
  let authorizationContext: AuthorizationContextID
}

private struct CredentialRefreshKey: Hashable, Sendable {
  let namespace: SecurityNamespaceID
  let authorizationContext: AuthorizationContextID
  let currentGeneration: CredentialGeneration

  var scope: CredentialRefreshScope {
    CredentialRefreshScope(
      namespace: namespace,
      authorizationContext: authorizationContext
    )
  }
}

private enum CredentialRefreshTaskContext {
  @TaskLocal static var activeKeys: Set<CredentialRefreshKey> = []
}

private actor CredentialRefreshCoordinator {
  private let registry = SharedTaskRegistry<CredentialRefreshKey, CredentialRefreshResult>()
  private var latestResults: [CredentialRefreshScope: CredentialRefreshResult] = [:]

  func refresh(
    key: CredentialRefreshKey,
    priority: ImageRequestPriority,
    operation: @escaping @Sendable () async throws -> CredentialRefreshResult
  ) async throws -> CredentialRefreshResult {
    guard !CredentialRefreshTaskContext.activeKeys.contains(key) else {
      throw PipelineFailure.authorization(reasonCode: "credential-refresh-reentrancy")
    }
    if let latest = latestResults[key.scope],
      latest.credentialGeneration.value > key.currentGeneration.value
    {
      return latest
    }

    let subscription = await registry.subscribe(key: key, priority: priority) { _ in
      let result = try await CredentialRefreshTaskContext.$activeKeys.withValue(
        CredentialRefreshTaskContext.activeKeys.union([key])
      ) {
        try await operation()
      }
      await self.publish(result, for: key)
      return result
    }
    return try await withTaskCancellationHandler {
      do {
        let result = try await subscription.value()
        try Task.checkCancellation()
        await subscription.detach()
        return result
      } catch {
        await subscription.detach()
        if error is CancellationError {
          throw PipelineFailure.cancelled(stage: .requestValidation)
        }
        if let failure = error as? PipelineFailure { throw failure }
        throw PipelineFailure.authorization(reasonCode: "credential-refresh-failed")
      }
    } onCancel: {
      Task { await subscription.detach() }
    }
  }

  private func publish(
    _ result: CredentialRefreshResult,
    for key: CredentialRefreshKey
  ) {
    guard result.credentialGeneration.value > key.currentGeneration.value else { return }
    if let existing = latestResults[key.scope],
      existing.credentialGeneration.value >= result.credentialGeneration.value
    {
      return
    }
    // 每个授权作用域只保留最新结果，用于覆盖同一旧代际中迟到的 401。
    latestResults[key.scope] = result
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
