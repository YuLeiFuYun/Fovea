import Foundation
import FoveaObservability
import XCTest

@_spi(DetailedDiagnostics) @testable import FoveaCore

final class T100DiagnosticsVocabularyAdoptionTests: XCTestCase {
    func testAddedDiagnosticKindsRoundTripUnderSchema19_T100_AUTH_PT_008() throws {
        XCTAssertEqual(DiagnosticEvent.currentSchemaVersion, 19)
        let addedKinds: [DiagnosticEventKind] = [
            .fetchSubscriberReceived,
            .fetchSubscriberReleased,
            .decodeResourceEstimateCompleted,
            .responseValidated,
            .responseBodyMaterialized,
            .progressiveFinalizationReady,
        ]

        for kind in addedKinds {
            let event = DiagnosticEvent(
                kind: kind,
                keyDigest: String(repeating: "a", count: 64),
                byteCount: 7,
                itemCount: 3,
                reason: "t100-vocabulary"
            )
            let encoded = try JSONEncoder().encode(event)
            let decoded = try JSONDecoder().decode(DiagnosticEvent.self, from: encoded)
            XCTAssertEqual(decoded.kind, kind)
            XCTAssertEqual(decoded.schemaVersion, 19)
            XCTAssertEqual(decoded.keyDigest, String(repeating: "a", count: 64))
            XCTAssertEqual(decoded.byteCount, 7)
            XCTAssertEqual(decoded.itemCount, 3)
            XCTAssertEqual(decoded.reason, "t100-vocabulary")
        }
    }

    func testDiagnosticSchemaRejectsAdjacentVersionsAndPreservesExistingRawValues_T100_AUTH_PT_009()
        throws
    {
        XCTAssertEqual(DiagnosticEventKind.fetchQueued.rawValue, "fetchQueued")
        XCTAssertEqual(DiagnosticEventKind.fetchCompleted.rawValue, "fetchCompleted")
        XCTAssertEqual(DiagnosticEventKind.decodeQueued.rawValue, "decodeQueued")
        XCTAssertEqual(DiagnosticEventKind.decodeCompleted.rawValue, "decodeCompleted")
        XCTAssertEqual(DiagnosticEventKind.cacheReadFailed.rawValue, "cacheReadFailed")
        XCTAssertEqual(DiagnosticEventKind.pipelineFailed.rawValue, "pipelineFailed")

        let encoded = try JSONEncoder().encode(DiagnosticEvent(kind: .pipelineFailed))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for unsupportedVersion in [18, 20] {
            object["schemaVersion"] = unsupportedVersion
            let hostile = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(DiagnosticEvent.self, from: hostile))
        }
    }

    func testAddedDiagnosticKindsMapToExplicitOSLogIntervals_T100_AUTH_PT_010() async throws {
        let emitter = T100DiagnosticsVocabularyEmitter()
        let sink = OSLogDiagnosticsSink(
            configuration: try OSLogDiagnosticsConfiguration(
                subsystem: "dev.fovea.t100-diagnostics",
                sampling: .all,
                signpostsEnabled: true
            ),
            emitter: emitter
        )
        let cases: [(DiagnosticEventKind, OSLogDiagnosticsInterval)] = [
            (.fetchSubscriberReceived, .fetch),
            (.fetchSubscriberReleased, .fetch),
            (.decodeResourceEstimateCompleted, .decode),
            (.responseValidated, .pipeline),
            (.responseBodyMaterialized, .pipeline),
            (.progressiveFinalizationReady, .pipeline),
        ]

        for (kind, _) in cases {
            await sink.record(DiagnosticEvent(kind: kind))
        }

        let signposts = await emitter.snapshot()
        XCTAssertEqual(signposts.count, cases.count)
        for (index, expected) in cases.enumerated() {
            XCTAssertEqual(signposts[index].operation, .event)
            XCTAssertEqual(signposts[index].interval, expected.1)
        }
    }
}

private struct T100RecordedDiagnosticsSignpost: Sendable {
    let operation: OSLogDiagnosticsOperation
    let interval: OSLogDiagnosticsInterval
}

private actor T100DiagnosticsVocabularyEmitter: OSLogDiagnosticsEmitting {
    private var nextIdentifier: UInt64 = 0
    private var signposts: [T100RecordedDiagnosticsSignpost] = []

    func makeSignpostID() async -> UInt64 {
        nextIdentifier += 1
        return nextIdentifier
    }

    func emitLog(level: OSLogDiagnosticsLevel, message: String) async {}

    func emitSignpost(
        operation: OSLogDiagnosticsOperation,
        interval: OSLogDiagnosticsInterval,
        id: UInt64,
        message: String
    ) async {
        signposts.append(
            T100RecordedDiagnosticsSignpost(operation: operation, interval: interval)
        )
    }

    func snapshot() -> [T100RecordedDiagnosticsSignpost] { signposts }
}
