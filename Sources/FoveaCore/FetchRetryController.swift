import FoveaHTTP

/// 单次 fetch 共享任务中的有界重试状态。
struct FetchRetryState {
    var attempt = 1
    var totalDelay: UInt64 = 0
    var additionalResponseBytes = 0
}

/// 一次已获准重试的完整执行计划。
struct FetchRetryPlan {
    let delay: UInt64
    let reason: String
    let statusCode: Int?
    let additionalResponseBytes: Int?
}

/// 负责重试分类、预算计算、退避等待和对应诊断，不参与网络执行。
struct FetchRetryController: Sendable {
    private let policy: TransportRetryPolicy
    private let sleeper: any RetrySleeping
    private let jitter: any RetryJittering
    private let diagnostics: FetchStageDiagnostics

    init(
        policy: TransportRetryPolicy,
        sleeper: any RetrySleeping,
        jitter: any RetryJittering,
        diagnostics: FetchStageDiagnostics
    ) {
        self.policy = policy
        self.sleeper = sleeper
        self.jitter = jitter
        self.diagnostics = diagnostics
    }

    func normalizedFailure(_ error: any Error) -> PipelineFailure {
        if error is CancellationError {
            return .cancelled(stage: .transport)
        }
        if let failure = error as? PipelineFailure {
            return failure
        }
        return .transport(error)
    }

    func failurePlan(
        failure: PipelineFailure,
        state: FetchRetryState
    ) async -> FetchRetryPlan? {
        guard failure.disposition == .retryable,
            state.attempt < policy.maximumAttempts,
            let delay = await retryDelay(
                failedAttempt: state.attempt,
                retryAfterNanoseconds: nil,
                totalDelay: state.totalDelay
            )
        else { return nil }
        return FetchRetryPlan(
            delay: delay,
            reason: failure.reasonCode,
            statusCode: failure.statusCode,
            additionalResponseBytes: nil
        )
    }

    func responsePlan(
        response: TimedTransportResponse,
        state: FetchRetryState
    ) async -> FetchRetryPlan? {
        let statusFailure = PipelineFailure.unsupportedStatus(response.head.statusCode)
        guard statusFailure.disposition == .retryable,
            response.head.statusCode != 304,
            state.attempt < policy.maximumAttempts
        else { return nil }

        let byteTotal = state.additionalResponseBytes.addingReportingOverflow(
            response.transport.metrics.receivedBytes
        )
        guard !byteTotal.overflow,
            byteTotal.partialValue <= policy.maximumAdditionalResponseBytes
        else { return nil }

        let retryAfter = HTTPCachePolicy.retryAfterNanoseconds(
            in: response.head.headers,
            now: response.responseTime,
            maximum: policy.maximumDelayNanoseconds
        )
        guard
            let delay = await retryDelay(
                failedAttempt: state.attempt,
                retryAfterNanoseconds: retryAfter,
                totalDelay: state.totalDelay
            )
        else { return nil }

        return FetchRetryPlan(
            delay: delay,
            reason: "http-status-retry",
            statusCode: response.head.statusCode,
            additionalResponseBytes: byteTotal.partialValue
        )
    }

    func schedule(
        _ plan: FetchRetryPlan,
        executionKey: FetchExecutionKey,
        attempt: Int
    ) async throws {
        await diagnostics.recordRetry(
            executionKey: executionKey,
            attempt: attempt,
            delay: plan.delay,
            reason: plan.reason,
            statusCode: plan.statusCode
        )
        do {
            try await sleeper.sleep(nanoseconds: plan.delay)
        } catch {
            let failure: PipelineFailure
            if error is CancellationError || Task.isCancelled {
                failure = .cancelled(stage: .transport)
            } else if let pipelineFailure = error as? PipelineFailure {
                failure = pipelineFailure
            } else {
                failure = .internalFailure(stage: .transport)
            }
            await diagnostics.recordTerminalFailure(
                failure,
                executionKey: executionKey,
                attempt: attempt
            )
            throw failure
        }
    }

    private func retryDelay(
        failedAttempt: Int,
        retryAfterNanoseconds: UInt64?,
        totalDelay: UInt64
    ) async -> UInt64? {
        let jitterFraction = await jitter.fractionPermille()
        let delay = policy.delayNanoseconds(
            afterFailedAttempt: failedAttempt,
            retryAfterNanoseconds: retryAfterNanoseconds,
            jitterFractionPermille: jitterFraction
        )
        let nextTotal = totalDelay.addingReportingOverflow(delay)
        guard !nextTotal.overflow, nextTotal.partialValue <= policy.maximumTotalDelayNanoseconds
        else {
            return nil
        }
        return delay
    }
}
