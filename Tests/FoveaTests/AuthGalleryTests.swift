import AkashicCore
import AkashicDisk
import CoreGraphics
import CryptoKit
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import FoveaStorage
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class AuthGalleryTests: XCTestCase {
    func testSameURLIsolatedAcrossAccountsAndLogoutPreservesOtherAccount() async throws {
        let bodyA = try makePNG(red: 230)
        let bodyB = try makePNG(red: 20)
        let origin = CredentialImageOrigin(responses: [
            "Bearer account-a": .init(
                body: bodyA,
                headers: ["Content-Type": "image/png", "Cache-Control": "private, max-age=3600"]
            ),
            "Bearer account-b": .init(
                body: bodyB,
                headers: ["Content-Type": "image/png", "Cache-Control": "private, max-age=3600"]
            ),
        ])
        let root = try makeTemporaryDirectory()
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records"))
        let pipeline = FoveaPipeline(
            transport: origin,
            encodedStore: encoded,
            recordStore: records,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        let url = try XCTUnwrap(URL(string: "https://images.example.test/avatar"))
        let target = try TargetPixels(width: 40, height: 40)
        let accountA = try authenticatedRequest(
            url: url,
            target: target,
            namespace: "account-a",
            principal: "principal-a",
            token: "Bearer account-a"
        )
        let accountB = try authenticatedRequest(
            url: url,
            target: target,
            namespace: "account-b",
            principal: "principal-b",
            token: "Bearer account-b"
        )

        let imageA = try await pipeline.image(for: accountA)
        let imageB = try await pipeline.image(for: accountB)
        let warmA = try await pipeline.image(for: accountA)
        let warmB = try await pipeline.image(for: accountB)

        XCTAssertGreaterThan(try centerRed(imageA.cgImage), 180)
        XCTAssertLessThan(try centerRed(imageB.cgImage), 80)
        XCTAssertGreaterThan(try centerRed(warmA.cgImage), 180)
        XCTAssertLessThan(try centerRed(warmB.cgImage), 80)
        let counts = await origin.requestCounts()
        XCTAssertEqual(counts["Bearer account-a"], 1)
        XCTAssertEqual(counts["Bearer account-b"], 1)

        let recordAValue = await records.record(for: accountA.fetchVariantKey.digestHex)
        let recordBValue = await records.record(for: accountB.fetchVariantKey.digestHex)
        let recordA = try XCTUnwrap(recordAValue)
        let recordB = try XCTUnwrap(recordBValue)
        XCTAssertEqual(
            recordA.securityNamespaceFingerprint,
            StorageNamespaceFingerprint(namespace: "account-a"))
        XCTAssertEqual(
            recordB.securityNamespaceFingerprint,
            StorageNamespaceFingerprint(namespace: "account-b"))
        let physicalAValue = await encoded.physicalID(
            contentID: recordA.contentID,
            namespace: "account-a"
        )
        let physicalBValue = await encoded.physicalID(
            contentID: recordB.contentID,
            namespace: "account-b"
        )
        let physicalA = try XCTUnwrap(physicalAValue)
        let physicalB = try XCTUnwrap(physicalBValue)
        XCTAssertNotEqual(physicalA, physicalB)

        try await pipeline.revoke(namespace: SecurityNamespaceID("account-a"))
        let revokedRecordA = await records.record(for: accountA.fetchVariantKey.digestHex)
        let revokedPhysicalA = await encoded.physicalID(
            contentID: recordA.contentID,
            namespace: "account-a"
        )
        let preservedRecordB = await records.record(for: accountB.fetchVariantKey.digestHex)
        let preservedPhysicalB = await encoded.physicalID(
            contentID: recordB.contentID,
            namespace: "account-b"
        )
        XCTAssertNil(revokedRecordA)
        XCTAssertNil(revokedPhysicalA)
        XCTAssertNotNil(preservedRecordB)
        XCTAssertNotNil(preservedPhysicalB)

        let afterLogoutB = try await pipeline.image(for: accountB)
        XCTAssertLessThan(try centerRed(afterLogoutB.cgImage), 80)
        let finalCounts = await origin.requestCounts()
        XCTAssertEqual(finalCounts["Bearer account-b"], 1)
    }

    func testPrivateNoStoreNeverCreatesReusableResidue() async throws {
        let body = try makePNG(red: 170)
        let origin = CredentialImageOrigin(responses: [
            "Bearer no-store": .init(
                body: body,
                headers: ["Content-Type": "image/png", "Cache-Control": "private, no-store"]
            )
        ])
        let root = try makeTemporaryDirectory()
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records"))
        let pipeline = FoveaPipeline(
            transport: origin,
            encodedStore: encoded,
            recordStore: records,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        let request = try authenticatedRequest(
            url: try XCTUnwrap(URL(string: "https://images.example.test/no-store")),
            target: try TargetPixels(width: 40, height: 40),
            namespace: "account-no-store",
            principal: "principal-no-store",
            token: "Bearer no-store"
        )

        _ = try await pipeline.image(for: request)
        _ = try await pipeline.image(for: request)

        let noStoreCounts = await origin.requestCounts()
        let noStoreRecord = await records.record(for: request.fetchVariantKey.digestHex)
        let contentID = ContentID(data: body).description
        let noStorePhysicalID = await encoded.physicalID(
            contentID: contentID,
            namespace: request.namespace.value
        )
        XCTAssertEqual(noStoreCounts["Bearer no-store"], 2)
        XCTAssertNil(noStoreRecord)
        XCTAssertNil(noStorePhysicalID)
    }

    func testLogoutCancelsInFlightFetchAndLeavesNoBlobOrRecord() async throws {
        let body = try makePNG(red: 100)
        let origin = CredentialImageOrigin(responses: [
            "Bearer delayed": .init(
                body: body,
                headers: ["Content-Type": "image/png", "Cache-Control": "private, max-age=3600"],
                delayNanoseconds: 150_000_000
            )
        ])
        let root = try makeTemporaryDirectory()
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records"))
        let pipeline = FoveaPipeline(
            transport: origin,
            encodedStore: encoded,
            recordStore: records,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        let request = try authenticatedRequest(
            url: try XCTUnwrap(URL(string: "https://images.example.test/delayed")),
            target: try TargetPixels(width: 40, height: 40),
            namespace: "account-delayed",
            principal: "principal-delayed",
            token: "Bearer delayed"
        )

        let task = Task { try await pipeline.image(for: request) }
        try await waitUntil("延迟鉴权请求进入 origin") {
            await origin.requestCounts()["Bearer delayed", default: 0] == 1
        }
        let delayedRequestCount = await origin.requestCounts()["Bearer delayed", default: 0]
        XCTAssertEqual(delayedRequestCount, 1)
        try await pipeline.revoke(namespace: request.namespace)

        do {
            _ = try await task.value
            XCTFail("A revoked namespace must not receive a final image")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .namespaceRevoked)
            XCTAssertEqual(failure.disposition, .terminal)
        }

        let delayedRecord = await records.record(for: request.fetchVariantKey.digestHex)
        let delayedPhysicalID = await encoded.physicalID(
            contentID: ContentID(data: body).description,
            namespace: request.namespace.value
        )
        XCTAssertNil(delayedRecord)
        XCTAssertNil(delayedPhysicalID)
    }

    func testRevokeDuringBlobCommitRemovesLateBlobAndRecord() async throws {
        let body = try makePNG(red: 120)
        let origin = CredentialImageOrigin(responses: [
            "Bearer commit-race": .init(
                body: body,
                headers: ["Content-Type": "image/png", "Cache-Control": "private, max-age=3600"]
            )
        ])
        let root = try makeTemporaryDirectory()
        let baseStore = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let barrierStore = CommitBarrierEncodedStore(base: baseStore)
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records"))
        let pipeline = FoveaPipeline(
            transport: origin,
            encodedStore: barrierStore,
            recordStore: records,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        let request = try authenticatedRequest(
            url: try XCTUnwrap(URL(string: "https://images.example.test/commit-race")),
            target: try TargetPixels(width: 40, height: 40),
            namespace: "account-commit-race",
            principal: "principal-commit-race",
            token: "Bearer commit-race"
        )

        let task = Task { try await pipeline.image(for: request) }
        await barrierStore.waitUntilCommitStarts()
        try await pipeline.revoke(namespace: request.namespace)
        await barrierStore.releaseCommit()

        do {
            _ = try await task.value
            XCTFail("A revoked namespace must not survive a late blob commit")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .namespaceRevoked)
            XCTAssertEqual(failure.disposition, .terminal)
        }

        let record = await records.record(for: request.fetchVariantKey.digestHex)
        let physicalID = await baseStore.physicalID(
            contentID: ContentID(data: body).description,
            namespace: request.namespace.value
        )
        XCTAssertNil(record)
        XCTAssertNil(physicalID)
    }

    func testRevocationBeforeRecordPublicationNeverTouchesRecordStore_AUTH_PT_003() async throws {
        let body = try makePNG(red: 125)
        let origin = CredentialImageOrigin(responses: [
            "Bearer pre-record": .init(
                body: body,
                headers: ["Content-Type": "image/png", "Cache-Control": "private, max-age=3600"]
            )
        ])
        let root = try makeTemporaryDirectory()
        let baseEncoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded")
        )
        let encoded = CommitBarrierEncodedStore(base: baseEncoded)
        let baseRecords = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let records = CountingRecordStore(base: baseRecords)
        let registry = NamespaceRegistry()
        let pipeline = FoveaPipeline(
            transport: origin,
            encodedStore: encoded,
            recordStore: records,
            namespaceRegistry: registry,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        let request = try authenticatedRequest(
            url: try XCTUnwrap(URL(string: "https://images.example.test/pre-record-revoke")),
            target: try TargetPixels(width: 40, height: 40),
            namespace: "account-pre-record",
            principal: "principal-pre-record",
            token: "Bearer pre-record"
        )

        let task = Task { try await pipeline.image(for: request) }
        await encoded.waitUntilCommitStarts()
        try await registry.revoke(request.namespace)
        await encoded.releaseCommit()

        do {
            _ = try await task.value
            XCTFail("失效代际不得继续发布记录")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .namespaceRevoked)
        }
        let putCount = await records.putCount
        let physicalID = await baseEncoded.physicalID(
            contentID: ContentID(data: body).description,
            namespace: request.namespace.value
        )
        XCTAssertEqual(putCount, 0)
        XCTAssertNil(physicalID)
    }

    func testRevocationAfterRecordPublicationRollsBackRecordAndBlob_AUTH_PT_005() async throws {
        let body = try makePNG(red: 126)
        let origin = CredentialImageOrigin(responses: [
            "Bearer post-record": .init(
                body: body,
                headers: ["Content-Type": "image/png", "Cache-Control": "private, max-age=3600"]
            )
        ])
        let root = try makeTemporaryDirectory()
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded")
        )
        let baseRecords = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let records = PublishedRecordBarrierStore(base: baseRecords)
        let registry = NamespaceRegistry()
        let pipeline = FoveaPipeline(
            transport: origin,
            encodedStore: encoded,
            recordStore: records,
            namespaceRegistry: registry,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        let request = try authenticatedRequest(
            url: try XCTUnwrap(URL(string: "https://images.example.test/post-record-revoke")),
            target: try TargetPixels(width: 40, height: 40),
            namespace: "account-post-record",
            principal: "principal-post-record",
            token: "Bearer post-record"
        )

        let task = Task { try await pipeline.image(for: request) }
        await records.waitUntilRecordPublished()
        try await registry.revoke(request.namespace)
        await records.releasePublication()

        do {
            _ = try await task.value
            XCTFail("失效代际发布的记录必须回滚")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .namespaceRevoked)
        }
        let record = await baseRecords.record(for: request.fetchVariantKey.digestHex)
        let physicalID = await encoded.physicalID(
            contentID: ContentID(data: body).description,
            namespace: request.namespace.value
        )
        XCTAssertNil(record)
        XCTAssertNil(physicalID)
    }

    func testRevokeDuring304RefreshRemovesLateMetadata_AUTH_PT_011() async throws {
        let body = try makePNG(red: 140)
        let root = try makeTemporaryDirectory()
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records"))
        let registry = NamespaceRegistry()
        let request = try ImageRequest(
            url: try XCTUnwrap(URL(string: "https://images.example.test/refresh-race")),
            target: try TargetPixels(width: 40, height: 40),
            namespace: SecurityNamespaceID("account-refresh-race"),
            authorizationContext: AuthorizationContextID("principal-refresh-race"),
            credentialGeneration: CredentialGeneration(1)
        )
        let seed = FoveaPipeline(
            transport: FakeHTTPTransport(stubs: [
                .init(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "image/png",
                        "Cache-Control": "private, max-age=0",
                        "ETag": "refresh-race-v1",
                    ],
                    body: body
                )
            ]),
            encodedStore: encoded,
            recordStore: records,
            namespaceRegistry: registry,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        _ = try await seed.image(for: request)

        let barrierRecords = RefreshBarrierRecordStore(base: records)
        let pipeline = FoveaPipeline(
            transport: FakeHTTPTransport(stubs: [
                .init(
                    statusCode: 304,
                    headers: ["Cache-Control": "private, max-age=3600", "ETag": "refresh-race-v1"]
                )
            ]),
            encodedStore: encoded,
            recordStore: barrierRecords,
            namespaceRegistry: registry,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )

        let task = Task { try await pipeline.image(for: request) }
        await barrierRecords.waitUntilRefreshStarts()
        try await pipeline.revoke(namespace: request.namespace)
        await barrierRecords.releaseRefresh()

        do {
            _ = try await task.value
            XCTFail("A late 304 refresh must not survive namespace revoke")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .namespaceRevoked)
            XCTAssertEqual(failure.disposition, .terminal)
        }

        let lateRecord = await records.record(for: request.fetchVariantKey.digestHex)
        let lateBlob = await encoded.physicalID(
            contentID: ContentID(data: body).description,
            namespace: request.namespace.value
        )
        XCTAssertNil(lateRecord)
        XCTAssertNil(lateBlob)
    }

    func testRevokeAttemptsAllPersistentCleanupWhenOneStoreFails() async throws {
        let encoded = TrackingCleanupEncodedStore()
        let records = FailingCleanupRecordStore()
        let pipeline = FoveaPipeline(
            transport: CredentialImageOrigin(responses: [:]),
            encodedStore: encoded,
            recordStore: records,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )

        do {
            try await pipeline.revoke(namespace: SecurityNamespaceID("account-cleanup-failure"))
            XCTFail("Expected a structured cleanup failure")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .cacheWrite)
            XCTAssertEqual(failure.stage, .revocation)
            XCTAssertEqual(failure.disposition, .cacheDegraded)
            XCTAssertEqual(failure.reasonCode, "namespace-cleanup-failed")
        }

        let encodedAttempts = await encoded.removeAllCount
        let recordAttempts = await records.removeAllCount
        XCTAssertEqual(encodedAttempts, 1)
        XCTAssertEqual(recordAttempts, 1)
    }

    func testCrossOriginRedirectStripsCredentialsButSameOriginPreservesThem() throws {
        var original = URLRequest(
            url: try XCTUnwrap(URL(string: "https://a.example.test/private"))
        )
        original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        original.setValue("session=secret", forHTTPHeaderField: "Cookie")
        original.setValue("api-secret", forHTTPHeaderField: "X-API-Key")
        original.setValue("image/avif", forHTTPHeaderField: "Accept")

        var crossOrigin = URLRequest(
            url: try XCTUnwrap(URL(string: "https://b.example.test/redirected"))
        )
        crossOrigin.allHTTPHeaderFields = original.allHTTPHeaderFields
        let sanitized = CredentialHeaderPolicy.sanitizedRedirectRequest(
            original: original,
            proposed: crossOrigin
        )
        XCTAssertNil(sanitized.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(sanitized.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(sanitized.value(forHTTPHeaderField: "X-API-Key"))
        XCTAssertEqual(sanitized.value(forHTTPHeaderField: "Accept"), "image/avif")

        crossOrigin.setValue("custom-secret", forHTTPHeaderField: "X-Tenant-Credential")
        let customSanitized = CredentialHeaderPolicy.sanitizedRedirectRequest(
            original: original,
            proposed: crossOrigin,
            additionalSensitiveNames: ["x-tenant-credential"]
        )
        XCTAssertNil(customSanitized.value(forHTTPHeaderField: "X-Tenant-Credential"))

        crossOrigin.setValue("session-secret", forHTTPHeaderField: "X-Session-ID")
        let heuristicSanitized = CredentialHeaderPolicy.sanitizedRedirectRequest(
            original: original,
            proposed: crossOrigin
        )
        XCTAssertNil(heuristicSanitized.value(forHTTPHeaderField: "X-Session-ID"))

        var sameOrigin = URLRequest(
            url: try XCTUnwrap(URL(string: "https://a.example.test:443/redirected"))
        )
        sameOrigin.allHTTPHeaderFields = original.allHTTPHeaderFields
        let preserved = CredentialHeaderPolicy.sanitizedRedirectRequest(
            original: original,
            proposed: sameOrigin
        )
        XCTAssertEqual(preserved.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(preserved.value(forHTTPHeaderField: "Cookie"), "session=secret")
    }
}

private func authenticatedRequest(
    url: URL,
    target: TargetPixels,
    namespace: String,
    principal: String,
    token: String
) throws -> ImageRequest {
    try ImageRequest(
        url: url,
        target: target,
        namespace: SecurityNamespaceID(namespace),
        authorizationContext: AuthorizationContextID(principal),
        credentialGeneration: CredentialGeneration(1),
        headers: ["Authorization": token]
    )
}

private func centerRed(_ image: CGImage) throws -> UInt8 {
    var pixel = [UInt8](repeating: 0, count: 4)
    let rendered = pixel.withUnsafeMutableBytes { bytes -> Bool in
        guard let baseAddress = bytes.baseAddress,
            let context = CGContext(
                data: baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return false
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return true
    }
    guard rendered else { throw NSError(domain: "FoveaAuthGalleryTests", code: 1) }
    return pixel[0]
}

private actor CredentialImageOrigin: HTTPTransporting {
    nonisolated let reusePolicy = TransportReusePolicy.reusable(
        contextIdentifier: "tests-credential-image-origin-v1"
    )

    struct Response: Sendable {
        let body: Data
        let headers: [String: String]
        let delayNanoseconds: UInt64

        init(body: Data, headers: [String: String], delayNanoseconds: UInt64 = 0) {
            self.body = body
            self.headers = headers
            self.delayNanoseconds = delayNanoseconds
        }
    }

    private let responses: [String: Response]
    private var counts: [String: Int] = [:]

    init(responses: [String: Response]) {
        self.responses = responses
    }

    func execute(_ request: TransportRequest) async throws -> TransportResponse {
        guard let credential = request.request.value(forHTTPHeaderField: "Authorization"),
            let response = responses[credential]
        else {
            throw URLError(.userAuthenticationRequired)
        }
        counts[credential, default: 0] += 1
        if response.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: response.delayNanoseconds)
        }
        try Task.checkCancellation()
        return TransportResponse(
            head: try TransportResponseHead(
                statusCode: 200,
                headers: response.headers,
                url: request.request.url
            ),
            body: response.body,
            metrics: TransportMetrics(receivedBytes: response.body.count, spilledToDisk: false)
        )
    }

    func requestCounts() -> [String: Int] { counts }
}

private enum CleanupTestError: Error, Sendable {
    case failed
}

private actor TrackingCleanupEncodedStore: OriginalEncodedStoring {
    private(set) var removeAllCount = 0

    func read(contentID: String, namespace: String) async throws -> Data {
        throw CleanupTestError.failed
    }

    func commit(data: Data, contentID: String, namespace: String) async throws -> StoredBlob {
        throw CleanupTestError.failed
    }

    func physicalID(contentID: String, namespace: String) async -> PhysicalBlobID? { nil }

    func remove(contentID: String, namespace: String) async throws {}

    func removeAll(namespace: String) async throws {
        removeAllCount += 1
    }
}

private actor FailingCleanupRecordStore: RepresentationRecordStoring {
    private(set) var removeAllCount = 0

    func records(
        for baseKeyDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async -> [RepresentationRecord] { [] }
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

    func removeAll(namespace: String) async throws {
        removeAllCount += 1
        throw CleanupTestError.failed
    }
}

private actor CountingRecordStore: RepresentationRecordStoring {
    private let base: RepresentationRecordStore
    private(set) var putCount = 0

    init(base: RepresentationRecordStore) {
        self.base = base
    }

    func records(
        for baseKeyDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async -> [RepresentationRecord] {
        await base.records(
            for: baseKeyDigest,
            namespace: namespace,
            namespaceGeneration: namespaceGeneration
        )
    }

    func put(_ record: RepresentationRecord) async throws {
        putCount += 1
        try await base.put(record)
    }

    func containsReference(
        to contentID: String,
        namespace: String,
        excludingVariantDigest: String?
    ) async -> Bool {
        await base.containsReference(
            to: contentID,
            namespace: namespace,
            excludingVariantDigest: excludingVariantDigest
        )
    }

    func remove(
        _ variantDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async throws {
        try await base.remove(
            variantDigest,
            namespace: namespace,
            namespaceGeneration: namespaceGeneration
        )
    }

    func removeAll(namespace: String) async throws {
        try await base.removeAll(namespace: namespace)
    }
}

private actor PublishedRecordBarrierStore: RepresentationRecordStoring {
    private let base: RepresentationRecordStore
    private var published = false
    private var released = false
    private var publishedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(base: RepresentationRecordStore) {
        self.base = base
    }

    func records(
        for baseKeyDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async -> [RepresentationRecord] {
        await base.records(
            for: baseKeyDigest,
            namespace: namespace,
            namespaceGeneration: namespaceGeneration
        )
    }

    func put(_ record: RepresentationRecord) async throws {
        try await base.put(record)
        published = true
        for waiter in publishedWaiters { waiter.resume() }
        publishedWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }

    func containsReference(
        to contentID: String,
        namespace: String,
        excludingVariantDigest: String?
    ) async -> Bool {
        await base.containsReference(
            to: contentID,
            namespace: namespace,
            excludingVariantDigest: excludingVariantDigest
        )
    }

    func remove(
        _ variantDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async throws {
        try await base.remove(
            variantDigest,
            namespace: namespace,
            namespaceGeneration: namespaceGeneration
        )
    }

    func removeAll(namespace: String) async throws {
        try await base.removeAll(namespace: namespace)
    }

    func waitUntilRecordPublished() async {
        if published { return }
        await withCheckedContinuation { publishedWaiters.append($0) }
    }

    func releasePublication() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}

private actor RefreshBarrierRecordStore: RepresentationRecordStoring {
    private let base: RepresentationRecordStore
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var released = false

    init(base: RepresentationRecordStore) {
        self.base = base
    }

    func records(
        for baseKeyDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async -> [RepresentationRecord] {
        await base.records(
            for: baseKeyDigest,
            namespace: namespace,
            namespaceGeneration: namespaceGeneration
        )
    }

    func put(_ record: RepresentationRecord) async throws {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        if !released {
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        try await base.put(record)
    }

    func containsReference(
        to contentID: String,
        namespace: String,
        excludingVariantDigest: String?
    ) async -> Bool {
        await base.containsReference(
            to: contentID,
            namespace: namespace,
            excludingVariantDigest: excludingVariantDigest
        )
    }

    func remove(
        _ variantDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async throws {
        try await base.remove(
            variantDigest,
            namespace: namespace,
            namespaceGeneration: namespaceGeneration
        )
    }

    func removeAll(namespace: String) async throws {
        try await base.removeAll(namespace: namespace)
    }

    func waitUntilRefreshStarts() async {
        guard !started else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func releaseRefresh() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
