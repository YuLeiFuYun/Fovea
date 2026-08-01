import AkashicCore
import Foundation
import FoveaStorage
import ImageCraftCore

private final class ImageEventStreamTerminalState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var cancellationHandled = false

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }

    func claimCancellationIfIncomplete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed, !cancellationHandled else { return false }
        cancellationHandled = true
        return true
    }
}

extension FoveaPipeline {
    /// 保留高层生命周期协作者，但不通过公共 API 暴露。
    package func retainLifetimeAnchor(_ anchor: any Sendable) async {
        await lifetimeAnchors.retain(anchor)
    }

    package func lifetimeAnchorCountForTesting() async -> Int {
        await lifetimeAnchors.count
    }

    @concurrent
    public func image(for request: ImageRequest) async throws -> DecodedImage {
        let admission = SharedTaskAdmission.now()
        return try await SharedTaskAdmissionContext.$current.withValue(admission) {
            try await execute {
                try validateAccess(to: request)
                try validateAuthorization(of: request)
                return try await imageCoordinator.load(request: request)
            }
        }
    }

    public func events(
        for request: ImageRequest
    ) -> AsyncThrowingStream<ImageLoadingEvent, any Error> {
        AsyncThrowingStream { continuation in
            let terminalState = ImageEventStreamTerminalState()
            let task = Task { [self] in
                do {
                    let image = try await execute {
                        try validateAccess(to: request)
                        try validateAuthorization(of: request)
                        return try await withImageLoadAdmission(request: request) {
                            let admission = SharedTaskAdmission.now()
                            return try await SharedTaskAdmissionContext.$current.withValue(
                                admission
                            ) {
                                try await self.imageCoordinator.load(
                                    request: request,
                                    onFullQualityPreview: { preview in
                                        try Task.checkCancellation()
                                        if case .terminated = continuation.yield(
                                            .preview(preview, quality: UInt16.max)
                                        ) {
                                            throw CancellationError()
                                        }
                                    }
                                )
                            }
                        }
                    }
                    try Task.checkCancellation()
                    if case .terminated = continuation.yield(.final(image)) {
                        throw CancellationError()
                    }
                    terminalState.markCompleted()
                    continuation.finish()
                } catch {
                    if Self.isCancellation(error),
                        terminalState.claimCancellationIfIncomplete()
                    {
                        observeCancelledRequest(request)
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable [weak self] termination in
                guard let self else {
                    task.cancel()
                    return
                }
                if case .cancelled = termination,
                    terminalState.claimCancellationIfIncomplete()
                {
                    self.observeCancelledRequest(request)
                }
                task.cancel()
            }
        }
    }

    public func encodedData(for request: ImageRequest) async throws -> Data {
        let admission = SharedTaskAdmission.now()
        return try await SharedTaskAdmissionContext.$current.withValue(admission) {
            try await execute {
                try validateAccess(to: request)
                try validateAuthorization(of: request)
                return try await encodedCoordinator.load(request: request)
            }
        }
    }

    /// 立即清空当前 pipeline 的 RenderedMemory。
    /// 系统内存压力、账户切换或宿主应用主动降级时可安全重复调用。
    @discardableResult
    public func purgeMemoryCache() async -> Int {
        let removed = await cache.purgeRendered()
        await diagnostics.record(
            DiagnosticEvent(
                kind: .renderedMemoryPurged,
                byteCount: removed.costBytes,
                itemCount: removed.itemCount,
                reason: "explicit-or-system-pressure"
            )
        )
        return removed.itemCount
    }

    /// 回收未被表征记录引用的持久化数据块。
    /// 自定义存储必须同时实现对应的维护协议，否则以结构化能力错误失败。
    public func garbageCollectCaches() async throws -> GarbageCollectionResult {
        do {
            return try await cache.garbageCollect()
        } catch let failure as PipelineFailure {
            throw failure
        } catch is CancellationError {
            throw PipelineFailure.cancelled(stage: .persistence)
        } catch {
            throw PipelineFailure(
                category: .cacheWrite,
                stage: .persistence,
                disposition: .cacheDegraded,
                reasonCode: "cache-garbage-collection-failed"
            )
        }
    }

    public func revoke(namespace: SecurityNamespaceID) async throws {
        let registryFailure: PipelineFailure?
        let revocationGeneration: NamespaceGeneration?
        do {
            revocationGeneration = try await namespaceRegistry.beginRevocation(namespace)
            registryFailure = nil
        } catch let failure as PipelineFailure {
            revocationGeneration = nil
            registryFailure = failure
        }
        defer {
            if let revocationGeneration {
                await namespaceRegistry.finishRevocation(
                    namespace,
                    generation: revocationGeneration
                )
            }
        }
        await fetchStage.cancelAll(namespace: namespace)
        await decodeStage.cancelAll(namespace: namespace)
        await deliveryCoordinator.cancelAll(namespace: namespace)
        await encodedWarmups.cancelAll(namespace: namespace)
        let cleanupFailed = await cache.cleanup(namespace: namespace)
        await diagnostics.record(
            DiagnosticEvent(
                kind: .namespaceRevoked,
                reason: cleanupFailed ? "persistent-cleanup-failed" : nil
            )
        )
        if cleanupFailed { throw PipelineFailure.namespaceCleanupFailed }
        if let registryFailure { throw registryFailure }
    }

    @_spi(BenchmarkDiagnostics)
    public func benchmarkDiagnosticsSnapshot() async -> FoveaBenchmarkDiagnosticsSnapshot {
        let handoff = cache.transientHandoffSnapshot()
        let warmups = await encodedWarmups.entryCount()
        return FoveaBenchmarkDiagnosticsSnapshot(
            transientHandoffCount: handoff.itemCount,
            transientHandoffBytes: handoff.costBytes,
            adaptiveWarmupCount: warmups,
            inFlightHandoffPreparationCount: handoff.inFlightPreparationCount,
            inFlightHandoffPreparationBytes: handoff.inFlightPreparationBytes
        )
    }

    package func cancelAdaptiveWork() async {
        await encodedWarmups.cancelAll()
        await cache.discardTransientHandoffs()
    }

    /// 测试缝：执行与自适应取消预热相同的原编码验证路径，不暴露为公共预取 API。
    package func warmOriginalForTesting(_ request: ImageRequest) async throws {
        try await execute {
            try validateAccess(to: request)
            try validateAuthorization(of: request)
            try await imageCoordinator.warmOriginal(request: request)
        }
    }

    private func withImageLoadAdmission<Value: Sendable>(
        request: ImageRequest,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let ticket = imageLoadAdmission.begin(for: request)
        do {
            if ticket.stabilizationNanoseconds > 0 {
                try await Task.sleep(nanoseconds: ticket.stabilizationNanoseconds)
            }
            let warmupRequest = request.reprioritized(.background)
            let completion = await encodedWarmups.completionStream(for: warmupRequest)
            for await _ in completion { break }
            try Task.checkCancellation()
            let grace =
                ticket.preservesFetchOnCancellation
                ? CancellationCohortPolicy.retentionNanoseconds
                : 0
            let value = try await FetchCancellationHandoffContext.$graceNanoseconds.withValue(
                grace
            ) {
                try await operation()
            }
            imageLoadAdmission.finish(ticket)
            return value
        } catch {
            imageLoadAdmission.finish(ticket)
            throw error
        }
    }

    private func observeCancelledRequest(_ request: ImageRequest) {
        let observation = imageLoadAdmission.recordCancellation(for: request)
        guard observation.shouldWarmCancelledRequest else { return }
        Task { await startCancelledRequestWarmup(request) }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        guard let failure = error as? PipelineFailure else { return false }
        return failure.disposition == .cancelled
    }

    private func startCancelledRequestWarmup(_ request: ImageRequest) async {
        do {
            try validateAccess(to: request)
            try validateAuthorization(of: request)
        } catch {
            return
        }
        let imageCoordinator = self.imageCoordinator
        let warmupRequest = request.reprioritized(.background)
        await encodedWarmups.start(request: warmupRequest) {
            let admission = SharedTaskAdmission.now()
            try await SharedTaskAdmissionContext.$current.withValue(admission) {
                try await imageCoordinator.warmOriginal(request: warmupRequest)
            }
        }
    }

    private func validateAccess(to request: ImageRequest) throws {
        guard profileAccessPolicy.permits(request) else {
            throw PipelineFailure.profileAccessDenied
        }
    }

    private func validateAuthorization(of request: ImageRequest) throws {
        guard request.containsCredentialHeaders else { return }
        guard request.authorizationContext != .public, request.credentialGeneration != nil else {
            throw PipelineFailure.missingAuthorizationContext
        }
    }

    private func execute<Value: Sendable>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        do {
            let value = try await operation()
            if detailedDiagnosticsAreEnabled(diagnostics) {
                await diagnostics.record(DiagnosticEvent(kind: .pipelineSucceeded))
            }
            return value
        } catch let failure as PipelineFailure {
            await record(failure)
            throw failure
        } catch is CancellationError {
            let failure = PipelineFailure.cancelled(stage: .pipeline)
            await record(failure)
            throw failure
        } catch {
            let failure = PipelineFailure.internalFailure(stage: .pipeline)
            await record(failure)
            throw failure
        }
    }

    private func record(_ failure: PipelineFailure) async {
        await diagnostics.record(
            DiagnosticEvent(
                kind: .pipelineFailed,
                statusCode: failure.statusCode,
                reason: failure.reasonCode,
                failureCategory: failure.category,
                failureStage: failure.stage,
                failureDisposition: failure.disposition
            )
        )
    }
}
