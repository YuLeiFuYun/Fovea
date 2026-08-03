import AkashicCore
import AkashicDisk
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import FoveaStorage
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class DiagnosticsTests: XCTestCase {
    func testBoundedDiagnosticsDropsOldestEvent() async {
        let first = String(repeating: "1", count: 64)
        let second = String(repeating: "2", count: 64)
        let third = String(repeating: "3", count: 64)
        let sink = BoundedDiagnosticsSink(capacity: 2)
        await sink.record(DiagnosticEvent(kind: .fetchStarted, keyDigest: first))
        await sink.record(DiagnosticEvent(kind: .fetchCompleted, keyDigest: second))
        await sink.record(DiagnosticEvent(kind: .decodeCompleted, keyDigest: third))

        let events = await sink.snapshot()
        let dropped = await sink.droppedEventCount
        XCTAssertEqual(events.map(\.event.keyDigest), [second, third])
        XCTAssertEqual(dropped, 1)
    }

    func testDiagnosticSequenceOverflowRebasesVisibleRingWithoutWrapping() async {
        let first = String(repeating: "1", count: 64)
        let second = String(repeating: "2", count: 64)
        let third = String(repeating: "3", count: 64)
        let sink = BoundedDiagnosticsSink(capacity: 2, initialSequence: UInt64.max - 1)
        await sink.record(DiagnosticEvent(kind: .fetchStarted, keyDigest: first))
        await sink.record(DiagnosticEvent(kind: .fetchCompleted, keyDigest: second))
        await sink.record(DiagnosticEvent(kind: .decodeCompleted, keyDigest: third))

        let events = await sink.snapshot()
        XCTAssertEqual(events.map(\.sequence), [2, 3])
        XCTAssertEqual(events.map(\.event.keyDigest), [second, third])
    }

    func testBoundedDiagnosticsClampsHostileCapacityWithoutUnboundedAllocation() async {
        let sink = BoundedDiagnosticsSink(capacity: Int.max)
        for _ in 0...65_536 {
            await sink.record(DiagnosticEvent(kind: .fetchStarted))
        }

        let events = await sink.snapshot()
        let dropped = await sink.droppedEventCount
        XCTAssertEqual(events.count, 65_536)
        XCTAssertEqual(dropped, 1)
    }

    func testDiagnosticEventRejectsInvalidNumericAndProtocolFields() {
        let event = DiagnosticEvent(
            kind: .fetchCompleted,
            statusCode: 99,
            byteCount: -1,
            itemCount: -2,
            sourcePixelCount: 0,
            outputPixelCount: -3,
            targetWidth: 0,
            targetHeight: -4,
            attempt: 0,
            transactionCount: -1,
            networkProtocolNames: ["H2", "h2", "bad protocol", String(repeating: "x", count: 17)],
            reusedConnectionCount: -1,
            proxyConnectionCount: -1,
            cellularTransactionCount: -1,
            expensiveTransactionCount: -1,
            constrainedTransactionCount: -1,
            redirectCount: -1
        )

        XCTAssertNil(event.statusCode)
        XCTAssertNil(event.byteCount)
        XCTAssertNil(event.itemCount)
        XCTAssertNil(event.sourcePixelCount)
        XCTAssertNil(event.outputPixelCount)
        XCTAssertNil(event.targetWidth)
        XCTAssertNil(event.targetHeight)
        XCTAssertNil(event.attempt)
        XCTAssertNil(event.transactionCount)
        XCTAssertEqual(event.networkProtocolNames, ["h2"])
        XCTAssertNil(event.reusedConnectionCount)
        XCTAssertNil(event.proxyConnectionCount)
        XCTAssertNil(event.cellularTransactionCount)
        XCTAssertNil(event.expensiveTransactionCount)
        XCTAssertNil(event.constrainedTransactionCount)
        XCTAssertNil(event.redirectCount)
    }

    func testDiagnosticEventBoundsHostilePositiveValues() {
        let event = DiagnosticEvent(
            kind: .fetchCompleted,
            keyDigest: "https://secret.example/path?token=abc",
            byteCount: Int.max,
            itemCount: Int.max,
            sourcePixelCount: Int.max,
            outputPixelCount: Int.max,
            targetWidth: Int.max,
            targetHeight: Int.max,
            attempt: Int.max,
            retryDelayNanoseconds: UInt64.max,
            durationNanoseconds: UInt64.max,
            transactionCount: Int.max,
            networkProtocolNames: ["H3", "h3", "bad protocol"],
            reusedConnectionCount: Int.max,
            proxyConnectionCount: Int.max,
            cellularTransactionCount: Int.max,
            expensiveTransactionCount: Int.max,
            constrainedTransactionCount: Int.max,
            redirectCount: Int.max,
            domainLookupDurationNanoseconds: UInt64.max,
            connectionDurationNanoseconds: UInt64.max,
            secureConnectionDurationNanoseconds: UInt64.max,
            requestDurationNanoseconds: UInt64.max,
            timeToFirstByteNanoseconds: UInt64.max,
            responseDurationNanoseconds: UInt64.max
        )

        XCTAssertNil(event.keyDigest)
        XCTAssertEqual(event.byteCount, 1_073_741_824)
        XCTAssertEqual(event.itemCount, 1_000_000)
        XCTAssertEqual(event.sourcePixelCount, 1_000_000_000)
        XCTAssertEqual(event.outputPixelCount, 1_000_000_000)
        XCTAssertEqual(event.targetWidth, 65_536)
        XCTAssertEqual(event.targetHeight, 65_536)
        XCTAssertEqual(event.attempt, TransportRetryLimits.maximumAttempts)
        XCTAssertEqual(event.retryDelayNanoseconds, 86_400_000_000_000)
        XCTAssertEqual(event.durationNanoseconds, 86_400_000_000_000)
        XCTAssertEqual(event.transactionCount, 4_096)
        XCTAssertEqual(event.networkProtocolNames, ["h3"])
        XCTAssertEqual(event.reusedConnectionCount, 4_096)
        XCTAssertEqual(event.proxyConnectionCount, 4_096)
        XCTAssertEqual(event.redirectCount, 4_096)
        XCTAssertEqual(event.responseDurationNanoseconds, 86_400_000_000_000)
    }

    func testDecodedDiagnosticEventRejectsExcessiveProtocolCandidates() throws {
        let object: [String: Any] = [
            "schemaVersion": 17,
            "kind": "fetchCompleted",
            "networkProtocolNames": Array(repeating: "h2", count: 65),
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(DiagnosticEvent.self, from: data))
    }

    func testDecodedDiagnosticEventReappliesSanitizationAndRejectsUnknownSchema() throws {
        let json = """
            {
              "schemaVersion": 17,
              "kind": "pipelineFailed",
              "keyDigest": "https://secret.example/path?token=abc",
              "statusCode": 99,
              "byteCount": -1,
              "reason": "Bearer decoded-secret@example.test",
              "networkProtocolNames": ["H2", "decoded-secret@example.test"]
            }
            """
        let decoded = try JSONDecoder().decode(
            DiagnosticEvent.self,
            from: Data(json.utf8)
        )
        XCTAssertNil(decoded.keyDigest)
        XCTAssertNil(decoded.statusCode)
        XCTAssertNil(decoded.byteCount)
        XCTAssertEqual(decoded.reason, "invalid-reason-code")
        XCTAssertEqual(decoded.networkProtocolNames, ["h2"])

        let unknown = json.replacingOccurrences(
            of: "\"schemaVersion\": 17", with: "\"schemaVersion\": 1799")
        XCTAssertThrowsError(
            try JSONDecoder().decode(DiagnosticEvent.self, from: Data(unknown.utf8))
        )
    }

    func testDiagnosticReasonRejectsFreeFormSensitiveText() {
        let event = DiagnosticEvent(
            kind: .pipelineFailed,
            reason: "Bearer secret-token@example.test/path"
        )

        XCTAssertEqual(event.reason, "invalid-reason-code")
    }

    func testFetchCompletionPropagatesSanitizedNetworkMetrics_DIAG_PT_012() async throws {
        let diagnostics = BoundedDiagnosticsSink(capacity: 32)
        let body = try makePNG()
        let metrics = TransportNetworkMetrics(
            taskDurationNanoseconds: 123_000_000,
            transactionCount: 2,
            negotiatedProtocolNames: ["h2"],
            reusedConnectionCount: 1,
            proxyConnectionCount: 1,
            cellularTransactionCount: 0,
            expensiveTransactionCount: 0,
            constrainedTransactionCount: 0,
            redirectCount: 1,
            domainLookupDurationNanoseconds: 1_000,
            connectionDurationNanoseconds: 2_000,
            secureConnectionDurationNanoseconds: 3_000,
            requestDurationNanoseconds: 4_000,
            timeToFirstByteNanoseconds: 5_000,
            responseDurationNanoseconds: 6_000
        )
        let (pipeline, _, _, _) = try await makePipeline(
            stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                    body: body,
                    networkMetrics: metrics
                )
            ],
            diagnostics: diagnostics
        )
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/network-metrics.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "diagnostic-network-metrics"
        )

        _ = try await pipeline.image(for: request)

        let events = await diagnostics.snapshot().map(\.event)
        let completed = try XCTUnwrap(events.first { $0.kind == .fetchCompleted })
        XCTAssertEqual(completed.durationNanoseconds, 123_000_000)
        XCTAssertEqual(completed.transactionCount, 2)
        XCTAssertEqual(completed.networkProtocolNames, ["h2"])
        XCTAssertEqual(completed.reusedConnectionCount, 1)
        XCTAssertEqual(completed.proxyConnectionCount, 1)
        XCTAssertEqual(completed.redirectCount, 1)
        XCTAssertEqual(completed.domainLookupDurationNanoseconds, 1_000)
        XCTAssertEqual(completed.connectionDurationNanoseconds, 2_000)
        XCTAssertEqual(completed.secureConnectionDurationNanoseconds, 3_000)
        XCTAssertEqual(completed.requestDurationNanoseconds, 4_000)
        XCTAssertEqual(completed.timeToFirstByteNanoseconds, 5_000)
        XCTAssertEqual(completed.responseDurationNanoseconds, 6_000)
    }

    func testFetchFailurePublishesCorrelatedTerminalEvent_DIAG_PT_005() async throws {
        let diagnostics = BoundedDiagnosticsSink(capacity: 32)
        let (pipeline, _, _, _) = try await makePipeline(
            stubs: [],
            configuration: PipelineConfiguration(
                transportRetryPolicy: TransportRetryPolicy(maximumAttempts: 1)
            ),
            diagnostics: diagnostics
        )
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/fetch-failure.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )

        do {
            _ = try await pipeline.image(for: request)
            XCTFail("空 transport 必须失败")
        } catch {}

        let events = await diagnostics.snapshot().map(\.event)
        let started = try XCTUnwrap(events.first { $0.kind == .fetchStarted })
        let failed = try XCTUnwrap(events.first { $0.kind == .fetchFailed })
        XCTAssertEqual(failed.keyDigest, started.keyDigest)
        XCTAssertEqual(failed.failureStage, .transport)
        XCTAssertNotEqual(failed.failureDisposition, .cancelled)
    }

    func testDecodeFailurePublishesCorrelatedTerminalEvent_DIAG_PT_005() async throws {
        let diagnostics = BoundedDiagnosticsSink(capacity: 32)
        let (pipeline, _, _, _) = try await makePipeline(
            stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                    body: Data("not-an-image".utf8)
                )
            ],
            diagnostics: diagnostics
        )
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/decode-failure.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )

        do {
            _ = try await pipeline.image(for: request)
            XCTFail("损坏图像必须失败")
        } catch {}

        let events = await diagnostics.snapshot().map(\.event)
        let started = try XCTUnwrap(events.first { $0.kind == .decodeStarted })
        let failed = try XCTUnwrap(events.first { $0.kind == .decodeFailed })
        XCTAssertEqual(failed.keyDigest, started.keyDigest)
        XCTAssertEqual(failed.failureStage, .probe)
        XCTAssertEqual(failed.failureCategory, .securityLimit)
    }

    func testPipelineDiagnosticsUseEphemeralCorrelationIDs_DIAG_PT_002() async throws {
        let body = try makePNG()
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/private-correlation.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )
        let firstSink = BoundedDiagnosticsSink()
        let secondSink = BoundedDiagnosticsSink()
        let first = try await makePipeline(
            stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                    body: body
                )
            ],
            diagnostics: firstSink
        ).0
        let second = try await makePipeline(
            stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                    body: body
                )
            ],
            diagnostics: secondSink
        ).0

        _ = try await first.image(for: request)
        _ = try await second.image(for: request)

        let firstIDs = await firstSink.snapshot().compactMap(\.event.keyDigest)
        let secondIDs = await secondSink.snapshot().compactMap(\.event.keyDigest)
        XCTAssertFalse(firstIDs.isEmpty)
        XCTAssertFalse(secondIDs.isEmpty)
        XCTAssertFalse(firstIDs.contains(request.fetchVariantKey.digestHex))
        XCTAssertFalse(firstIDs.contains(request.fetchExecutionKey.digestHex))
        XCTAssertNotEqual(Set(firstIDs), Set(secondIDs))
    }

    func testFailedCorruptRecordRemovalIsObservable() async throws {
        let body = try makePNG()
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/removal-diagnostics.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )
        let record = makeRepresentationRecord(
            namespace: request.namespace.value,
            baseKeyDigest: request.fetchBaseKey.digestHex,
            variantKeyDigest: request.fetchVariantKey.digestHex,
            expiresAt: Date().addingTimeInterval(3_600),
            contentID: ContentID(data: body).description,
            payloadLength: body.count
        )
        let diagnostics = BoundedDiagnosticsSink(capacity: 64)
        let pipeline = FoveaPipeline(
            transport: FakeHTTPTransport(stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                    body: body
                )
            ]),
            encodedStore: FailingReadEncodedStore(),
            recordStore: RemovalFailingRecordStore(record: record),
            diagnostics: diagnostics,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )

        _ = try await pipeline.image(for: request)

        let events = await diagnostics.snapshot().map(\.event)
        XCTAssertTrue(
            events.contains {
                $0.kind == .cacheReadFailed && $0.reason == "original-encoded-read"
            }
        )
        XCTAssertTrue(
            events.contains {
                $0.kind == .cacheWriteFailed && $0.reason == "record-removal-failed"
            }
        )
    }

    func testSlowExternalSinkCannotDelayImageDelivery_DIAG_PT_003() async throws {
        let body = try makePNG()
        let root = try makeTemporaryDirectory()
        let pipeline = FoveaPipeline(
            transport: FakeHTTPTransport(stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                    body: body
                )
            ]),
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")),
            recordStore: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")),
            diagnostics: SlowDiagnosticsSink(),
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/slow-diagnostics.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )

        let clock = ContinuousClock()
        let started = clock.now
        _ = try await pipeline.image(for: request)
        let elapsed = started.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .milliseconds(350))
    }

    func testExternalRelayReportsBoundedDrops_DIAG_PT_004() async throws {
        let downstream = CapturingSlowDiagnosticsSink(delay: .milliseconds(50))
        let relay = BufferedDiagnosticsRelay(downstream: downstream, capacity: 1)
        for index in 0..<20 {
            await relay.record(DiagnosticEvent(kind: .fetchQueued, byteCount: index))
        }
        let dropped = await relay.droppedEventCount
        XCTAssertGreaterThan(dropped, 0)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var summary: DiagnosticEvent?
        while summary == nil, clock.now < deadline {
            // 每次 record 都先尝试发布尚未发送的 drop summary；循环等待的是
            // “缓冲槽可用并观察到 summary”这一语义条件，而不是固定调度时长。
            await relay.record(DiagnosticEvent(kind: .fetchCompleted))
            try await Task.sleep(for: .milliseconds(25))
            summary = await downstream.events.first { $0.kind == .diagnosticsDropped }
        }

        let observed = try XCTUnwrap(summary)
        XCTAssertNil(observed.byteCount)
        XCTAssertGreaterThan(observed.itemCount ?? 0, 0)
    }

    func testPipelineDiagnosticsDistinguishFetchDecodeAndMemoryHit() async throws {
        let sink = BoundedDiagnosticsSink(capacity: 64)
        let body = try makePNG(width: 400, height: 300)
        let (pipeline, _, _, _) = try await makePipeline(
            stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                    body: body
                )
            ],
            diagnostics: sink
        )
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.com/diagnostics.png")),
            target: try TargetPixels(width: 100, height: 75),
            appID: "tests"
        )

        _ = try await pipeline.image(for: request)
        _ = try await pipeline.image(for: request)

        let events = await sink.snapshot().map(\.event)
        XCTAssertEqual(events.filter { $0.kind == .fetchStarted }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .fetchCompleted }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .decodeCompleted }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .probeCompleted }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .originalEncodedHit }.count, 0)
        XCTAssertEqual(events.filter { $0.kind == .renderedMemoryHit }.count, 1)

        let decode = try XCTUnwrap(events.first { $0.kind == .decodeCompleted })
        XCTAssertEqual(decode.sourcePixelCount, 120_000)
        XCTAssertEqual(decode.outputPixelCount, 7_500)
        XCTAssertEqual(decode.targetWidth, 100)
        XCTAssertEqual(decode.targetHeight, 75)
    }
}

private actor SlowDiagnosticsSink: DiagnosticsSink {
    func record(_ event: DiagnosticEvent) async {
        try? await Task.sleep(for: .milliseconds(500))
    }
}

private actor CapturingSlowDiagnosticsSink: DiagnosticsSink {
    private let delay: Duration
    private(set) var events: [DiagnosticEvent] = []

    init(delay: Duration) {
        self.delay = delay
    }

    func record(_ event: DiagnosticEvent) async {
        try? await Task.sleep(for: delay)
        events.append(event)
    }
}

private actor FailingReadEncodedStore: OriginalEncodedStoring {
    func read(contentID: String, namespace: String) async throws -> Data {
        throw AkashicError.integrityMismatch
    }

    func commit(data: Data, contentID: String, namespace: String) async throws -> StoredBlob {
        throw AkashicError.storageUnavailable
    }

    func physicalID(contentID: String, namespace: String) async -> PhysicalBlobID? { nil }
    func remove(contentID: String, namespace: String) async throws {}
    func removeAll(namespace: String) async throws {}
}

private actor RemovalFailingRecordStore: RepresentationRecordStoring {
    private let record: RepresentationRecord

    init(record: RepresentationRecord) {
        self.record = record
    }

    func records(
        for baseKeyDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async -> [RepresentationRecord] {
        guard record.baseKeyDigest == baseKeyDigest,
            record.securityNamespaceFingerprint
                == StorageNamespaceFingerprint(namespace: namespace),
            record.namespaceGeneration == namespaceGeneration
        else { return [] }
        return [record]
    }

    func put(_ record: RepresentationRecord) async throws {}

    func containsReference(
        to contentID: String,
        namespace: String,
        excludingVariantDigest: String?
    ) async -> Bool {
        true
    }

    func remove(
        _ variantDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async throws {
        throw AkashicError.storageUnavailable
    }

    func removeAll(namespace: String) async throws {}
}
