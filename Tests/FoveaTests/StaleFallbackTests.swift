import AkashicDisk
import CryptoKit
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class StaleFallbackTests: XCTestCase {
    func testStaleFallbackWindowIsBoundedAcrossConstructionAndDecoding() throws {
        let policy = StaleFallbackPolicy.networkResilient(
            maximumStalenessSeconds: UInt64.max
        )
        XCTAssertEqual(policy.maximumStalenessSeconds, 365 * 24 * 60 * 60)

        let data = try JSONEncoder().encode(StaleFallbackPolicy.disabled)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["maximumStalenessSeconds"] = 365 * 24 * 60 * 60 + 1
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                StaleFallbackPolicy.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testRetryableNetworkFailureUsesBoundedStaleWithoutRefreshingMetadataErrPt005() async throws
    {
        let body = try makePNG(red: 180)
        let root = try makeTemporaryDirectory()
        let clock = MutableStaleClock(Date(timeIntervalSince1970: 1_000))
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let initialTransport = StaleSequenceTransport(steps: [
            .response(statusCode: 200, headers: staleHeaders, body: body)
        ])
        let request = try publicRequest("network-fallback.png")
        let initial = makePipeline(
            encoded: encoded,
            records: records,
            transport: initialTransport,
            clock: clock,
            staleWindow: 60
        )
        _ = try await initial.image(for: request)
        let beforeCandidates = await records.records(
            for: request.fetchBaseKey.digestHex,
            namespace: request.namespace.value,
            namespaceGeneration: 0
        )
        let before = try XCTUnwrap(beforeCandidates.first)

        await clock.set(Date(timeIntervalSince1970: 1_030))
        let diagnostics = BoundedDiagnosticsSink(capacity: 64)
        let failingTransport = StaleSequenceTransport(steps: [
            .failure(URLError(.notConnectedToInternet))
        ])
        let fallback = makePipeline(
            encoded: encoded,
            records: records,
            transport: failingTransport,
            clock: clock,
            staleWindow: 60,
            diagnostics: diagnostics
        )

        let image = try await fallback.image(for: request)
        XCTAssertGreaterThan(try centerRedComponent(of: image.cgImage), 120)
        let afterCandidates = await records.records(
            for: request.fetchBaseKey.digestHex,
            namespace: request.namespace.value,
            namespaceGeneration: 0
        )
        let after = try XCTUnwrap(afterCandidates.first)
        XCTAssertEqual(after, before)
        let failingRequestCount = await failingTransport.requestCount
        XCTAssertEqual(failingRequestCount, 1)
        let events = await diagnostics.snapshot().map(\.event)
        XCTAssertEqual(events.filter { $0.kind == .staleFallbackUsed }.count, 1)
        XCTAssertEqual(
            events.first { $0.kind == .staleFallbackUsed }?.reason, "url-session-transport")
    }

    func testStaleFallbackIsDecidedPerSubscriber_ERR_PT_006() async throws {
        let fixture = try await makeStaleFixture(path: "per-subscriber.png", staleWindow: 60)
        await fixture.clock.set(Date(timeIntervalSince1970: 1_010))
        let transport = StaleSequenceTransport(steps: [
            .delayedFailure(URLError(.notConnectedToInternet), 40_000_000)
        ])
        let pipeline = makePipeline(
            encoded: fixture.encoded,
            records: fixture.records,
            transport: transport,
            clock: fixture.clock,
            staleWindow: 60
        )
        let denied = try ImageRequest.publicImage(
            url: fixture.request.url,
            target: fixture.request.target,
            appID: "tests",
            stalePolicy: .disallow
        )

        let allowedTask = Task { try await pipeline.image(for: fixture.request) }
        let deniedTask = Task { try await pipeline.image(for: denied) }
        let allowedImage = try await allowedTask.value
        XCTAssertGreaterThan(try centerRedComponent(of: allowedImage.cgImage), 120)
        do {
            _ = try await deniedTask.value
            XCTFail("禁止 stale 的订阅者不得接收共享失败后的 stale 表示")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .transport)
            XCTAssertEqual(failure.reasonCode, "url-session-transport")
        }

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testStaleWindowExpiryReturnsOriginalFailureErrPt005() async throws {
        let fixture = try await makeStaleFixture(path: "expired-fallback.png", staleWindow: 10)
        await fixture.clock.set(Date(timeIntervalSince1970: 1_011))
        let transport = StaleSequenceTransport(steps: [
            .failure(URLError(.notConnectedToInternet))
        ])
        let pipeline = makePipeline(
            encoded: fixture.encoded,
            records: fixture.records,
            transport: transport,
            clock: fixture.clock,
            staleWindow: 10
        )

        do {
            _ = try await pipeline.image(for: fixture.request)
            XCTFail("Expired stale representation must not be returned")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .transport)
            XCTAssertEqual(failure.disposition, .retryable)
        }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testMustRevalidateAndNoCacheNeverUseStaleFallback() async throws {
        for directive in ["must-revalidate, max-age=0", "no-cache"] {
            let root = try makeTemporaryDirectory()
            let clock = MutableStaleClock(Date(timeIntervalSince1970: 1_000))
            let encoded = try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")
            )
            let records = try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")
            )
            let transport = StaleSequenceTransport(steps: [
                .response(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "image/png",
                        "Cache-Control": directive,
                        "ETag": "v1",
                    ],
                    body: try makePNG()
                ),
                .failure(URLError(.networkConnectionLost)),
            ])
            let pipeline = makePipeline(
                encoded: encoded,
                records: records,
                transport: transport,
                clock: clock,
                staleWindow: 3_600
            )
            let request = try publicRequest("requires-revalidation-\(UUID().uuidString).png")

            _ = try await pipeline.image(for: request)
            do {
                _ = try await pipeline.image(for: request)
                XCTFail("\(directive) must prohibit stale fallback after failed validation")
            } catch let failure as PipelineFailure {
                XCTAssertEqual(failure.category, .transport)
            }
        }
    }

    func test304CanReplaceRevalidationRequirement() async throws {
        let root = try makeTemporaryDirectory()
        let clock = MutableStaleClock(Date(timeIntervalSince1970: 1_000))
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded")
        )
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let transport = StaleSequenceTransport(steps: [
            .response(
                statusCode: 200,
                headers: [
                    "Content-Type": "image/png",
                    "Cache-Control": "must-revalidate, max-age=0",
                    "ETag": "v1",
                ],
                body: try makePNG()
            ),
            .response(
                statusCode: 304,
                headers: ["Cache-Control": "max-age=3600"],
                body: Data()
            ),
        ])
        let pipeline = makePipeline(
            encoded: encoded,
            records: records,
            transport: transport,
            clock: clock,
            staleWindow: 3_600
        )
        let request = try publicRequest("304-revalidation-reset.png")

        _ = try await pipeline.image(for: request)
        _ = try await pipeline.image(for: request)

        let candidates = await records.records(
            for: request.fetchBaseKey.digestHex,
            namespace: request.namespace.value,
            namespaceGeneration: 0
        )
        let stored = try XCTUnwrap(candidates.first)
        XCTAssertFalse(stored.requiresRevalidation)
        let currentDate = await clock.now()
        XCTAssertTrue(stored.isFresh(at: currentDate))
    }

    func testAuthorizationFailureNeverUsesStaleErrPt005() async throws {
        let fixture = try await makeStaleFixture(path: "auth-fallback.png", staleWindow: 60)
        await fixture.clock.set(Date(timeIntervalSince1970: 1_010))
        let transport = StaleSequenceTransport(steps: [
            .response(statusCode: 401, headers: [:], body: Data())
        ])
        let pipeline = makePipeline(
            encoded: fixture.encoded,
            records: fixture.records,
            transport: transport,
            clock: fixture.clock,
            staleWindow: 60
        )

        do {
            _ = try await pipeline.image(for: fixture.request)
            XCTFail("Authorization failures must not serve stale private content")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.statusCode, 401)
            XCTAssertEqual(failure.disposition, .terminal)
        }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testCorruptStaleBlobIsRemovedAndOriginalFailureSurfacesErrPt005() async throws {
        let fixture = try await makeStaleFixture(path: "corrupt-fallback.png", staleWindow: 60)
        let candidates = await fixture.records.records(
            for: fixture.request.fetchBaseKey.digestHex,
            namespace: fixture.request.namespace.value,
            namespaceGeneration: 0
        )
        let record = try XCTUnwrap(candidates.first)
        let storedPhysicalID = await fixture.encoded.physicalID(
            contentID: record.contentID,
            namespace: fixture.request.namespace.value
        )
        let physicalID = try XCTUnwrap(storedPhysicalID)
        let blobURL = fixture.root
            .appendingPathComponent("encoded/blobs")
            .appendingPathComponent(physicalID.foveaStorageFileName)
        try Data("corrupt".utf8).write(to: blobURL, options: .atomic)
        await fixture.clock.set(Date(timeIntervalSince1970: 1_010))

        let transport = StaleSequenceTransport(steps: [
            .failure(URLError(.networkConnectionLost))
        ])
        let pipeline = makePipeline(
            encoded: fixture.encoded,
            records: fixture.records,
            transport: transport,
            clock: fixture.clock,
            staleWindow: 60
        )

        do {
            _ = try await pipeline.image(for: fixture.request)
            XCTFail("Corrupt stale bytes must never be displayed")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .transport)
            XCTAssertEqual(failure.reasonCode, "url-session-transport")
        }
        let remaining = await fixture.records.records(
            for: fixture.request.fetchBaseKey.digestHex,
            namespace: fixture.request.namespace.value,
            namespaceGeneration: 0
        )
        XCTAssertTrue(remaining.isEmpty)
    }

    private func makeStaleFixture(
        path: String,
        staleWindow: UInt64
    ) async throws -> StaleFixture {
        let root = try makeTemporaryDirectory()
        let clock = MutableStaleClock(Date(timeIntervalSince1970: 1_000))
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let transport = StaleSequenceTransport(steps: [
            .response(statusCode: 200, headers: staleHeaders, body: try makePNG(red: 160))
        ])
        let request = try publicRequest(path)
        let pipeline = makePipeline(
            encoded: encoded,
            records: records,
            transport: transport,
            clock: clock,
            staleWindow: staleWindow
        )
        _ = try await pipeline.image(for: request)
        return StaleFixture(
            root: root,
            clock: clock,
            encoded: encoded,
            records: records,
            request: request
        )
    }

    private func makePipeline(
        encoded: AkashicOriginalEncodedStore,
        records: RepresentationRecordStore,
        transport: any HTTPTransporting,
        clock: MutableStaleClock,
        staleWindow: UInt64,
        diagnostics: any DiagnosticsSink = NullDiagnosticsSink()
    ) -> FoveaPipeline {
        FoveaPipeline(
            configuration: PipelineConfiguration(
                transportRetryPolicy: TransportRetryPolicy(maximumAttempts: 1),
                staleFallbackPolicy: .networkResilient(
                    maximumStalenessSeconds: staleWindow
                )
            ),
            transport: transport,
            encodedStore: encoded,
            recordStore: records,
            namespaceRegistry: NamespaceRegistry(),
            diagnostics: diagnostics,
            profileAccessPolicy: .unrestricted,
            decoder: ImageIOImageDecoder(),
            clock: clock
        )
    }

    private func publicRequest(_ path: String) throws -> ImageRequest {
        try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/\(path)")),
            target: TargetPixels(width: 20, height: 20),
            appID: "tests"
        )
    }

    private var staleHeaders: [String: String] {
        ["Content-Type": "image/png", "Cache-Control": "max-age=0"]
    }
}

private struct StaleFixture {
    let root: URL
    let clock: MutableStaleClock
    let encoded: AkashicOriginalEncodedStore
    let records: RepresentationRecordStore
    let request: ImageRequest
}

private actor MutableStaleClock: WallClock {
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date { value }

    func set(_ value: Date) {
        self.value = value
    }
}

private actor StaleSequenceTransport: HTTPTransporting {
    nonisolated let reusePolicy = TransportReusePolicy.reusable(
        contextIdentifier: "tests-stale-sequence-v1"
    )

    enum Step: Sendable {
        case failure(URLError)
        case delayedFailure(URLError, UInt64)
        case response(statusCode: Int, headers: [String: String], body: Data)
    }

    private var steps: [Step]
    private(set) var requestCount = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    func execute(_ request: TransportRequest) async throws -> TransportResponse {
        requestCount += 1
        guard !steps.isEmpty else { throw URLError(.resourceUnavailable) }
        switch steps.removeFirst() {
        case .failure(let error):
            throw error
        case .delayedFailure(let error, let nanoseconds):
            try await Task.sleep(nanoseconds: nanoseconds)
            throw error
        case .response(let statusCode, let headers, let body):
            return TransportResponse(
                head: try TransportResponseHead(
                    statusCode: statusCode,
                    headers: headers,
                    url: request.request.url
                ),
                body: body,
                metrics: TransportMetrics(receivedBytes: body.count, spilledToDisk: false)
            )
        }
    }
}
