import Foundation
import FoveaHTTP

// 该协作者只构造脱敏事件，不拥有 fetch 状态、重试决策或网络任务。
// live MJPEG 与普通 fetch 共用事件词汇，但保持独立的固定 reason 标记。
/// 统一构造 fetch 阶段诊断事件，避免编排代码重复携带遥测字段。
struct FetchStageDiagnostics: Sendable {
    private let sink: any DiagnosticsSink

    init(sink: any DiagnosticsSink) {
        self.sink = sink
    }

    func recordLiveQueued(
        keyDigest: String,
        requestedPriority: ImageRequestPriority
    ) async {
        await sink.record(
            DiagnosticEvent(
                kind: .fetchQueued,
                keyDigest: keyDigest,
                reason: "mjpeg-live",
                requestedPriority: requestedPriority
            )
        )
    }

    func recordLiveStarted(
        keyDigest: String,
        requestedPriority: ImageRequestPriority
    ) async {
        await sink.record(
            DiagnosticEvent(
                kind: .fetchStarted,
                keyDigest: keyDigest,
                reason: "mjpeg-live",
                attempt: 1,
                requestedPriority: requestedPriority,
                effectivePriority: requestedPriority
            )
        )
    }

    func recordLiveCompleted(
        _ response: TransportProgressCompletion,
        keyDigest: String
    ) async {
        let network = response.metrics.network
        await sink.record(
            DiagnosticEvent(
                kind: .fetchCompleted,
                keyDigest: keyDigest,
                statusCode: response.head.statusCode,
                byteCount: response.metrics.receivedBytes,
                reason: "mjpeg-live",
                attempt: 1,
                durationNanoseconds: network?.taskDurationNanoseconds,
                transactionCount: network?.transactionCount,
                networkProtocolNames: network?.negotiatedProtocolNames,
                reusedConnectionCount: network?.reusedConnectionCount,
                proxyConnectionCount: network?.proxyConnectionCount,
                cellularTransactionCount: network?.cellularTransactionCount,
                expensiveTransactionCount: network?.expensiveTransactionCount,
                constrainedTransactionCount: network?.constrainedTransactionCount,
                redirectCount: network?.redirectCount,
                domainLookupDurationNanoseconds: network?.domainLookupDurationNanoseconds,
                connectionDurationNanoseconds: network?.connectionDurationNanoseconds,
                secureConnectionDurationNanoseconds: network?.secureConnectionDurationNanoseconds,
                requestDurationNanoseconds: network?.requestDurationNanoseconds,
                timeToFirstByteNanoseconds: network?.timeToFirstByteNanoseconds,
                responseDurationNanoseconds: network?.responseDurationNanoseconds
            )
        )
    }

    func recordLiveFailure(
        _ failure: PipelineFailure,
        keyDigest: String
    ) async {
        await sink.record(
            DiagnosticEvent(
                kind: failure.disposition == .cancelled ? .fetchCancelled : .fetchFailed,
                keyDigest: keyDigest,
                statusCode: failure.statusCode,
                reason: failure.reasonCode,
                attempt: 1,
                failureCategory: failure.category,
                failureStage: failure.stage,
                failureDisposition: failure.disposition
            )
        )
    }

    func recordQueued(
        executionKey: FetchExecutionKey,
        requestedPriority: ImageRequestPriority,
        reason: String? = nil
    ) async {
        await sink.record(
            DiagnosticEvent(
                kind: .fetchQueued,
                keyDigest: executionKey.digestHex,
                reason: reason,
                requestedPriority: requestedPriority
            )
        )
    }

    func recordJoined(
        executionKey: FetchExecutionKey,
        requestedPriority: ImageRequestPriority,
        effectivePriority: ImageRequestPriority
    ) async {
        await sink.record(
            DiagnosticEvent(
                kind: .fetchJoined,
                keyDigest: executionKey.digestHex,
                requestedPriority: requestedPriority,
                effectivePriority: effectivePriority
            )
        )
    }

    func recordStarted(
        executionKey: FetchExecutionKey,
        attempt: Int,
        requestedPriority: ImageRequestPriority,
        effectivePriority: ImageRequestPriority
    ) async {
        await sink.record(
            DiagnosticEvent(
                kind: .fetchStarted,
                keyDigest: executionKey.digestHex,
                attempt: attempt,
                requestedPriority: requestedPriority,
                effectivePriority: effectivePriority
            )
        )
    }

    func recordTerminalFailure(
        _ failure: PipelineFailure,
        executionKey: FetchExecutionKey,
        attempt: Int
    ) async {
        await sink.record(
            DiagnosticEvent(
                kind: failure.disposition == .cancelled ? .fetchCancelled : .fetchFailed,
                keyDigest: executionKey.digestHex,
                statusCode: failure.statusCode,
                reason: failure.reasonCode,
                attempt: attempt,
                failureCategory: failure.category,
                failureStage: failure.stage,
                failureDisposition: failure.disposition
            )
        )
    }

    func recordSubscriberReceived(
        executionKey: FetchExecutionKey,
        requestedPriority: ImageRequestPriority
    ) async {
        await sink.record(
            DiagnosticEvent(
                kind: .fetchSubscriberReceived,
                keyDigest: executionKey.digestHex,
                requestedPriority: requestedPriority
            )
        )
    }

    func recordSubscriberReleased(
        executionKey: FetchExecutionKey,
        requestedPriority: ImageRequestPriority
    ) async {
        await sink.record(
            DiagnosticEvent(
                kind: .fetchSubscriberReleased,
                keyDigest: executionKey.digestHex,
                requestedPriority: requestedPriority
            )
        )
    }

    func recordRetry(
        executionKey: FetchExecutionKey,
        attempt: Int,
        delay: UInt64,
        reason: String,
        statusCode: Int?
    ) async {
        await sink.record(
            DiagnosticEvent(
                kind: .fetchRetryScheduled,
                keyDigest: executionKey.digestHex,
                statusCode: statusCode,
                reason: reason,
                attempt: attempt,
                retryDelayNanoseconds: delay
            )
        )
    }

    func recordCompleted(
        _ response: TimedTransportResponse,
        executionKey: FetchExecutionKey,
        attempt: Int
    ) async {
        let network = response.transport.metrics.network
        await sink.record(
            DiagnosticEvent(
                kind: .fetchCompleted,
                keyDigest: executionKey.digestHex,
                statusCode: response.head.statusCode,
                byteCount: response.transport.metrics.receivedBytes,
                attempt: attempt,
                durationNanoseconds: network?.taskDurationNanoseconds,
                transactionCount: network?.transactionCount,
                networkProtocolNames: network?.negotiatedProtocolNames,
                reusedConnectionCount: network?.reusedConnectionCount,
                proxyConnectionCount: network?.proxyConnectionCount,
                cellularTransactionCount: network?.cellularTransactionCount,
                expensiveTransactionCount: network?.expensiveTransactionCount,
                constrainedTransactionCount: network?.constrainedTransactionCount,
                redirectCount: network?.redirectCount,
                domainLookupDurationNanoseconds: network?.domainLookupDurationNanoseconds,
                connectionDurationNanoseconds: network?.connectionDurationNanoseconds,
                secureConnectionDurationNanoseconds: network?.secureConnectionDurationNanoseconds,
                requestDurationNanoseconds: network?.requestDurationNanoseconds,
                timeToFirstByteNanoseconds: network?.timeToFirstByteNanoseconds,
                responseDurationNanoseconds: network?.responseDurationNanoseconds
            )
        )
    }
}

/// Owns the subscriber-side lifecycle for a shared fetch without owning retry or transport work.
struct FetchSharedExecutionCoordinator: Sendable {
    typealias Operation =
        @Sendable (SharedTaskPriorityControl) async throws -> TimedTransportResponse
    typealias FailureNormalizer = @Sendable (any Error) async -> any Error

    let registry: SharedTaskRegistry<ScopedFetchExecutionKey, TimedTransportResponse>
    let diagnostics: FetchStageDiagnostics
    let detailedDiagnosticsEnabled: Bool
    let transportMemoryThreshold: Int

    func execute(
        request: ImageRequest,
        executionKey: FetchExecutionKey,
        operation: @escaping Operation,
        normalize: @escaping FailureNormalizer
    ) async throws -> TimedTransportResponse {
        let scopedKey = ScopedFetchExecutionKey(
            namespace: request.namespace,
            execution: executionKey
        )
        let subscription = await registry.subscribe(
            key: scopedKey,
            priority: request.priority,
            admission: SharedTaskAdmissionContext.current ?? .now()
        ) { priorityControl in
            await diagnostics.recordQueued(
                executionKey: executionKey,
                requestedPriority: request.priority
            )
            return try await operation(priorityControl)
        }
        await recordJoinIfNeeded(
            subscription,
            request: request,
            executionKey: executionKey
        )
        let handoffLease = FetchCancellationHandoffContext.lease
        let remainingByteLimit = FetchCancellationHandoffPolicy.maximumRemainingBytes(
            targetWidth: request.target.width,
            targetHeight: request.target.height,
            transportMemoryThreshold: transportMemoryThreshold
        )
        return try await awaitSharedValue(
            subscription,
            request: request,
            executionKey: executionKey,
            handoffLease: handoffLease,
            handoffRemainingByteLimit: remainingByteLimit,
            normalize: normalize
        )
    }

    private func recordJoinIfNeeded(
        _ subscription: SharedTaskSubscription<ScopedFetchExecutionKey, TimedTransportResponse>,
        request: ImageRequest,
        executionKey: FetchExecutionKey
    ) async {
        guard subscription.wasJoined else { return }
        await diagnostics.recordJoined(
            executionKey: executionKey,
            requestedPriority: request.priority,
            effectivePriority: await subscription.priorityControl.currentPriority()
        )
    }

    private func awaitSharedValue(
        _ subscription: SharedTaskSubscription<ScopedFetchExecutionKey, TimedTransportResponse>,
        request: ImageRequest,
        executionKey: FetchExecutionKey,
        handoffLease: FetchCancellationHandoffLease?,
        handoffRemainingByteLimit: Int,
        normalize: @escaping FailureNormalizer
    ) async throws -> TimedTransportResponse {
        try await withTaskCancellationHandler {
            do {
                let result = try await subscription.value()
                return try await releaseSuccessful(
                    result,
                    subscription: subscription,
                    request: request,
                    executionKey: executionKey
                )
            } catch {
                await releaseFailed(
                    error,
                    subscription: subscription,
                    handoffLease: handoffLease,
                    handoffRemainingByteLimit: handoffRemainingByteLimit
                )
                throw await normalize(error)
            }
        } onCancel: {
            Task {
                await releaseForCancellation(
                    subscription,
                    handoffLease: handoffLease,
                    handoffRemainingByteLimit: handoffRemainingByteLimit
                )
            }
        }
    }

    private func releaseSuccessful(
        _ result: TimedTransportResponse,
        subscription: SharedTaskSubscription<ScopedFetchExecutionKey, TimedTransportResponse>,
        request: ImageRequest,
        executionKey: FetchExecutionKey
    ) async throws -> TimedTransportResponse {
        if detailedDiagnosticsEnabled {
            await diagnostics.recordSubscriberReceived(
                executionKey: executionKey,
                requestedPriority: request.priority
            )
        }
        try Task.checkCancellation()
        let retention = FetchCompletionHandoffPolicy.retentionNanoseconds(
            head: result.head,
            requestTime: result.requestTime,
            responseTime: result.responseTime,
            request: request
        )
        if retention > 0 {
            await subscription.detach(handoffGraceNanoseconds: retention)
        } else {
            await subscription.cancel()
        }
        if detailedDiagnosticsEnabled {
            await diagnostics.recordSubscriberReleased(
                executionKey: executionKey,
                requestedPriority: request.priority
            )
        }
        return result
    }

    private func releaseFailed(
        _ error: any Error,
        subscription: SharedTaskSubscription<ScopedFetchExecutionKey, TimedTransportResponse>,
        handoffLease: FetchCancellationHandoffLease?,
        handoffRemainingByteLimit: Int
    ) async {
        guard Self.isCancellation(error) || Task.isCancelled else {
            await subscription.cancel()
            return
        }
        await releaseForCancellation(
            subscription,
            handoffLease: handoffLease,
            handoffRemainingByteLimit: handoffRemainingByteLimit
        )
    }

    private func releaseForCancellation(
        _ subscription: SharedTaskSubscription<ScopedFetchExecutionKey, TimedTransportResponse>,
        handoffLease: FetchCancellationHandoffLease?,
        handoffRemainingByteLimit: Int
    ) async {
        let grace =
            handoffLease?.eligibleGraceNanoseconds(
                maximumRemainingBytes: handoffRemainingByteLimit
            ) ?? 0
        if grace > 0 {
            await subscription.detach(handoffGraceNanoseconds: grace)
        } else {
            await subscription.cancel(
                retainingCancelledTaskForNanoseconds: CancellationCohortPolicy.retentionNanoseconds
            )
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        guard let failure = error as? PipelineFailure else { return false }
        return failure.disposition == .cancelled
    }
}
