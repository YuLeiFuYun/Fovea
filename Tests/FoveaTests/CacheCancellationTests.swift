import AkashicCore
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import FoveaStorage
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class CacheCancellationTests: XCTestCase {
    func testFreshCacheCancellationDoesNotDeleteRecordOrStartNetwork() async throws {
        let request = try makeRequest(path: "fresh-cancellation.png")
        let record = makeRecord(for: request, expiresAt: Date().addingTimeInterval(3_600))
        let records = CancellationTrackingRecordStore(record: record)
        let transport = CountingTransport(statusCode: 500)
        let pipeline = makePipeline(transport: transport, records: records)

        await assertCancelled { try await pipeline.image(for: request) }
        await assertCancelled { try await pipeline.encodedData(for: request) }

        let removals = await records.removalCount
        let requests = await transport.requestCount
        XCTAssertEqual(removals, 0)
        XCTAssertEqual(requests, 0)
    }

    func test304CachedBodyCancellationDoesNotDeleteRecordOrRetryUnconditionally() async throws {
        let request = try makeRequest(path: "validated-cancellation.png")
        let record = makeRecord(for: request, expiresAt: Date().addingTimeInterval(-60), etag: "v1")
        let records = CancellationTrackingRecordStore(record: record)
        let transport = CountingTransport(statusCode: 304)
        let pipeline = makePipeline(transport: transport, records: records)

        await assertCancelled { try await pipeline.image(for: request) }

        let removals = await records.removalCount
        let requests = await transport.requestCount
        XCTAssertEqual(removals, 0)
        XCTAssertEqual(requests, 1)
    }

    private func makeRequest(path: String) throws -> ImageRequest {
        try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/\(path)")),
            target: TargetPixels(width: 20, height: 20),
            appID: "cache-cancellation-tests"
        )
    }

    private func makeRecord(
        for request: ImageRequest,
        expiresAt: Date,
        etag: String? = nil
    ) -> RepresentationRecord {
        makeRepresentationRecord(
            namespace: request.namespace.value,
            baseKeyDigest: request.fetchBaseKey.digestHex,
            variantKeyDigest: request.fetchVariantKey.digestHex,
            requestTime: Date().addingTimeInterval(-120),
            responseTime: Date().addingTimeInterval(-119),
            expiresAt: expiresAt,
            etag: etag,
            contentID: ContentID(data: Data("cached".utf8)).description,
            payloadLength: 6
        )
    }

    private func makePipeline(
        transport: CountingTransport,
        records: CancellationTrackingRecordStore
    ) -> FoveaPipeline {
        FoveaPipeline(
            transport: transport,
            encodedStore: CancellingReadEncodedStore(),
            recordStore: records,
            profileAccessPolicy: .unrestricted,
            decoder: ImageIOImageDecoder()
        )
    }

    private func assertCancelled<T: Sendable>(
        _ operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected cancellation", file: file, line: line)
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .cancelled, file: file, line: line)
            XCTAssertEqual(failure.disposition, .cancelled, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private actor CancellingReadEncodedStore: OriginalEncodedStoring {
    func read(contentID: String, namespace: String) async throws -> Data {
        throw CancellationError()
    }

    func commit(data: Data, contentID: String, namespace: String) async throws -> StoredBlob {
        XCTFail("Cancellation path must not commit")
        throw CancellationError()
    }

    func physicalID(contentID: String, namespace: String) async -> PhysicalBlobID? { nil }
    func remove(contentID: String, namespace: String) async throws {}
    func removeAll(namespace: String) async throws {}
}

private actor CancellationTrackingRecordStore: RepresentationRecordStoring {
    private let record: RepresentationRecord
    private(set) var removalCount = 0

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
    ) async throws {
        removalCount += 1
    }

    func removeAll(namespace: String) async throws {}
}

private actor CountingTransport: HTTPTransporting {
    nonisolated let reusePolicy = TransportReusePolicy.reusable(
        contextIdentifier: "cache-cancellation-tests"
    )
    private let statusCode: Int
    private(set) var requestCount = 0

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    func execute(_ request: TransportRequest) async throws -> TransportResponse {
        requestCount += 1
        return TransportResponse(
            head: try TransportResponseHead(
                statusCode: statusCode,
                headers: statusCode == 304 ? ["ETag": "v1"] : [:],
                url: request.request.url
            ),
            body: Data(),
            metrics: TransportMetrics(receivedBytes: 0, spilledToDisk: false)
        )
    }
}
