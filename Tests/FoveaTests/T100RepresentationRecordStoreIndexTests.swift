import Foundation
import FoveaHTTP
import FoveaPersistence
import FoveaStorage
import XCTest

final class T100RepresentationRecordStoreIndexTests: XCTestCase {
    func testExactLookupRequiresUniqueNamespaceGenerationCandidate_RECORD_STORE_PT_001() async throws {
        let root = try t100RecordStoreTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await RepresentationRecordStore.open(root: root)
        let first = t100Record(
            namespace: "account-a",
            generation: 7,
            baseNibble: "a",
            variantNibble: "b"
        )
        try await store.put(first)

        let fingerprint = StorageNamespaceFingerprint(namespace: "account-a")
        let unique = store.uniqueRecord(
            for: first.variantKeyDigest,
            baseKeyDigest: first.baseKeyDigest,
            namespaceFingerprint: fingerprint,
            namespaceGeneration: 7
        )
        XCTAssertEqual(unique, first)
        let wrongNamespace = store.uniqueRecord(
            for: first.variantKeyDigest,
            baseKeyDigest: first.baseKeyDigest,
            namespaceFingerprint: StorageNamespaceFingerprint(namespace: "account-b"),
            namespaceGeneration: 7
        )
        XCTAssertNil(wrongNamespace)
        let wrongGeneration = store.uniqueRecord(
            for: first.variantKeyDigest,
            baseKeyDigest: first.baseKeyDigest,
            namespaceFingerprint: fingerprint,
            namespaceGeneration: 8
        )
        XCTAssertNil(wrongGeneration)

        let second = t100Record(
            namespace: "account-a",
            generation: 7,
            baseNibble: "a",
            variantNibble: "c"
        )
        try await store.put(second)
        let ambiguous = store.uniqueRecord(
            for: first.variantKeyDigest,
            baseKeyDigest: first.baseKeyDigest,
            namespaceFingerprint: fingerprint,
            namespaceGeneration: 7
        )
        XCTAssertNil(ambiguous)
    }

    func testSnapshotIsNamespaceGenerationScopedAndDeterministicallySorted_RECORD_STORE_PT_002()
        async throws
    {
        let root = try t100RecordStoreTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await RepresentationRecordStore.open(root: root)
        let base = t100Digest("a")
        let first = t100Record(
            namespace: "account-a", generation: 2, baseDigest: base, variantNibble: "d")
        let second = t100Record(
            namespace: "account-a", generation: 2, baseDigest: base, variantNibble: "b")
        let otherGeneration = t100Record(
            namespace: "account-a", generation: 3, baseDigest: base, variantNibble: "c")
        let otherNamespace = t100Record(
            namespace: "account-b", generation: 2, baseDigest: base, variantNibble: "e")
        for record in [first, second, otherGeneration, otherNamespace] {
            try await store.put(record)
        }

        let snapshot = try XCTUnwrap(
            store.recordsSnapshot(
                for: base,
                namespaceFingerprint: StorageNamespaceFingerprint(namespace: "account-a"),
                namespaceGeneration: 2
            )
        )
        XCTAssertEqual(snapshot.map(\.variantKeyDigest), [second.variantKeyDigest, first.variantKeyDigest])
    }

    func testPersistenceFailureDoesNotPublishGhostIndexEntry_RECORD_STORE_PT_003() async throws {
        let parent = try t100RecordStoreTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("records", isDirectory: true)
        let store = try await RepresentationRecordStore.open(root: root)
        try FileManager.default.removeItem(at: root)
        let record = t100Record(
            namespace: "public:tests",
            generation: 0,
            baseNibble: "1",
            variantNibble: "2"
        )

        do {
            try await store.put(record)
            XCTFail("expected durable write failure")
        } catch {
            // Expected: exact index must return to the pre-mutation snapshot.
        }
        let snapshot = try XCTUnwrap(
            store.recordsSnapshot(
                for: record.baseKeyDigest,
                namespaceFingerprint: StorageNamespaceFingerprint(namespace: "public:tests"),
                namespaceGeneration: 0
            )
        )
        XCTAssertTrue(snapshot.isEmpty)
        let ghost = store.uniqueRecord(
            for: record.variantKeyDigest,
            baseKeyDigest: record.baseKeyDigest,
            namespaceFingerprint: StorageNamespaceFingerprint(namespace: "public:tests"),
            namespaceGeneration: 0
        )
        XCTAssertNil(ghost)
    }

    func testRemovalRebuildsExactIndexWithoutDisturbingOtherScope_RECORD_STORE_PT_004()
        async throws
    {
        let root = try t100RecordStoreTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await RepresentationRecordStore.open(root: root)
        let base = t100Digest("4")
        let first = t100Record(
            namespace: "account-a", generation: 1, baseDigest: base, variantNibble: "5")
        let second = t100Record(
            namespace: "account-a", generation: 1, baseDigest: base, variantNibble: "6")
        let other = t100Record(
            namespace: "account-b", generation: 1, baseDigest: base, variantNibble: "7")
        for record in [first, second, other] { try await store.put(record) }

        try await store.remove(
            first.variantKeyDigest,
            namespace: "account-a",
            namespaceGeneration: 1
        )
        let remaining = store.uniqueRecord(
            for: second.variantKeyDigest,
            baseKeyDigest: base,
            namespaceFingerprint: StorageNamespaceFingerprint(namespace: "account-a"),
            namespaceGeneration: 1
        )
        XCTAssertEqual(remaining, second)
        let otherSnapshot = try XCTUnwrap(
            store.recordsSnapshot(
                for: base,
                namespaceFingerprint: StorageNamespaceFingerprint(namespace: "account-b"),
                namespaceGeneration: 1
            )
        )
        XCTAssertEqual(otherSnapshot, [other])
    }
}

private func t100RecordStoreTemporaryDirectory() throws -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("fovea-t100-record-index-\(UUID().uuidString)", isDirectory: true)
}

private func t100Digest(_ nibble: Character) -> String {
    String(repeating: String(nibble), count: 64)
}

private func t100Record(
    namespace: String,
    generation: UInt64,
    baseDigest: String? = nil,
    baseNibble: Character = "a",
    variantNibble: Character
) -> RepresentationRecord {
    RepresentationRecord(
        securityNamespace: namespace,
        namespaceGeneration: generation,
        baseKeyDigest: baseDigest ?? t100Digest(baseNibble),
        variantKeyDigest: t100Digest(variantNibble),
        statusCode: 200,
        requestTime: Date(timeIntervalSinceReferenceDate: 1_000),
        responseTime: Date(timeIntervalSinceReferenceDate: 1_001),
        responseDate: Date(timeIntervalSinceReferenceDate: 1_001),
        expiresAt: Date(timeIntervalSinceReferenceDate: 10_000),
        etag: nil,
        lastModified: nil,
        disposition: namespace.hasPrefix("public:") ? .reusable : .privateNamespace,
        contentID: "sha256:\(t100Digest("8")):1",
        payloadLength: 1,
        contentType: "image/jpeg"
    )
}
