import AkashicCore
import AkashicDisk
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import FoveaStorage
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class EncodedDataCoordinatorTests: XCTestCase {
    func testFreshReusableRecordReturnsEncodedBytesWithoutNetwork() async throws {
        let body = try makePNG(red: 91)
        let diagnostics = BoundedDiagnosticsSink(capacity: 32)
        let (pipeline, transport, _, _) = try await makePipeline(
            stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                    body: body
                )
            ],
            diagnostics: diagnostics
        )
        let request = try makeRequest(path: "fresh-hit")

        _ = try await pipeline.image(for: request)
        let encoded = try await pipeline.encodedData(for: request)

        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(encoded, body)
        XCTAssertEqual(requestCount, 1)
        let hitRecorded = await diagnostics.snapshot().contains {
            $0.event.kind == .originalEncodedHit
        }
        XCTAssertTrue(hitRecorded)
    }

    func testAuthorizedNetworkDataBindsContentAndGeneration_W5_PT_110() async throws {
        let body = try makePNG(red: 110)
        let (pipeline, transport, _, _) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                body: body
            )
        ])
        let request = try makeRequest(path: "authorized-network")

        let result = try await pipeline.authorizedEncodedData(for: request)

        XCTAssertEqual(result.data, body)
        XCTAssertEqual(result.contentID, ContentID(data: body))
        XCTAssertEqual(result.namespace, request.namespace)
        XCTAssertEqual(result.generation, NamespaceGeneration(0))
        XCTAssertEqual(result.baseKeyDigest, request.fetchBaseDigest)
        XCTAssertEqual(result.requestExecutionKeyDigest, request.fetchExecutionKey.digestHex)
        XCTAssertNil(result.representationKeyDigest)
        XCTAssertEqual(result.origin, .network)
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testAuthorizedCacheDataBindsSelectedRepresentation_W5_PT_111() async throws {
        let body = try makePNG(red: 111)
        let (pipeline, transport, _, records) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                body: body
            )
        ])
        let request = try makeRequest(path: "authorized-cache")

        _ = try await pipeline.image(for: request)
        let storedRecord = await records.record(for: request.fetchVariantKey.digestHex)
        let record = try XCTUnwrap(storedRecord)
        let result = try await pipeline.authorizedEncodedData(for: request)

        XCTAssertEqual(result.data, body)
        XCTAssertEqual(result.contentID, ContentID(data: body))
        XCTAssertEqual(result.namespace, request.namespace)
        XCTAssertEqual(result.generation, NamespaceGeneration(record.namespaceGeneration))
        XCTAssertEqual(result.baseKeyDigest, record.baseKeyDigest)
        XCTAssertEqual(result.requestExecutionKeyDigest, request.fetchExecutionKey.digestHex)
        XCTAssertEqual(result.representationKeyDigest, record.variantKeyDigest)
        XCTAssertEqual(result.origin, .reusableCache)
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testAuthorizedDataGenerationAdvancesAfterNamespaceRevocation_W5_PT_112() async throws {
        let firstBody = try makePNG(red: 112)
        let secondBody = try makePNG(red: 113)
        let (pipeline, transport, _, _) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                body: firstBody
            ),
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                body: secondBody
            ),
        ])
        let request = try makeRequest(path: "authorized-revocation")

        let first = try await pipeline.authorizedEncodedData(for: request)
        try await pipeline.revoke(namespace: request.namespace)
        let second = try await pipeline.authorizedEncodedData(for: request)

        XCTAssertEqual(first.generation, NamespaceGeneration(0))
        XCTAssertEqual(second.generation, NamespaceGeneration(1))
        XCTAssertEqual(first.contentID, ContentID(data: firstBody))
        XCTAssertEqual(second.contentID, ContentID(data: secondBody))
        XCTAssertNotEqual(first.contentID, second.contentID)
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 2)
    }

    func testAuthorizedCacheReadFailsWhenNamespaceIsRevokedInFlight_W5_PT_113() async throws {
        let body = try makePNG(red: 114)
        let request = try makeRequest(path: "authorized-inflight-revocation")
        let record = makeRepresentationRecord(
            namespace: request.namespace.value,
            namespaceGeneration: 0,
            baseKeyDigest: request.fetchBaseDigest,
            variantKeyDigest: request.fetchVariantKey.digestHex,
            requestTime: Date().addingTimeInterval(-10),
            responseTime: Date().addingTimeInterval(-9),
            expiresAt: Date().addingTimeInterval(3_600),
            contentID: ContentID(data: body).description,
            payloadLength: body.count,
            contentType: "image/png"
        )
        let encodedStore = GatedAuthorizedEncodedStore(data: body)
        let recordStore = FixedAuthorizedRecordStore(record: record)
        let transport = FakeHTTPTransport(stubs: [])
        let registry = NamespaceRegistry()
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: encodedStore,
            recordStore: recordStore,
            namespaceRegistry: registry,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        let load = Task {
            try await pipeline.authorizedEncodedData(for: request)
        }
        try await waitUntil("授权编码缓存读取已进入存储层") {
            await encodedStore.hasStartedRead
        }

        try await pipeline.revoke(namespace: request.namespace)
        await encodedStore.releaseRead()

        do {
            _ = try await load.value
            XCTFail("撤销期间完成的缓存读取不得返回授权资产")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .namespaceRevoked)
            XCTAssertEqual(failure.stage, .revocation)
        }
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 0)
    }

    func testCorruptFreshBlobIsRemovedBeforeNetworkFallback() async throws {
        let firstBody = try makePNG(red: 41)
        let fallbackBody = try makePNG(red: 42)
        let diagnostics = BoundedDiagnosticsSink(capacity: 32)
        let root = try makeTemporaryDirectory("encoded-data-corrupt-fallback")
        let (pipeline, transport, encodedStore, records) = try await makePipeline(
            stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                    body: firstBody
                ),
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                    body: fallbackBody
                ),
            ],
            root: root,
            diagnostics: diagnostics
        )
        let request = try makeRequest(path: "corrupt-fallback")

        _ = try await pipeline.image(for: request)
        let storedRecord = await records.record(for: request.fetchVariantKey.digestHex)
        let record = try XCTUnwrap(storedRecord)
        let storedPhysicalID = await encodedStore.physicalID(
            contentID: record.contentID,
            namespace: request.namespace.value
        )
        let physicalID = try XCTUnwrap(storedPhysicalID)
        let blobURL = root.appendingPathComponent(
            "encoded/blobs/\(physicalID.foveaStorageFileName)"
        )
        try Data("corrupt".utf8).write(to: blobURL)

        let result = try await pipeline.encodedData(for: request)

        let requestCount = await transport.capturedRequests().count
        let removedRecord = await records.record(for: request.fetchVariantKey.digestHex)
        XCTAssertEqual(result, fallbackBody)
        XCTAssertEqual(requestCount, 2)
        XCTAssertNil(removedRecord)
        let readFailureRecorded = await diagnostics.snapshot().contains {
            $0.event.kind == .cacheReadFailed && $0.event.reason == "encoded-data-read"
        }
        XCTAssertTrue(readFailureRecorded)
    }

    func testOnlyIfCachedMissFailsBeforeNetwork() async throws {
        let (pipeline, transport, _, _) = try await makePipeline(stubs: [])
        let request = try ImageRequest(
            url: try XCTUnwrap(URL(string: "https://example.test/encoded/only-if-cached")),
            target: try TargetPixels(width: 20, height: 20),
            namespace: .publicNamespace(appID: "encoded-data-tests"),
            cachePolicy: .onlyIfCached
        )

        do {
            _ = try await pipeline.encodedData(for: request)
            XCTFail("only-if-cached 未命中时不得访问网络")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .cacheRead)
            XCTAssertEqual(failure.stage, .cacheLookup)
            XCTAssertEqual(failure.reasonCode, "only-if-cached-miss")
        }
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 0)
    }

    func testEncodedDataRejectsNonImageContentType() async throws {
        let body = Data("not-an-image".utf8)
        let (pipeline, transport, _, _) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "text/plain", "Cache-Control": "no-store"],
                body: body
            )
        ])

        do {
            _ = try await pipeline.encodedData(for: makeRequest(path: "non-image"))
            XCTFail("原编码入口不得接受明确的非图片 Content-Type")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .http)
            XCTAssertEqual(failure.stage, .responseValidation)
            XCTAssertEqual(failure.reasonCode, "non-image-response")
        }
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testMissingContentTypeReturnsBytesAndRecordsAnomaly() async throws {
        let body = Data("opaque-image-bytes".utf8)
        let diagnostics = BoundedDiagnosticsSink(capacity: 16)
        let (pipeline, _, _, _) = try await makePipeline(
            stubs: [
                .init(statusCode: 200, headers: ["Cache-Control": "no-store"], body: body)
            ],
            diagnostics: diagnostics
        )

        let result = try await pipeline.encodedData(for: makeRequest(path: "missing-content-type"))

        XCTAssertEqual(result, body)
        let anomaly = await diagnostics.snapshot().contains {
            $0.event.kind == .responseAnomaly && $0.event.reason == "missing-content-type"
        }
        XCTAssertTrue(anomaly)
    }

    func testNonSuccessStatusUsesStructuredHTTPFailure() async throws {
        let (pipeline, _, _, _) = try await makePipeline(stubs: [
            .init(statusCode: 404, headers: [:], body: Data())
        ])

        do {
            _ = try await pipeline.encodedData(for: makeRequest(path: "missing"))
            XCTFail("非 200 响应不得作为原编码数据返回")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .http)
            XCTAssertEqual(failure.stage, .responseValidation)
            XCTAssertEqual(failure.statusCode, 404)
            XCTAssertEqual(failure.reasonCode, "unsupported-http-status")
        }
    }

    private func makeRequest(path: String) throws -> ImageRequest {
        try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/encoded/\(path)")),
            target: TargetPixels(width: 20, height: 20),
            appID: "encoded-data-tests"
        )
    }
}

private actor GatedAuthorizedEncodedStore: OriginalEncodedStoring {
    private let data: Data
    private var readStarted = false
    private var readReleased = false
    private var readContinuation: CheckedContinuation<Void, Never>?

    init(data: Data) {
        self.data = data
    }

    var hasStartedRead: Bool { readStarted }

    func read(contentID: String, namespace: String) async throws -> Data {
        readStarted = true
        if !readReleased {
            await withCheckedContinuation { continuation in
                readContinuation = continuation
            }
        }
        return data
    }

    func releaseRead() {
        readReleased = true
        readContinuation?.resume()
        readContinuation = nil
    }

    func commit(data: Data, contentID: String, namespace: String) async throws -> StoredBlob {
        try StoredBlob(physicalID: PhysicalBlobID(), byteCount: data.count, wasCreated: true)
    }

    func physicalID(contentID: String, namespace: String) async -> PhysicalBlobID? { nil }
    func remove(contentID: String, namespace: String) async throws {}
    func removeAll(namespace: String) async throws {}
}

private actor FixedAuthorizedRecordStore: RepresentationRecordStoring {
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
    ) async -> Bool { true }

    func remove(
        _ variantDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async throws {}

    func removeAll(namespace: String) async throws {}
}
