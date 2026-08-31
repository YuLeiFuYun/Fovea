import FoveaHTTP
import FoveaStorage
import XCTest

final class T100RepresentationRecordCapabilityTests: XCTestCase {
    func testBaseStoreDoesNotImplicitlyGainOptionalLookupCapabilities_RECORD_CAP_PT_001() {
        let base: any RepresentationRecordStoring = BaseOnlyRecordStore()
        XCTAssertNil(base as? any RepresentationRecordSnapshotLookingUp)
        XCTAssertNil(base as? any RepresentationRecordExactLookingUp)
    }

    func testSnapshotCapabilityRemainsOptInAndUsesFingerprintSignature_RECORD_CAP_PT_002() {
        let fingerprint = StorageNamespaceFingerprint(namespace: "capability-snapshot")
        let base: any RepresentationRecordStoring = SnapshotRecordStore()
        let snapshot = base as? any RepresentationRecordSnapshotLookingUp

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(
            snapshot?.recordsSnapshot(
                for: "base",
                namespaceFingerprint: fingerprint,
                namespaceGeneration: 7
            )?.count,
            0
        )
        XCTAssertNil(base as? any RepresentationRecordExactLookingUp)
    }

    func testExactCapabilityRemainsOptInAndUsesVariantSignature_RECORD_CAP_PT_003() {
        let fingerprint = StorageNamespaceFingerprint(namespace: "capability-exact")
        let base: any RepresentationRecordStoring = ExactRecordStore()
        let exact = base as? any RepresentationRecordExactLookingUp

        XCTAssertNotNil(exact)
        XCTAssertNil(
            exact?.uniqueRecord(
                for: "variant",
                baseKeyDigest: "base",
                namespaceFingerprint: fingerprint,
                namespaceGeneration: 11
            )
        )
        XCTAssertNil(base as? any RepresentationRecordSnapshotLookingUp)
    }
}

private struct BaseOnlyRecordStore: RepresentationRecordStoring {
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

    func removeAll(namespace: String) async throws {}
}

private struct SnapshotRecordStore: RepresentationRecordStoring,
    RepresentationRecordSnapshotLookingUp
{
    func records(
        for baseKeyDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async -> [RepresentationRecord] { [] }

    func recordsSnapshot(
        for baseKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: UInt64
    ) -> [RepresentationRecord]? { [] }

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

private struct ExactRecordStore: RepresentationRecordStoring, RepresentationRecordExactLookingUp {
    func records(
        for baseKeyDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async -> [RepresentationRecord] { [] }

    func uniqueRecord(
        for variantDigest: String,
        baseKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: UInt64
    ) -> RepresentationRecord? { nil }

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
