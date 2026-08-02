import AkashicDisk
import CryptoKit
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class ResourceLimitTests: XCTestCase {
    func testPipelineRevalidatesCustomTransportBodyLimit() async throws {
        let body = Data(repeating: 0x41, count: 2_048)
        let transport = TrackingTransport(body: body, delay: .zero)
        let root = try makeTemporaryDirectory()
        let pipeline = FoveaPipeline(
            configuration: PipelineConfiguration(
                maximumTransportBytes: 1_024,
                transportMemoryThreshold: 512
            ),
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")
            ),
            recordStore: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")
            ),
            profileAccessPolicy: .unrestricted,
            decoder: ImageIOImageDecoder()
        )
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/oversized-custom-transport.png")),
            target: TargetPixels(width: 20, height: 20),
            appID: "tests"
        )

        do {
            _ = try await pipeline.image(for: request)
            XCTFail("The pipeline must not trust a custom transport to enforce body limits")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .securityLimit)
            XCTAssertEqual(failure.stage, .transport)
            XCTAssertEqual(failure.reasonCode, "encoded-body-limit-exceeded")
        }
    }

    func testNamespaceCapacityRejectsBeforeNetwork_RES_PT_018() async throws {
        let body = try makePNG()
        let (pipeline, transport, _, _) = try await makePipeline(
            stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                    body: body
                )
            ],
            configuration: PipelineConfiguration(maximumTrackedNamespaces: 1)
        )
        let first = try ImageRequest(
            url: XCTUnwrap(URL(string: "https://example.test/namespace-first.png")),
            target: TargetPixels(width: 20, height: 20),
            namespace: SecurityNamespaceID("namespace-first"),
            authorizationContext: .public
        )
        let rejected = try ImageRequest(
            url: XCTUnwrap(URL(string: "https://example.test/namespace-rejected.png")),
            target: TargetPixels(width: 20, height: 20),
            namespace: SecurityNamespaceID("namespace-rejected"),
            authorizationContext: .public
        )

        _ = try await pipeline.image(for: first)
        do {
            _ = try await pipeline.image(for: rejected)
            XCTFail("A new namespace must fail before network when the registry is full")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .resourceLimit)
            XCTAssertEqual(failure.stage, .requestValidation)
            XCTAssertEqual(failure.reasonCode, "namespace-registry-capacity-exceeded")
        }

        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }
    func testFetchConcurrencyNeverExceedsStaticLimit_RES_PT_001() async throws {
        let body = try makePNG()
        let transport = TrackingTransport(body: body, delay: .milliseconds(80))
        let root = try makeTemporaryDirectory()
        let pipeline = FoveaPipeline(
            configuration: PipelineConfiguration(
                maximumConcurrentFetches: 2,
                maximumConcurrentDecodes: 8
            ),
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")),
            recordStore: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")),
            profileAccessPolicy: .unrestricted,
            decoder: ImageIOImageDecoder()
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let request = try ImageRequest.publicImage(
                        url: try XCTUnwrap(URL(string: "https://example.test/fetch-\(index).png")),
                        target: try TargetPixels(width: 20 + index, height: 20 + index),
                        appID: "tests"
                    )
                    _ = try await pipeline.image(for: request)
                }
            }
            try await group.waitForAll()
        }

        let maximum = await transport.maximumConcurrentRequests
        XCTAssertEqual(maximum, 2)
    }

    func testCancelledPermitWaiterDoesNotLeakOrStartNetwork_RES_PT_002() async throws {
        let body = try makePNG()
        let transport = TrackingTransport(body: body, delay: .milliseconds(120))
        let diagnostics = BoundedDiagnosticsSink(capacity: 32)
        let root = try makeTemporaryDirectory()
        let pipeline = FoveaPipeline(
            configuration: PipelineConfiguration(
                maximumConcurrentFetches: 1,
                maximumConcurrentDecodes: 2
            ),
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")),
            recordStore: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")),
            diagnostics: diagnostics,
            profileAccessPolicy: .unrestricted,
            decoder: ImageIOImageDecoder()
        )

        let firstRequest = try makeRequest(path: "first")
        let cancelledRequest = try makeRequest(path: "cancelled")
        let afterCancelRequest = try makeRequest(path: "after-cancel")
        let first = Task {
            try await pipeline.image(for: firstRequest)
        }
        try await waitUntil("首个 transport 请求开始") {
            await transport.requestCount == 1
        }
        let firstStartedCount = await transport.requestCount
        XCTAssertEqual(firstStartedCount, 1)

        let cancelled = Task {
            try await pipeline.image(for: cancelledRequest)
        }
        try await waitUntil("取消目标进入 fetch permit 队列") {
            await diagnostics.snapshot().filter { $0.event.kind == .fetchQueued }.count >= 2
        }
        let queuedCount = await diagnostics.snapshot().filter { $0.event.kind == .fetchQueued }
            .count
        XCTAssertGreaterThanOrEqual(queuedCount, 2)
        cancelled.cancel()

        do {
            _ = try await cancelled.value
            XCTFail("Cancelled permit waiter must not continue")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .cancelled)
            XCTAssertEqual(failure.disposition, .cancelled)
        }

        _ = try await first.value
        _ = try await pipeline.image(for: afterCancelRequest)

        let requestCount = await transport.requestCount
        let maximum = await transport.maximumConcurrentRequests
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(maximum, 1)
    }

    func testFetchPermitWaitDoesNotInflateHTTPResponseDelay_HTTP_CONF_AGE_004() async throws {
        let body = try makePNG()
        let transport = TrackingTransport(
            body: body,
            delay: .milliseconds(80),
            headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
        )
        let root = try makeTemporaryDirectory()
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records"))
        let clock = SequenceWallClock([
            Date(timeIntervalSince1970: 10),
            Date(timeIntervalSince1970: 20),
            Date(timeIntervalSince1970: 30),
            Date(timeIntervalSince1970: 40),
            Date(timeIntervalSince1970: 50),
            Date(timeIntervalSince1970: 60),
        ])
        let pipeline = FoveaPipeline(
            configuration: PipelineConfiguration(
                maximumConcurrentFetches: 1,
                maximumConcurrentDecodes: 2
            ),
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")),
            recordStore: records,
            namespaceRegistry: NamespaceRegistry(),
            profileAccessPolicy: .unrestricted,
            decoder: ImageIOImageDecoder(),
            clock: clock
        )
        let firstRequest = try makeRequest(path: "clock-first")
        let secondRequest = try makeRequest(path: "clock-second")
        let first = Task { try await pipeline.image(for: firstRequest) }
        try await waitUntil("首个 transport 请求开始") {
            await transport.requestCount == 1
        }
        let firstStartedCount = await transport.requestCount
        XCTAssertEqual(firstStartedCount, 1)
        let second = Task { try await pipeline.image(for: secondRequest) }
        _ = try await first.value
        _ = try await second.value

        let firstRecordValue = await records.record(for: firstRequest.fetchVariantKey.digestHex)
        let secondRecordValue = await records.record(for: secondRequest.fetchVariantKey.digestHex)
        let firstRecord = try XCTUnwrap(firstRecordValue)
        let secondRecord = try XCTUnwrap(secondRecordValue)

        XCTAssertEqual(
            firstRecord.responseTime.timeIntervalSince(firstRecord.requestTime),
            10,
            accuracy: 0.001
        )
        XCTAssertEqual(
            secondRecord.responseTime.timeIntervalSince(secondRecord.requestTime),
            10,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(secondRecord.requestTime, firstRecord.responseTime)
    }

    func testFetchQueueLimitRejectsExcessWaitersWithoutStartingNetwork_RES_PT_001() async throws {
        let body = try makePNG()
        let transport = TrackingTransport(body: body, delay: .milliseconds(120))
        let root = try makeTemporaryDirectory()
        let pipeline = FoveaPipeline(
            configuration: PipelineConfiguration(
                maximumConcurrentFetches: 1,
                maximumConcurrentDecodes: 2,
                maximumQueuedFetches: 0
            ),
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")),
            recordStore: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")),
            profileAccessPolicy: .unrestricted,
            decoder: ImageIOImageDecoder()
        )
        let firstRequest = try makeRequest(path: "queue-first")
        let rejectedRequest = try makeRequest(path: "queue-rejected")
        let first = Task { try await pipeline.image(for: firstRequest) }
        try await waitUntil("占用唯一 fetch permit 的请求开始") {
            await transport.requestCount == 1
        }
        let startedRequestCount = await transport.requestCount
        XCTAssertEqual(startedRequestCount, 1)

        do {
            _ = try await pipeline.image(for: rejectedRequest)
            XCTFail("An exhausted zero-length queue must reject the request")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .resourceLimit)
            XCTAssertEqual(failure.stage, .transport)
            XCTAssertEqual(failure.disposition, .terminal)
            XCTAssertEqual(failure.reasonCode, "fetch-queue-limit-exceeded")
        }

        _ = try await first.value
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testDecodeConcurrencyNeverExceedsStaticLimit_RES_PT_001() async throws {
        let body = try makePNG()
        let transport = TrackingTransport(body: body, delay: .zero)
        let root = try makeTemporaryDirectory()
        let pipeline = FoveaPipeline(
            configuration: PipelineConfiguration(
                maximumConcurrentFetches: 8,
                maximumConcurrentDecodes: 1
            ),
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")),
            recordStore: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")),
            profileAccessPolicy: .unrestricted,
            decoder: DelayedDecoder(delay: 0.08)
        )

        let started = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<3 {
                group.addTask {
                    let request = try ImageRequest.publicImage(
                        url: try XCTUnwrap(URL(string: "https://example.test/decode-\(index).png")),
                        target: try TargetPixels(width: 20 + index, height: 20 + index),
                        appID: "tests"
                    )
                    _ = try await pipeline.image(for: request)
                }
            }
            try await group.waitForAll()
        }
        let elapsed = started.duration(to: .now)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(210))
    }

    func testWorkingSetWaiterDoesNotHoldDecodeCountPermit_RES_PT_014() async throws {
        let workingSetPermits = AsyncPermitPool(limit: 2_000, queueLimit: 8)
        let externalReservation = try await workingSetPermits.acquire(units: 1_000)
        let stage = DecodeStage(
            decoder: ImageIOImageDecoder(),
            limits: DecodeLimits(),
            diagnostics: NullDiagnosticsSink(),
            maximumConcurrentDecodes: 1,
            maximumDecodeWorkingSetBytes: 2_000,
            maximumQueuedDecodes: 8,
            workingSetPermits: workingSetPermits
        )
        let largeData = try makePNG(width: 10, height: 10)
        let smallData = try makePNG(width: 5, height: 5)
        let largeRequest = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/large.png")),
            target: try TargetPixels(width: 10, height: 10),
            appID: "working-set-order"
        )
        let smallRequest = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/small.png")),
            target: try TargetPixels(width: 5, height: 5),
            appID: "working-set-order"
        )

        let large = Task {
            try await stage.image(
                from: largeData,
                contentID: ContentID(data: largeData),
                request: largeRequest,
                generation: NamespaceGeneration(0),
                keyDigest: String(repeating: "a", count: 64)
            )
        }
        try await waitUntil("大任务进入 working-set 队列") {
            await workingSetPermits.queuedCount() == 1
        }
        let queued = await workingSetPermits.queuedCount()
        XCTAssertEqual(queued, 1)

        let completion = CompletionFlag()
        let small = Task {
            let image = try await stage.image(
                from: smallData,
                contentID: ContentID(data: smallData),
                request: smallRequest,
                generation: NamespaceGeneration(0),
                keyDigest: String(repeating: "b", count: 64)
            )
            await completion.markCompleted()
            return image
        }
        try await waitUntil("小任务在释放外部 reservation 前完成") {
            await completion.isCompleted
        }
        let smallCompletedBeforeRelease = await completion.isCompleted

        await externalReservation.release()
        _ = try await large.value
        _ = try await small.value
        XCTAssertTrue(
            smallCompletedBeforeRelease,
            "等待 working-set 的大任务不得继续占有 decode-count 许可"
        )
    }

    func testDecodeWorkingSetIsRejectedBeforePixelAllocation_RES_PT_013() async throws {
        let body = Data("probe-only".utf8)
        let transport = TrackingTransport(body: body, delay: .zero)
        let diagnostics = BoundedDiagnosticsSink(capacity: 32)
        let root = try makeTemporaryDirectory()
        let pipeline = FoveaPipeline(
            configuration: PipelineConfiguration(
                maximumConcurrentFetches: 1,
                maximumConcurrentDecodes: 1,
                maximumDecodeWorkingSetBytes: 1 * 1024 * 1024
            ),
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")),
            recordStore: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")),
            diagnostics: diagnostics,
            profileAccessPolicy: .unrestricted,
            decoder: OverBudgetDecoder()
        )
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/working-set.png")),
            target: try TargetPixels(width: 4_000, height: 4_000),
            appID: "tests"
        )

        do {
            _ = try await pipeline.image(for: request)
            XCTFail("估算 working set 超过 hard cap 时不得进入像素分配")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .resourceLimit)
            XCTAssertEqual(failure.stage, .decode)
            XCTAssertEqual(failure.reasonCode, "decode-working-set-limit-exceeded")
        }

        let events = await diagnostics.snapshot().map(\.event)
        let rejection = events.first { $0.kind == .decodeAdmissionRejected }
        XCTAssertNotNil(rejection)
        XCTAssertGreaterThan(rejection?.byteCount ?? 0, 1 * 1024 * 1024)
    }

    func testDecodeWorkingSetEstimatorAccountsForFillOverscan_RES_PT_013() throws {
        let probe = try ImageProbe(pixelWidth: 4_000, pixelHeight: 1_000, frameCount: 1)
        let target = try TargetPixels(width: 1_000, height: 1_000)
        let fit = FoveaDecodeWorkingSetEstimator.estimatedBytes(
            probe: probe,
            request: ImageDecodeRequest(target: target, contentMode: .fit)
        )
        let fill = FoveaDecodeWorkingSetEstimator.estimatedBytes(
            probe: probe,
            request: ImageDecodeRequest(target: target, contentMode: .fill)
        )

        XCTAssertGreaterThan(fill, fit)
        XCTAssertEqual(fill, 36_000_000)
    }

    private func makeRequest(path: String) throws -> ImageRequest {
        try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/\(path).png")),
            target: TargetPixels(width: 20, height: 20),
            appID: "tests"
        )
    }
}

private final class TrackingTransport: HTTPTransporting, Sendable {
    nonisolated let reusePolicy = TransportReusePolicy.reusable(
        contextIdentifier: "tests-tracking-transport-v1"
    )

    private let tracker = ConcurrencyTracker()
    private let body: Data
    private let delay: Duration
    private let headers: [String: String]

    init(
        body: Data,
        delay: Duration,
        headers: [String: String] = [
            "Content-Type": "image/png",
            "Cache-Control": "no-store",
        ]
    ) {
        self.body = body
        self.delay = delay
        self.headers = headers
    }

    func execute(_ request: TransportRequest) async throws -> TransportResponse {
        await tracker.begin()
        do {
            try await Task.sleep(for: delay)
            try Task.checkCancellation()
            await tracker.end()
        } catch {
            await tracker.end()
            throw error
        }
        return TransportResponse(
            head: try TransportResponseHead(
                statusCode: 200,
                headers: headers,
                url: request.request.url
            ),
            body: body,
            metrics: TransportMetrics(receivedBytes: body.count, spilledToDisk: false)
        )
    }

    var maximumConcurrentRequests: Int { get async { await tracker.maximum } }
    var requestCount: Int { get async { await tracker.total } }
}

extension ResourceLimitTests {
    func testCustomDecoderProbeIsRevalidatedAgainstRuntimeLimits() async throws {
        let body = try makePNG(width: 20, height: 20)
        let transport = FakeHTTPTransport(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                body: body
            )
        ])
        let root = try makeTemporaryDirectory()
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")
            ),
            recordStore: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")
            ),
            profileAccessPolicy: .unrestricted,
            decoder: OverFrameProbeDecoder()
        )
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/invalid-custom-probe.png")),
            target: TargetPixels(width: 20, height: 20),
            appID: "resource-limit-tests"
        )

        do {
            _ = try await pipeline.image(for: request)
            XCTFail("A custom decoder must not bypass the runtime frame limit")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .securityLimit)
            XCTAssertEqual(failure.stage, .probe)
            XCTAssertEqual(failure.reasonCode, "frame-limit-exceeded")
        }
    }
}

private struct OverFrameProbeDecoder: ImageDecoding {
    func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
        try ImageProbe(pixelWidth: 20, pixelHeight: 20, frameCount: 2)
    }

    func decode(
        data: Data,
        probe: ImageProbe,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage {
        XCTFail("Decode must not run after an invalid probe postcondition")
        throw ImageCraftError.decodeFailed
    }
}

private actor ConcurrencyTracker {
    private var active = 0
    private(set) var maximum = 0
    private(set) var total = 0

    func begin() {
        active += 1
        total += 1
        maximum = max(maximum, active)
    }

    func end() {
        active -= 1
    }
}

private actor SequenceWallClock: WallClock {
    private var values: [Date]
    private var index = 0

    init(_ values: [Date]) {
        self.values = values
    }

    func now() -> Date {
        guard !values.isEmpty else { return .distantPast }
        defer { index = min(index + 1, values.count - 1) }
        return values[index]
    }
}

private struct DelayedDecoder: ImageDecoding {
    let delay: TimeInterval

    func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
        try ImageIOImageDecoder().probe(data: data, limits: limits)
    }

    func decode(
        data: Data,
        probe: ImageProbe,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage {
        Thread.sleep(forTimeInterval: delay)
        return try ImageIOImageDecoder().decode(
            data: data,
            probe: probe,
            request: request,
            limits: limits
        )
    }
}

private struct OverBudgetDecoder: ImageDecoding {
    func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
        try ImageProbe(pixelWidth: 4_000, pixelHeight: 4_000, frameCount: 1)
    }

    func decode(
        data: Data,
        probe: ImageProbe,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage {
        throw ImageCraftError.decodeFailed
    }
}

private actor CompletionFlag {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

extension ResourceLimitTests {
    func testInvalidBackendResourceEstimateFailsClosedBeforeDecode() async throws {
        let stage = DecodeStage(
            decoder: InvalidResourceEstimateDecoder(),
            limits: .coreV1,
            diagnostics: NullDiagnosticsSink(),
            maximumConcurrentDecodes: 1,
            maximumDecodeWorkingSetBytes: 1_000_000,
            maximumQueuedDecodes: 1
        )
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/invalid-estimate.png")),
            target: TargetPixels(width: 10, height: 10),
            appID: "codec-conformance-tests"
        )

        do {
            _ = try await stage.image(
                from: Data([0]),
                contentID: ContentID(data: Data([0])),
                request: request,
                generation: NamespaceGeneration(0),
                keyDigest: String(repeating: "e", count: 64)
            )
            XCTFail("无效后端资源估计必须在 decode 前失败")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .internalFailure)
            XCTAssertEqual(failure.stage, .decode)
            XCTAssertEqual(failure.reasonCode, "invalid-codec-resource-estimate")
        }
    }
}

private struct InvalidResourceEstimateDecoder: ImageDecoding, ImageCodec {
    let codecDescriptor = ImageCodecDescriptor(
        identifier: ImageCodecIdentifier(rawValue: "test.invalid-resource-estimate"),
        implementationVersion: 1,
        capabilities: .foveaLegacyBaseline
    )

    func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
        try ImageProbe(pixelWidth: 10, pixelHeight: 10, frameCount: 1, format: .png)
    }

    func resourceEstimate(
        probe: ImageProbe,
        request: ImageDecodeRequest
    ) throws -> ImageDecodeResourceEstimate {
        throw ImageCodecContractError.invalidResourceEstimate
    }

    func decode(
        data: Data,
        probe: ImageProbe,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage {
        XCTFail("无效资源估计之后不得调用 decode")
        throw ImageCraftError.decodeFailed
    }
}
