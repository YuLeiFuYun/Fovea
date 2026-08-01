import FoveaHTTP

/// 统一构造 fetch 阶段诊断事件，避免编排代码重复携带遥测字段。
struct FetchStageDiagnostics: Sendable {
    private let sink: any DiagnosticsSink

    init(sink: any DiagnosticsSink) {
        self.sink = sink
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
