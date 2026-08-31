import CryptoKit
import Foundation
import XCTest

@_spi(FoveaBenchmarking) @testable import FoveaCore

final class T100DiagnosticsSinkAdoptionTests: XCTestCase {
    func testFixedSaltRedactionMatchesLegacyFormatter_DIAG_AUTH_PT_001() async throws {
        let downstream = T100DiagnosticsCaptureSink()
        let salt = Data("t100-diagnostics-fixed-salt".utf8)
        let stableDigest = String(repeating: "a", count: 64)
        let sink = RedactingDiagnosticsSink(downstream: downstream, salt: salt)

        await sink.record(DiagnosticEvent(kind: .fetchStarted, keyDigest: stableDigest))

        var material = Data("fovea-diagnostic-correlation-v1\u{0}".utf8)
        material.append(salt)
        material.append(0)
        material.append(contentsOf: stableDigest.utf8)
        let expected = SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
        let events = await downstream.snapshot()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.keyDigest, expected)
        XCTAssertNotEqual(events.first?.keyDigest, stableDigest)
    }

    func testInlineBenchmarkSinkBypassesBufferedRelay_DIAG_AUTH_PT_002() async throws {
        let downstream = T100InlineBenchmarkCaptureSink()
        let sink = nonBlockingDiagnosticsSink(downstream)
        XCTAssertTrue(sink is T100InlineBenchmarkCaptureSink)

        let event = DiagnosticEvent(
            kind: .fetchCompleted,
            keyDigest: String(repeating: "b", count: 64)
        )
        await sink.record(event)
        let events = await downstream.snapshot()
        XCTAssertEqual(events, [event])
    }

    func testInlineBenchmarkSinkBypassesPipelineRedaction_DIAG_AUTH_PT_003() async throws {
        let downstream = T100InlineBenchmarkCaptureSink()
        let sink = pipelineDiagnosticsSink(downstream)
        XCTAssertTrue(sink is T100InlineBenchmarkCaptureSink)

        let event = DiagnosticEvent(
            kind: .decodeCompleted,
            keyDigest: String(repeating: "c", count: 64)
        )
        await sink.record(event)
        let events = await downstream.snapshot()
        XCTAssertEqual(events, [event])
        XCTAssertEqual(events.first?.keyDigest, String(repeating: "c", count: 64))
    }
}

private actor T100DiagnosticsCaptureSink: DiagnosticsSink {
    private var events: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) {
        events.append(event)
    }

    func snapshot() -> [DiagnosticEvent] {
        events
    }
}

private actor T100InlineBenchmarkCaptureSink: InlineBenchmarkDiagnosticsSink {
    private var events: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) {
        events.append(event)
    }

    func snapshot() -> [DiagnosticEvent] {
        events
    }
}
