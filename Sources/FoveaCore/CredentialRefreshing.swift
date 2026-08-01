import Foundation
import FoveaHTTP
import ImageCraftCore

/// 经过验证的替代凭证代际及其请求头。

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

/// 约束凭证刷新交接、结果复用和已记忆授权范围。

public struct CredentialRefreshPolicy: Hashable, Sendable {
    public let handoffGraceNanoseconds: UInt64
    public let resultReuseWindowNanoseconds: UInt64
    public let maximumRememberedScopes: Int

    public init(
        handoffGraceNanoseconds: UInt64 = 250_000_000,
        resultReuseWindowNanoseconds: UInt64 = 5_000_000_000,
        maximumRememberedScopes: Int = 128
    ) {
        self.handoffGraceNanoseconds = min(handoffGraceNanoseconds, 5_000_000_000)
        self.resultReuseWindowNanoseconds = min(resultReuseWindowNanoseconds, 60_000_000_000)
        self.maximumRememberedScopes = min(4_096, max(0, maximumRememberedScopes))
    }

    public static let `default` = CredentialRefreshPolicy()
}

/// 认证失败后为一个授权范围刷新凭证。

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
    private struct RememberedResult: Sendable {
        let result: CredentialRefreshResult
        let expiresAtNanoseconds: UInt64
        var accessSequence: UInt64
    }

    private let registry = SharedTaskRegistry<CredentialRefreshKey, CredentialRefreshResult>()
    private let policy: CredentialRefreshPolicy
    private let timeSource: any MonotonicTimeSource
    private var latestResults: [CredentialRefreshScope: RememberedResult] = [:]
    private var nextAccessSequence: UInt64 = 0

    init(
        policy: CredentialRefreshPolicy,
        timeSource: any MonotonicTimeSource
    ) {
        self.policy = policy
        self.timeSource = timeSource
    }

    func refresh(
        key: CredentialRefreshKey,
        priority: ImageRequestPriority,
        operation: @escaping @Sendable () async throws -> CredentialRefreshResult
    ) async throws -> CredentialRefreshResult {
        guard !Task.isCancelled else {
            throw PipelineFailure.cancelled(stage: .requestValidation)
        }
        guard !CredentialRefreshTaskContext.activeKeys.contains(key) else {
            throw PipelineFailure.authorization(reasonCode: "credential-refresh-reentrancy")
        }
        if var remembered = latestResults[key.scope] {
            let now = timeSource.nowNanoseconds()
            if now < remembered.expiresAtNanoseconds,
                remembered.result.credentialGeneration.value > key.currentGeneration.value
            {
                guard !Task.isCancelled else {
                    throw PipelineFailure.cancelled(stage: .requestValidation)
                }
                remembered.accessSequence = nextSequence()
                latestResults[key.scope] = remembered
                return remembered.result
            }
            latestResults.removeValue(forKey: key.scope)
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
                // 成功结果的复用只能由 latestResults 的显式窗口决定；registry 只协调
                // 在途刷新，不得通过 completed-task handoff 成为旁路结果缓存。
                await subscription.cancel()
                return result
            } catch {
                await subscription.detach(
                    handoffGraceNanoseconds: policy.handoffGraceNanoseconds
                )
                if error is CancellationError {
                    throw PipelineFailure.cancelled(stage: .requestValidation)
                }
                if let failure = error as? PipelineFailure { throw failure }
                throw PipelineFailure.authorization(reasonCode: "credential-refresh-failed")
            }
        } onCancel: {
            Task {
                await subscription.detach(
                    handoffGraceNanoseconds: policy.handoffGraceNanoseconds
                )
            }
        }
    }

    private func publish(
        _ result: CredentialRefreshResult,
        for key: CredentialRefreshKey
    ) {
        guard result.credentialGeneration.value > key.currentGeneration.value,
            policy.maximumRememberedScopes > 0,
            policy.resultReuseWindowNanoseconds > 0
        else { return }
        if let existing = latestResults[key.scope],
            existing.result.credentialGeneration.value >= result.credentialGeneration.value
        {
            return
        }
        let now = timeSource.nowNanoseconds()
        let (expiry, overflow) = now.addingReportingOverflow(policy.resultReuseWindowNanoseconds)
        latestResults[key.scope] = RememberedResult(
            result: result,
            expiresAtNanoseconds: overflow ? UInt64.max : expiry,
            accessSequence: nextSequence()
        )
        evictIfNeeded()
    }

    func invalidate(namespace: SecurityNamespaceID) async {
        latestResults = latestResults.filter { $0.key.namespace != namespace }
        _ = await registry.cancelAll { $0.namespace == namespace }
    }

    func rememberedScopeCount() -> Int {
        latestResults.count
    }

    private func evictIfNeeded() {
        while latestResults.count > policy.maximumRememberedScopes,
            let oldest = latestResults.min(by: { $0.value.accessSequence < $1.value.accessSequence }
            )
        {
            latestResults.removeValue(forKey: oldest.key)
        }
    }

    private func nextSequence() -> UInt64 {
        if nextAccessSequence == UInt64.max {
            let ordered = latestResults.sorted { $0.value.accessSequence < $1.value.accessSequence }
            for (index, element) in ordered.enumerated() {
                var remembered = element.value
                remembered.accessSequence = UInt64(index + 1)
                latestResults[element.key] = remembered
            }
            nextAccessSequence = UInt64(ordered.count)
        }
        nextAccessSequence += 1
        return nextAccessSequence
    }
}

/// 为图像加载器添加 single-flight、代际感知的凭证刷新与重放。

public final class RefreshingImageLoader<Base: ImageLoading>: ImageLoading, Sendable {
    private let base: Base
    private let refresher: any CredentialRefreshing
    private let coordinator: CredentialRefreshCoordinator

    public init(
        base: Base,
        refresher: any CredentialRefreshing,
        policy: CredentialRefreshPolicy = .default
    ) {
        self.base = base
        self.refresher = refresher
        self.coordinator = CredentialRefreshCoordinator(
            policy: policy,
            timeSource: SystemMonotonicTimeSource()
        )
    }

    package init(
        base: Base,
        refresher: any CredentialRefreshing,
        policy: CredentialRefreshPolicy,
        timeSource: any MonotonicTimeSource
    ) {
        self.base = base
        self.refresher = refresher
        self.coordinator = CredentialRefreshCoordinator(
            policy: policy,
            timeSource: timeSource
        )
    }

    /// 清除某命名空间已记忆的刷新凭证，并取消进行中的刷新工作。
    /// 退出登录时应与底层管线命名空间撤销一同调用。
    public func invalidateCredentials(for namespace: SecurityNamespaceID) async {
        await coordinator.invalidate(namespace: namespace)
    }

    package func rememberedCredentialScopeCount() async -> Int {
        await coordinator.rememberedScopeCount()
    }

    public func image(for request: ImageRequest) async throws -> DecodedImage {
        do {
            return try await base.image(for: request)
        } catch let failure as PipelineFailure {
            let authorized = try await refreshedRequest(after: failure, for: request)
            return try await base.image(for: authorized)
        }
    }

    private func refreshedRequest(
        after failure: PipelineFailure,
        for request: ImageRequest
    ) async throws -> ImageRequest {
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
        guard !Task.isCancelled else {
            throw PipelineFailure.cancelled(stage: .requestValidation)
        }
        return try request.replacingCredentials(refreshed)
    }
}

extension RefreshingImageLoader: ProgressiveImageLoading where Base: ProgressiveImageLoading {
    /// 保留渐进加载能力，同时应用相同的 single-flight 401 刷新契约。
    public func events(
        for request: ImageRequest
    ) -> AsyncThrowingStream<ImageLoadingEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    do {
                        for try await event in base.events(for: request) {
                            try Task.checkCancellation()
                            continuation.yield(event)
                        }
                    } catch let failure as PipelineFailure {
                        let authorized = try await refreshedRequest(after: failure, for: request)
                        for try await event in base.events(for: authorized) {
                            try Task.checkCancellation()
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension RefreshingImageLoader: NamespaceRevoking where Base: NamespaceRevoking {
    /// 撤销底层命名空间状态前，先使已记忆刷新结果失效。
    /// 凭证失效有意先执行；即使后续持久化清理
    /// 报告降级也不回滚，避免退出登录后残留可重放的刷新凭证。
    public func revoke(namespace: SecurityNamespaceID) async throws {
        await coordinator.invalidate(namespace: namespace)
        try await base.revoke(namespace: namespace)
    }
}
