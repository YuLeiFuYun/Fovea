import AkashicCore
import AkashicDisk
import AkashicMemory
import Foundation
import FoveaHTTP
import FoveaPersistence
import FoveaStorage
import ImageCraftCore
import XCTest

@testable import FoveaCore

final class TransportVerifiedEncodedHandoffTests: XCTestCase {
    func testHandoffRejectsPayloadLargerThanDerivedBudget_MATH_PT_022() async throws {
        let fixture = try await makeFixture(costLimit: 4)
        let data = Data(repeating: 0x41, count: 5)
        let request = try makeRequest(path: "oversized.png")
        let record = makeRecord(data: data, request: request, generation: 0)

        try await fixture.cache.insertTransportVerifiedHandoff(
            data: data,
            record: record,
            request: request,
            generation: NamespaceGeneration(0)
        )

        let result = try await fixture.cache.transportVerifiedHandoff(
            for: request,
            generation: NamespaceGeneration(0),
            currentDate: { Date() }
        )
        XCTAssertNil(result)
    }

    func testHandoffRequiresExactExecutionAndGenerationIdentity_MATH_PT_022() async throws {
        let fixture = try await makeFixture(costLimit: 32)
        let data = Data(repeating: 0x42, count: 8)
        let request = try makeRequest(path: "exact.png")
        let otherExecution = try makeRequest(path: "other.png")
        let record = makeRecord(data: data, request: request, generation: 0)

        try await fixture.cache.insertTransportVerifiedHandoff(
            data: data,
            record: record,
            request: request,
            generation: NamespaceGeneration(0)
        )

        let exact = try await fixture.cache.transportVerifiedHandoff(
            for: request,
            generation: NamespaceGeneration(0),
            currentDate: { Date() }
        )
        let wrongExecution = try await fixture.cache.transportVerifiedHandoff(
            for: otherExecution,
            generation: NamespaceGeneration(0),
            currentDate: { Date() }
        )
        let wrongGeneration = try await fixture.cache.transportVerifiedHandoff(
            for: request,
            generation: NamespaceGeneration(1),
            currentDate: { Date() }
        )

        XCTAssertEqual(try exact?.materializedData(), data)
        let reconstructed = exact?.representation(
            for: request,
            generation: NamespaceGeneration(0)
        )
        XCTAssertEqual(reconstructed, record)
        XCTAssertNil(wrongExecution)
        XCTAssertNil(wrongGeneration)
    }

    func testHandoffRejectsExpiredNoStorePrivateAndCredentialedEntries_MATH_PT_022() async throws {
        let fixture = try await makeFixture(costLimit: 64)
        let data = Data(repeating: 0x43, count: 8)
        let publicRequest = try makeRequest(path: "policy.png")

        let noStore = makeRecord(
            data: data,
            request: publicRequest,
            generation: 0,
            disposition: .noStore
        )
        try await fixture.cache.insertTransportVerifiedHandoff(
            data: data,
            record: noStore,
            request: publicRequest,
            generation: NamespaceGeneration(0)
        )
        let noStoreResult = try await fixture.cache.transportVerifiedHandoff(
            for: publicRequest,
            generation: NamespaceGeneration(0),
            currentDate: { Date() }
        )
        XCTAssertNil(noStoreResult)

        let privateDisposition = makeRecord(
            data: data,
            request: publicRequest,
            generation: 0,
            disposition: .privateNamespace
        )
        try await fixture.cache.insertTransportVerifiedHandoff(
            data: data,
            record: privateDisposition,
            request: publicRequest,
            generation: NamespaceGeneration(0)
        )
        let privateDispositionResult = try await fixture.cache.transportVerifiedHandoff(
            for: publicRequest,
            generation: NamespaceGeneration(0),
            currentDate: { Date() }
        )
        XCTAssertNil(privateDispositionResult)

        let credentialed = try ImageRequest(
            url: XCTUnwrap(URL(string: "https://example.test/credentialed.png")),
            target: TargetPixels(width: 32, height: 32),
            namespace: SecurityNamespaceID("handoff-private"),
            authorizationContext: AuthorizationContextID("handoff-user"),
            credentialGeneration: CredentialGeneration(1),
            headers: ["Authorization": "Bearer secret"]
        )
        let credentialedRecord = makeRecord(
            data: data,
            request: credentialed,
            generation: 0
        )
        try await fixture.cache.insertTransportVerifiedHandoff(
            data: data,
            record: credentialedRecord,
            request: credentialed,
            generation: NamespaceGeneration(0)
        )
        let credentialedResult = try await fixture.cache.transportVerifiedHandoff(
            for: credentialed,
            generation: NamespaceGeneration(0),
            currentDate: { Date() }
        )
        XCTAssertNil(credentialedResult)

        let expiredRequest = try makeRequest(path: "expired.png")
        let expiredRecord = makeRecord(
            data: data,
            request: expiredRequest,
            generation: 0,
            expiresAt: Date().addingTimeInterval(-1)
        )
        try await fixture.cache.insertTransportVerifiedHandoff(
            data: data,
            record: expiredRecord,
            request: expiredRequest,
            generation: NamespaceGeneration(0)
        )
        let expiredResult = try await fixture.cache.transportVerifiedHandoff(
            for: expiredRequest,
            generation: NamespaceGeneration(0),
            currentDate: { Date() }
        )
        XCTAssertNil(expiredResult)
    }

    func testDiskStoreRejectsBroadPermissionStagedFile_SEC_CASE_019() async throws {
        let data = Data(repeating: 0x5B, count: 17)
        let request = try makeRequest(path: "insecure-shared-stage.png")
        let generation = NamespaceGeneration(0)
        let record = makeRecord(data: data, request: request, generation: generation.value)
        let metadata = try XCTUnwrap(
            TransportVerifiedEncodedHandoffMetadata(
                record: record,
                request: request,
                generation: generation,
                payloadByteCount: data.count
            )
        )
        let source = try makeTemporaryDirectory("handoff-insecure-stage-\(UUID().uuidString)")
            .appendingPathComponent("body.bin")
        try data.write(to: source)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: source.path
        )
        let lease = TransportStagedFileLease(fileURL: source, byteCount: data.count)
        let store = TransportVerifiedHandoffDiskStore(costLimit: 64)
        let key = ScopedTransportVerifiedHandoffKey(
            namespace: request.namespace,
            generation: generation,
            executionDigest: request.fetchExecutionKey.digestHex
        )

        await assertThrowsErrorAsync {
            try await store.insert(payload: .stagedFile(lease), metadata: metadata, for: key)
        }
        XCTAssertEqual(try Data(contentsOf: source), data)
        let stored = try await store.entry(for: key)
        XCTAssertNil(stored)
    }

    func testDiskStoreClonesSharedStagedLeaseWithoutInvalidatingTransportResponse_CACHE_PT_048()
        async throws
    {
        let data = Data(repeating: 0x5A, count: 17)
        let request = try makeRequest(path: "shared-stage.png")
        let generation = NamespaceGeneration(0)
        let record = makeRecord(data: data, request: request, generation: generation.value)
        let metadata = try XCTUnwrap(
            TransportVerifiedEncodedHandoffMetadata(
                record: record,
                request: request,
                generation: generation,
                payloadByteCount: data.count
            )
        )
        let source = try makeTemporaryDirectory("handoff-shared-stage-\(UUID().uuidString)")
            .appendingPathComponent("body.bin")
        try data.write(to: source)
        try FoveaManagedFileSecurity.securePublishedFile(source)
        let lease = TransportStagedFileLease(fileURL: source, byteCount: data.count)
        let store = TransportVerifiedHandoffDiskStore(costLimit: 64)
        let key = ScopedTransportVerifiedHandoffKey(
            namespace: request.namespace,
            generation: generation,
            executionDigest: request.fetchExecutionKey.digestHex
        )

        try await store.insert(payload: .stagedFile(lease), metadata: metadata, for: key)

        // handoff 必须获得独立文件能力，不能通过 move 使共享 fetch 的原响应失效。
        XCTAssertEqual(try lease.mappedData(), data)
        let stored = try await store.entry(for: key)
        XCTAssertEqual(try stored?.materializedData(), data)
        XCTAssertEqual(stored?.metadata.contentID, metadata.contentID)
    }

    func testDiskStoreEvictionKeepsIndexAndFilesConsistent_CACHE_PT_049() async throws {
        let store = TransportVerifiedHandoffDiskStore(costLimit: 8)
        let generation = NamespaceGeneration(0)
        let firstRequest = try makeRequest(path: "disk-first.png")
        let secondRequest = try makeRequest(path: "disk-second.png")
        let firstData = Data(repeating: 0x31, count: 5)
        let secondData = Data(repeating: 0x32, count: 5)

        func key(for request: ImageRequest) -> ScopedTransportVerifiedHandoffKey {
            ScopedTransportVerifiedHandoffKey(
                namespace: request.namespace,
                generation: generation,
                executionDigest: request.fetchExecutionKey.digestHex
            )
        }
        func metadata(for request: ImageRequest, data: Data) throws
            -> TransportVerifiedEncodedHandoffMetadata
        {
            try XCTUnwrap(
                TransportVerifiedEncodedHandoffMetadata(
                    record: makeRecord(
                        data: data,
                        request: request,
                        generation: generation.value
                    ),
                    request: request,
                    generation: generation,
                    payloadByteCount: data.count
                )
            )
        }

        try await store.insert(
            payload: .memory(firstData),
            metadata: try metadata(for: firstRequest, data: firstData),
            for: key(for: firstRequest)
        )
        try await store.insert(
            payload: .memory(secondData),
            metadata: try metadata(for: secondRequest, data: secondData),
            for: key(for: secondRequest)
        )

        let evictedEntry = try await store.entry(for: key(for: firstRequest))
        let retainedEntry = try await store.entry(for: key(for: secondRequest))
        XCTAssertNil(evictedEntry)
        XCTAssertEqual(try retainedEntry?.materializedData(), secondData)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.currentCost, secondData.count)
        let removalSummary = await store.removeAllAndReport()
        XCTAssertEqual(
            removalSummary,
            MemoryCacheRemovalSummary(itemCount: 1, costBytes: secondData.count)
        )
        let removedEntry = try await store.entry(for: key(for: secondRequest))
        XCTAssertNil(removedEntry)
    }

    func testDiskStoreConcurrentCommitsPreserveBodyMetadataAtomicity_CACHE_PT_050()
        async throws
    {
        let store = TransportVerifiedHandoffDiskStore(costLimit: 64)
        let request = try makeRequest(path: "concurrent-same-key.png")
        let generation = NamespaceGeneration(0)
        let key = ScopedTransportVerifiedHandoffKey(
            namespace: request.namespace,
            generation: generation,
            executionDigest: request.fetchExecutionKey.digestHex
        )
        let payloads = (0..<32).map { Data(repeating: UInt8($0), count: 5) }
        let work = payloads.compactMap { data -> (Data, TransportVerifiedEncodedHandoffMetadata)? in
            let record = makeRecord(
                data: data,
                request: request,
                generation: generation.value
            )
            guard
                let metadata = TransportVerifiedEncodedHandoffMetadata(
                    record: record,
                    request: request,
                    generation: generation,
                    payloadByteCount: data.count
                )
            else { return nil }
            return (data, metadata)
        }

        await withTaskGroup(of: Void.self) { group in
            for (data, metadata) in work {
                group.addTask {
                    try? await store.insert(payload: .memory(data), metadata: metadata, for: key)
                }
            }
        }

        let storedEntry = try await store.entry(for: key)
        let entry = try XCTUnwrap(storedEntry)
        let body = try entry.materializedData()
        XCTAssertEqual(entry.metadata.contentID, ContentID(data: body))
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.currentCost, body.count)
    }

    func testDiskStoreConcurrentCapacityInvariant_CACHE_PT_051() async throws {
        let store = TransportVerifiedHandoffDiskStore(costLimit: 48)
        let generation = NamespaceGeneration(0)
        let requests = try (0..<64).map { try makeRequest(path: "capacity-\($0).png") }
        let data = Data(repeating: 0x7B, count: 3)
        let work = requests.compactMap {
            request
                -> (ScopedTransportVerifiedHandoffKey, TransportVerifiedEncodedHandoffMetadata)? in
            let record = makeRecord(
                data: data,
                request: request,
                generation: generation.value
            )
            guard
                let metadata = TransportVerifiedEncodedHandoffMetadata(
                    record: record,
                    request: request,
                    generation: generation,
                    payloadByteCount: data.count
                )
            else { return nil }
            let key = ScopedTransportVerifiedHandoffKey(
                namespace: request.namespace,
                generation: generation,
                executionDigest: request.fetchExecutionKey.digestHex
            )
            return (key, metadata)
        }

        await withTaskGroup(of: Void.self) { group in
            for (key, metadata) in work {
                group.addTask {
                    try? await store.insert(payload: .memory(data), metadata: metadata, for: key)
                }
            }
        }

        var residentCount = 0
        var residentBytes = 0
        for request in requests {
            let key = ScopedTransportVerifiedHandoffKey(
                namespace: request.namespace,
                generation: generation,
                executionDigest: request.fetchExecutionKey.digestHex
            )
            if let entry = try await store.entry(for: key) {
                residentCount += 1
                residentBytes += entry.byteCount
            }
        }
        XCTAssertEqual(store.count, residentCount)
        XCTAssertEqual(store.currentCost, residentBytes)
        XCTAssertLessThanOrEqual(residentBytes, 48)
        XCTAssertLessThanOrEqual(residentCount, 16)
    }

    func testDiskStoreInvalidationIsMonotonic_CACHE_PT_052() async throws {
        let store = TransportVerifiedHandoffDiskStore(costLimit: 64)
        let request = try makeRequest(path: "invalidated.png")
        let generation = NamespaceGeneration(0)
        let data = Data(repeating: 0x55, count: 8)
        let record = makeRecord(data: data, request: request, generation: generation.value)
        let metadata = try XCTUnwrap(
            TransportVerifiedEncodedHandoffMetadata(
                record: record,
                request: request,
                generation: generation,
                payloadByteCount: data.count
            )
        )
        let key = ScopedTransportVerifiedHandoffKey(
            namespace: request.namespace,
            generation: generation,
            executionDigest: request.fetchExecutionKey.digestHex
        )

        _ = await store.invalidateAndRemoveAll()
        do {
            try await store.insert(payload: .memory(data), metadata: metadata, for: key)
            XCTFail("失效后的 handoff store 不得重新发布")
        } catch is CancellationError {
            // 预期。
        }
        let entry = try await store.entry(for: key)
        XCTAssertNil(entry)
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(store.currentCost, 0)
    }

    func testPurgeAndNamespaceCleanupRemoveHandoffState_MATH_PT_022() async throws {
        let fixture = try await makeFixture(costLimit: 64)
        let data = Data(repeating: 0x44, count: 8)
        let request = try makeRequest(path: "cleanup.png")
        let record = makeRecord(data: data, request: request, generation: 0)

        try await insert(data: data, record: record, request: request, into: fixture.cache)
        let purgeSummary = await fixture.cache.purgeRendered()
        XCTAssertGreaterThanOrEqual(purgeSummary.itemCount, 1)
        let afterPurge = try await fixture.cache.transportVerifiedHandoff(
            for: request,
            generation: NamespaceGeneration(0),
            currentDate: { Date() }
        )
        XCTAssertNil(afterPurge)

        try await insert(data: data, record: record, request: request, into: fixture.cache)
        let cleanupFailed = await fixture.cache.cleanup(namespace: request.namespace)
        XCTAssertFalse(cleanupFailed)
        let afterCleanup = try await fixture.cache.transportVerifiedHandoff(
            for: request,
            generation: NamespaceGeneration(0),
            currentDate: { Date() }
        )
        XCTAssertNil(afterCleanup)
    }

    private func insert(
        data: Data,
        record: RepresentationRecord,
        request: ImageRequest,
        into cache: PipelineCache
    ) async throws {
        try await cache.insertTransportVerifiedHandoff(
            data: data,
            record: record,
            request: request,
            generation: NamespaceGeneration(0)
        )
    }

    private func makeFixture(costLimit: Int) async throws -> (
        cache: PipelineCache,
        encoded: AkashicOriginalEncodedStore,
        records: RepresentationRecordStore
    ) {
        let root = try makeTemporaryDirectory("validated-handoff-\(UUID().uuidString)")
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded")
        )
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let registry = NamespaceRegistry(maximumTrackedNamespaces: 16)
        let cache = PipelineCache(
            encodedStore: encoded,
            recordStore: records,
            memoryCostLimit: 1_024,
            transportVerifiedEncodedHandoffCostLimit: costLimit,
            mutationQueueLimit: 16,
            namespaceRegistry: registry,
            diagnostics: NullDiagnosticsSink()
        )
        return (cache, encoded, records)
    }

    private func makeRequest(path: String) throws -> ImageRequest {
        try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/\(path)")),
            target: TargetPixels(width: 32, height: 32),
            appID: "validated-handoff-tests"
        )
    }

    private func makeRecord(
        data: Data,
        request: ImageRequest,
        generation: UInt64,
        disposition: CacheDisposition = .reusable,
        expiresAt: Date = Date().addingTimeInterval(60)
    ) -> RepresentationRecord {
        RepresentationRecord(
            securityNamespace: request.namespace.value,
            namespaceGeneration: generation,
            baseKeyDigest: request.fetchBaseKey.digestHex,
            variantKeyDigest: request.fetchVariantKey.digestHex,
            statusCode: 200,
            requestTime: Date(),
            responseTime: Date(),
            responseDate: Date(),
            expiresAt: expiresAt,
            etag: nil,
            lastModified: nil,
            disposition: disposition,
            contentID: ContentID(data: data).description,
            payloadLength: data.count,
            contentType: "image/png"
        )
    }
}
