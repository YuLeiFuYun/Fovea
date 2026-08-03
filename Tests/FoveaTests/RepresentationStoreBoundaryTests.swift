import AkashicCore
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaStorage
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class RepresentationStoreBoundaryTests: XCTestCase {
    func testCrossNamespaceCustomRecordIsRejectedBeforeEncodedRead() async throws {
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/custom-record-boundary.png")),
            target: TargetPixels(width: 20, height: 20),
            appID: "record-boundary-tests"
        )
        let networkBody = Data("network-body".utf8)
        let maliciousRecord = makeRepresentationRecord(
            namespace: "another-account",
            baseKeyDigest: request.fetchBaseKey.digestHex,
            variantKeyDigest: request.fetchVariantKey.digestHex,
            expiresAt: Date().addingTimeInterval(3_600),
            contentID: ContentID(data: Data("private-cached-body".utf8)).description,
            payloadLength: Data("private-cached-body".utf8).count
        )
        let encodedStore = SecretReturningEncodedStore()
        let transport = FixedEncodedTransport(body: networkBody)
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: encodedStore,
            recordStore: UntrustedRecordStore(records: [maliciousRecord]),
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )

        let result = try await pipeline.encodedData(for: request)

        XCTAssertEqual(result, networkBody)
        let readCount = await encodedStore.readCount
        let requestCount = await transport.requestCount
        XCTAssertEqual(readCount, 0)
        XCTAssertEqual(requestCount, 1)
    }

    func testConflictingDuplicateVariantFromCustomStoreIsRejectedDeterministically() async throws {
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/ambiguous-record.png")),
            target: TargetPixels(width: 20, height: 20),
            appID: "record-boundary-tests"
        )
        let firstBody = Data("cached-first".utf8)
        let secondBody = Data("cached-second".utf8)
        let networkBody = Data("network-body".utf8)
        let first = makeRepresentationRecord(
            namespace: request.namespace.value,
            baseKeyDigest: request.fetchBaseKey.digestHex,
            variantKeyDigest: request.fetchVariantKey.digestHex,
            expiresAt: Date().addingTimeInterval(3_600),
            contentID: ContentID(data: firstBody).description,
            payloadLength: firstBody.count
        )
        let second = makeRepresentationRecord(
            namespace: request.namespace.value,
            baseKeyDigest: request.fetchBaseKey.digestHex,
            variantKeyDigest: request.fetchVariantKey.digestHex,
            expiresAt: Date().addingTimeInterval(3_600),
            contentID: ContentID(data: secondBody).description,
            payloadLength: secondBody.count
        )
        let encodedStore = SecretReturningEncodedStore()
        let transport = FixedEncodedTransport(body: networkBody)
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: encodedStore,
            recordStore: UntrustedRecordStore(records: [second, first]),
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )

        let result = try await pipeline.encodedData(for: request)

        XCTAssertEqual(result, networkBody)
        let readCount = await encodedStore.readCount
        let requestCount = await transport.requestCount
        XCTAssertEqual(readCount, 0)
        XCTAssertEqual(requestCount, 1)
    }

    func testDecodedRepresentationRecordRejectsSemanticCorruption() throws {
        let record = makeRepresentationRecord(
            namespace: "tests",
            baseKeyDigest: String(repeating: "a", count: 64),
            variantKeyDigest: String(repeating: "b", count: 64),
            contentID: ContentID(data: Data()).description,
            payloadLength: 0
        )
        let encoded = try JSONEncoder().encode(record)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["payloadLength"] = -1
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                RepresentationRecord.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }
}

private actor UntrustedRecordStore: RepresentationRecordStoring {
    let stored: [RepresentationRecord]
    init(records: [RepresentationRecord]) { self.stored = records }

    func records(
        for baseKeyDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async -> [RepresentationRecord] { stored }
    func put(_ record: RepresentationRecord) async throws {}
    func containsReference(
        to contentID: String,
        namespace: String,
        excludingVariantDigest: String?
    ) async -> Bool { false }
    func remove(
        _ variantDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async throws {}
    func removeAll(namespace: String) async throws {}
}

private actor SecretReturningEncodedStore: OriginalEncodedStoring {
    private(set) var readCount = 0
    func read(contentID: String, namespace: String) async throws -> Data {
        readCount += 1
        return Data("private-cached-body".utf8)
    }
    func commit(data: Data, contentID: String, namespace: String) async throws -> StoredBlob {
        try StoredBlob(physicalID: PhysicalBlobID(), byteCount: data.count, wasCreated: true)
    }
    func physicalID(contentID: String, namespace: String) async -> PhysicalBlobID? { nil }
    func remove(contentID: String, namespace: String) async throws {}
    func removeAll(namespace: String) async throws {}
}

private actor FixedEncodedTransport: HTTPTransporting {
    nonisolated let reusePolicy = TransportReusePolicy.reusable(
        contextIdentifier: "representation-store-boundary"
    )
    let body: Data
    private(set) var requestCount = 0
    init(body: Data) { self.body = body }

    func execute(_ request: TransportRequest) async throws -> TransportResponse {
        requestCount += 1
        return TransportResponse(
            head: try TransportResponseHead(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                url: request.request.url
            ),
            body: body,
            metrics: TransportMetrics(receivedBytes: body.count, spilledToDisk: false)
        )
    }
}
