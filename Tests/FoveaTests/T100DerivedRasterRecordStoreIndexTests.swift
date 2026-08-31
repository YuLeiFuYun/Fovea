import AkashicCore
import Foundation
import FoveaPersistence
import FoveaStorage
import XCTest

final class T100DerivedRasterRecordStoreIndexTests: XCTestCase {
    func testPutPublishesScopedHotIndexAndCanonicalBlobDigest_DERIVED_RECORD_STORE_PT_001()
        async throws
    {
        let root = try t100DerivedRecordStoreTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await DerivedRasterRecordStore.open(root: root)
        let record = try t100DerivedRecord(artifactNibble: "1", namespaceNibble: "9", generation: 4)

        try await store.put(record)
        let indexed = store.record(
            for: record.artifactKeyDigest,
            namespaceFingerprint: record.namespaceFingerprint,
            namespaceGeneration: 4
        )
        XCTAssertEqual(indexed?.record, record)
        XCTAssertEqual(indexed?.containerDigest.byteCount, record.containerByteCount)
        let wrongNamespace = store.record(
            for: record.artifactKeyDigest,
            namespaceFingerprint: StorageNamespaceFingerprint(validatedValue: t100DRDigest("8")),
            namespaceGeneration: 4
        )
        XCTAssertNil(wrongNamespace)
        let wrongGeneration = store.record(
            for: record.artifactKeyDigest,
            namespaceFingerprint: record.namespaceFingerprint,
            namespaceGeneration: 5
        )
        XCTAssertNil(wrongGeneration)
    }

    func testReopenRebuildsHotIndexFromValidatedManifest_DERIVED_RECORD_STORE_PT_002()
        async throws
    {
        let root = try t100DerivedRecordStoreTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: DerivedRasterRecordStore? = try await DerivedRasterRecordStore.open(root: root)
        let record = try t100DerivedRecord(artifactNibble: "2", namespaceNibble: "7", generation: 2)
        try await store?.put(record)
        store = nil

        let reopened = try await DerivedRasterRecordStore.open(root: root)
        let indexed = reopened.record(
            for: record.artifactKeyDigest,
            namespaceFingerprint: record.namespaceFingerprint,
            namespaceGeneration: record.namespaceGeneration
        )
        XCTAssertEqual(indexed?.record, record)
        let all = await reopened.allRecordsForTesting()
        XCTAssertEqual(all, [record])
    }

    func testPersistenceFailureDoesNotPublishGhostRecord_DERIVED_RECORD_STORE_PT_003()
        async throws
    {
        let parent = try t100DerivedRecordStoreTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("records", isDirectory: true)
        let store = try await DerivedRasterRecordStore.open(root: root)
        try FileManager.default.removeItem(at: root)
        let record = try t100DerivedRecord(artifactNibble: "3", namespaceNibble: "6", generation: 1)

        do {
            try await store.put(record)
            XCTFail("expected durable manifest write failure")
        } catch {
            // 预期路径：beginMutation 必须回滚，且不能发布 candidate record。
        }
        let indexed = store.record(
            for: record.artifactKeyDigest,
            namespaceFingerprint: record.namespaceFingerprint,
            namespaceGeneration: record.namespaceGeneration
        )
        XCTAssertNil(indexed)
        let all = await store.allRecordsForTesting()
        XCTAssertTrue(all.isEmpty)
    }

    func testScopedRemovalUpdatesHotIndexAndRetainsOtherRecord_DERIVED_RECORD_STORE_PT_004()
        async throws
    {
        let root = try t100DerivedRecordStoreTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await DerivedRasterRecordStore.open(root: root)
        let first = try t100DerivedRecord(artifactNibble: "4", namespaceNibble: "5", generation: 3)
        let second = try t100DerivedRecord(artifactNibble: "5", namespaceNibble: "4", generation: 3)
        try await store.put(first)
        try await store.put(second)

        let removed = try await store.remove(
            artifactKeyDigest: first.artifactKeyDigest,
            namespaceFingerprint: first.namespaceFingerprint,
            namespaceGeneration: first.namespaceGeneration
        )
        XCTAssertEqual(removed, first)
        let removedIndex = store.record(
            for: first.artifactKeyDigest,
            namespaceFingerprint: first.namespaceFingerprint,
            namespaceGeneration: first.namespaceGeneration
        )
        XCTAssertNil(removedIndex)
        let retained = store.record(
            for: second.artifactKeyDigest,
            namespaceFingerprint: second.namespaceFingerprint,
            namespaceGeneration: second.namespaceGeneration
        )
        XCTAssertEqual(retained?.record, second)
    }
}

private func t100DerivedRecordStoreTempDirectory() throws -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "fovea-t100-derived-record-store-\(UUID().uuidString)", isDirectory: true)
}

private func t100DRDigest(_ nibble: Character) -> String {
    String(repeating: String(nibble), count: 64)
}

private func t100DerivedRecord(
    artifactNibble: Character,
    namespaceNibble: Character,
    generation: UInt64
) throws -> DerivedRasterRecord {
    try DerivedRasterRecord(
        artifactKeyDigest: t100DRDigest(artifactNibble),
        baseKeyDigest: t100DRDigest("b"),
        variantKeyDigest: t100DRDigest("c"),
        namespaceFingerprint: StorageNamespaceFingerprint(
            validatedValue: t100DRDigest(namespaceNibble)),
        namespaceGeneration: generation,
        containerContentID: "sha256:\(t100DRDigest("d")):3",
        containerByteCount: 3,
        formatIdentifier: "raw-rgb24",
        formatSemanticVersion: 1,
        pixelLayoutFingerprint: "rgb24-v1",
        pixelDigestHex: t100DRDigest("e"),
        pixelWidth: 1,
        pixelHeight: 1,
        createdAt: Date(timeIntervalSinceReferenceDate: 1_000 + Double(generation))
    )
}
