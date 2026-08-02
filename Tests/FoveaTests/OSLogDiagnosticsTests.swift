import FoveaCore
import FoveaObservability
import XCTest

final class OSLogDiagnosticsTests: XCTestCase {
    func testSystemEmitterAcceptsAllLevelsAndSignpostCategories_DIAG_PT_009() async throws {
        let sink = OSLogDiagnosticsSink(
            configuration: try OSLogDiagnosticsConfiguration(
                subsystem: "dev.fovea.tests",
                category: "system-emitter",
                sampling: .all,
                signpostsEnabled: true
            )
        )
        let fetch = String(repeating: "1", count: 64)
        let decode = String(repeating: "2", count: 64)

        await sink.record(
            DiagnosticEvent(
                kind: .fetchStarted,
                keyDigest: fetch,
                attempt: 1,
                requestedPriority: .high,
                effectivePriority: .userInitiated
            )
        )
        await sink.record(
            DiagnosticEvent(
                kind: .fetchCompleted,
                keyDigest: fetch,
                statusCode: 200,
                byteCount: 256,
                durationNanoseconds: 10,
                transactionCount: 1,
                networkProtocolNames: ["h2"],
                reusedConnectionCount: 1,
                proxyConnectionCount: 0,
                cellularTransactionCount: 0,
                expensiveTransactionCount: 0,
                constrainedTransactionCount: 0
            )
        )
        await sink.record(DiagnosticEvent(kind: .decodeStarted, keyDigest: decode))
        await sink.record(
            DiagnosticEvent(
                kind: .decodeCompleted,
                keyDigest: decode,
                sourcePixelCount: 400,
                outputPixelCount: 100,
                targetWidth: 10,
                targetHeight: 10
            )
        )
        await sink.record(DiagnosticEvent(kind: .originalEncodedHit, byteCount: 256))
        await sink.record(DiagnosticEvent(kind: .namespaceRevoked, reason: "cleanup-failed"))
        await sink.record(
            DiagnosticEvent(
                kind: .pipelineFailed,
                reason: "transport-failed",
                failureCategory: .transport,
                failureStage: .transport,
                failureDisposition: .terminal
            )
        )
        await sink.record(DiagnosticEvent(kind: .responseAnomaly, reason: "missing-content-type"))
    }

    func testFailuresOnlyDropsOrdinaryEventsButKeepsTerminalEvents_DIAG_PT_009() async throws {
        let emitter = RecordingOSLogDiagnosticsEmitter()
        let sink = OSLogDiagnosticsSink(
            configuration: try OSLogDiagnosticsConfiguration(
                subsystem: "dev.fovea.tests",
                sampling: .failuresOnly,
                signpostsEnabled: false
            ),
            emitter: emitter
        )

        await sink.record(DiagnosticEvent(kind: .fetchStarted))
        await sink.record(DiagnosticEvent(kind: .fetchCompleted))
        await sink.record(DiagnosticEvent(kind: .cacheWriteFailed, reason: "cache-write-failed"))

        let logs = await emitter.logs
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.level, .error)
    }

    func testConfigurationRejectsDynamicOrHighCardinalityIdentifiers_DIAG_PT_001() {
        XCTAssertThrowsError(
            try OSLogDiagnosticsConfiguration(subsystem: "dev.fovea/account-secret")
        ) { error in
            XCTAssertEqual(error as? OSLogDiagnosticsConfigurationError, .invalidSubsystem)
        }
        XCTAssertThrowsError(
            try OSLogDiagnosticsConfiguration(
                subsystem: "dev.fovea.tests",
                category: String(repeating: "a", count: 65)
            )
        ) { error in
            XCTAssertEqual(error as? OSLogDiagnosticsConfigurationError, .invalidCategory)
        }
    }

    func testIntervalsCloseOnSuccessFailureAndCancellation_DIAG_PT_005() async throws {
        let emitter = RecordingOSLogDiagnosticsEmitter()
        let sink = OSLogDiagnosticsSink(
            configuration: try OSLogDiagnosticsConfiguration(
                subsystem: "dev.fovea.tests",
                sampling: .all
            ),
            emitter: emitter
        )
        let fetchSuccess = String(repeating: "a", count: 64)
        let decodeFailure = String(repeating: "b", count: 64)
        let fetchCancellation = String(repeating: "c", count: 64)

        await sink.record(DiagnosticEvent(kind: .fetchStarted, keyDigest: fetchSuccess))
        await sink.record(DiagnosticEvent(kind: .fetchCompleted, keyDigest: fetchSuccess))
        await sink.record(DiagnosticEvent(kind: .decodeStarted, keyDigest: decodeFailure))
        await sink.record(
            DiagnosticEvent(
                kind: .decodeFailed,
                keyDigest: decodeFailure,
                reason: "decode-failed"
            )
        )
        await sink.record(DiagnosticEvent(kind: .fetchStarted, keyDigest: fetchCancellation))
        await sink.record(
            DiagnosticEvent(
                kind: .fetchCancelled,
                keyDigest: fetchCancellation,
                reason: "cancelled"
            )
        )

        let signposts = await emitter.signposts
        XCTAssertEqual(signposts.count, 6)
        assertSignpost(signposts[0], operation: .begin, interval: .fetch, id: 1)
        assertSignpost(signposts[1], operation: .end, interval: .fetch, id: 1)
        assertSignpost(signposts[2], operation: .begin, interval: .decode, id: 2)
        assertSignpost(signposts[3], operation: .end, interval: .decode, id: 2)
        assertSignpost(signposts[4], operation: .begin, interval: .fetch, id: 3)
        assertSignpost(signposts[5], operation: .end, interval: .fetch, id: 3)
    }

    func testActiveIntervalsAreBoundedAndDroppedSummaryClosesOutstandingIntervals() async throws {
        let emitter = RecordingOSLogDiagnosticsEmitter()
        let sink = OSLogDiagnosticsSink(
            configuration: try OSLogDiagnosticsConfiguration(
                subsystem: "dev.fovea.tests",
                maximumActiveIntervals: 2
            ),
            emitter: emitter
        )

        await sink.record(
            DiagnosticEvent(kind: .fetchStarted, keyDigest: String(repeating: "1", count: 64))
        )
        await sink.record(
            DiagnosticEvent(kind: .decodeStarted, keyDigest: String(repeating: "2", count: 64))
        )
        await sink.record(
            DiagnosticEvent(kind: .fetchStarted, keyDigest: String(repeating: "3", count: 64))
        )

        let boundedCount = await sink.activeIntervalCount()
        XCTAssertEqual(boundedCount, 2)
        let beforeDrop = await emitter.signposts
        XCTAssertEqual(beforeDrop.map(\.operation), [.begin, .begin, .end, .begin])
        XCTAssertTrue(beforeDrop[2].message.contains("active-signpost-capacity"))

        await sink.record(
            DiagnosticEvent(
                kind: .diagnosticsDropped,
                itemCount: 1,
                reason: "external-sink-backpressure"
            )
        )

        let remainingCount = await sink.activeIntervalCount()
        XCTAssertEqual(remainingCount, 0)
        let afterDrop = await emitter.signposts
        XCTAssertEqual(afterDrop.suffix(3).map(\.operation), [.end, .end, .event])
    }

    func testIntervalSequenceOverflowRebasesBeforeCapacityEviction() async throws {
        let emitter = RecordingOSLogDiagnosticsEmitter()
        let sink = OSLogDiagnosticsSink(
            configuration: try OSLogDiagnosticsConfiguration(
                subsystem: "dev.fovea.tests",
                maximumActiveIntervals: 2
            ),
            emitter: emitter,
            initialIntervalSequence: UInt64.max - 1
        )
        let first = String(repeating: "1", count: 64)
        let second = String(repeating: "2", count: 64)
        let third = String(repeating: "3", count: 64)

        await sink.record(DiagnosticEvent(kind: .fetchStarted, keyDigest: first))
        await sink.record(DiagnosticEvent(kind: .decodeStarted, keyDigest: second))
        await sink.record(DiagnosticEvent(kind: .fetchStarted, keyDigest: third))

        let signposts = await emitter.signposts
        XCTAssertEqual(signposts.map(\.operation), [.begin, .begin, .end, .begin])
        XCTAssertEqual(signposts[2].id, 1, "The oldest interval must be evicted after rebasing")
        let activeCount = await sink.activeIntervalCount()
        XCTAssertEqual(activeCount, 2)
    }

    func testTerminalWithoutStartEmitsPointInsteadOfUnbalancedEnd_DIAG_PT_005() async throws {
        let emitter = RecordingOSLogDiagnosticsEmitter()
        let sink = OSLogDiagnosticsSink(
            configuration: try OSLogDiagnosticsConfiguration(subsystem: "dev.fovea.tests"),
            emitter: emitter
        )

        await sink.record(
            DiagnosticEvent(
                kind: .decodeFailed,
                keyDigest: String(repeating: "d", count: 64),
                reason: "decode-failed"
            )
        )

        let signposts = await emitter.signposts
        XCTAssertEqual(signposts.count, 1)
        XCTAssertEqual(signposts[0].operation, .event)
        XCTAssertEqual(signposts[0].interval, .decode)
    }

    func testCorrelationSamplingIsStableAndCriticalFailuresBypassSampling_DIAG_PT_009() async throws
    {
        let emitter = RecordingOSLogDiagnosticsEmitter()
        let sink = OSLogDiagnosticsSink(
            configuration: try OSLogDiagnosticsConfiguration(
                subsystem: "dev.fovea.tests",
                sampling: .oneIn(2),
                signpostsEnabled: false
            ),
            emitter: emitter
        )
        let sampled = "0000000000000002" + String(repeating: "0", count: 48)
        let skipped = "0000000000000001" + String(repeating: "0", count: 48)

        await sink.record(DiagnosticEvent(kind: .fetchStarted, keyDigest: sampled))
        await sink.record(DiagnosticEvent(kind: .fetchCompleted, keyDigest: sampled))
        await sink.record(DiagnosticEvent(kind: .fetchStarted, keyDigest: skipped))
        await sink.record(DiagnosticEvent(kind: .fetchCompleted, keyDigest: skipped))
        await sink.record(
            DiagnosticEvent(
                kind: .fetchFailed,
                keyDigest: skipped,
                reason: "transport-failed"
            )
        )

        let logs = await emitter.logs
        XCTAssertEqual(logs.map(\.level), [.debug, .info, .error])
        XCTAssertTrue(logs[0].message.contains("trace=0000000000000002"))
        XCTAssertTrue(logs[1].message.contains("trace=0000000000000002"))
        XCTAssertTrue(logs[2].message.contains("trace=0000000000000001"))
    }

    func testOSLogMessagePreservesBoundedProtocolTokenAlphabet_DIAG_PT_001() async throws {
        let emitter = RecordingOSLogDiagnosticsEmitter()
        let sink = OSLogDiagnosticsSink(
            configuration: try OSLogDiagnosticsConfiguration(
                subsystem: "dev.fovea.tests",
                signpostsEnabled: false
            ),
            emitter: emitter
        )

        await sink.record(
            DiagnosticEvent(
                kind: .fetchCompleted,
                networkProtocolNames: ["H2", "http/1.1", "QUIC_v1", "h3-29", "H2"]
            )
        )

        let logs = await emitter.logs
        let message = try XCTUnwrap(logs.first?.message)
        XCTAssertTrue(message.contains("protocols=h2,http/1.1,quic_v1,h3-29"))
    }

    func testOSLogMessageRevalidatesDynamicFieldsAndNeverExportsFreeFormText_DIAG_PT_001()
        async throws
    {
        let emitter = RecordingOSLogDiagnosticsEmitter()
        let sink = OSLogDiagnosticsSink(
            configuration: try OSLogDiagnosticsConfiguration(
                subsystem: "dev.fovea.tests",
                signpostsEnabled: false
            ),
            emitter: emitter
        )

        await sink.record(
            DiagnosticEvent(
                kind: .pipelineFailed,
                keyDigest: "https://secret.example/path?token=abc",
                reason: "Bearer secret@example.test",
                networkProtocolNames: ["h2", "secret@example.test"],
                failureCategory: .transport,
                failureStage: .transport,
                failureDisposition: .terminal
            )
        )

        let message = await emitter.logs.first?.message
        XCTAssertNotNil(message)
        XCTAssertFalse(message?.contains("trace=") == true)
        XCTAssertTrue(message?.contains("reason=invalid-reason-code") == true)
        XCTAssertTrue(message?.contains("protocols=h2") == true)
        XCTAssertFalse(message?.contains("secret") == true)
        XCTAssertFalse(message?.contains("token") == true)
        XCTAssertFalse(message?.contains("example.test") == true)
    }
}

private func assertSignpost(
    _ signpost: RecordedOSLogSignpost,
    operation: OSLogDiagnosticsOperation,
    interval: OSLogDiagnosticsInterval,
    id: UInt64,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(signpost.operation, operation, file: file, line: line)
    XCTAssertEqual(signpost.interval, interval, file: file, line: line)
    XCTAssertEqual(signpost.id, id, file: file, line: line)
}

private struct RecordedOSLogMessage: Sendable {
    let level: OSLogDiagnosticsLevel
    let message: String
}

private struct RecordedOSLogSignpost: Sendable {
    let operation: OSLogDiagnosticsOperation
    let interval: OSLogDiagnosticsInterval
    let id: UInt64
    let message: String
}

private actor RecordingOSLogDiagnosticsEmitter: OSLogDiagnosticsEmitting {
    private(set) var logs: [RecordedOSLogMessage] = []
    private(set) var signposts: [RecordedOSLogSignpost] = []
    private var nextSignpostID: UInt64 = 1

    package func makeSignpostID() -> UInt64 {
        defer { nextSignpostID += 1 }
        return nextSignpostID
    }

    package func emitLog(level: OSLogDiagnosticsLevel, message: String) {
        logs.append(RecordedOSLogMessage(level: level, message: message))
    }

    package func emitSignpost(
        operation: OSLogDiagnosticsOperation,
        interval: OSLogDiagnosticsInterval,
        id: UInt64,
        message: String
    ) {
        signposts.append(
            RecordedOSLogSignpost(
                operation: operation,
                interval: interval,
                id: id,
                message: message
            )
        )
    }
}
