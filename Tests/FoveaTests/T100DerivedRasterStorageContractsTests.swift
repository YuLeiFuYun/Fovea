import Foundation
import FoveaStorage
import XCTest

final class T100DerivedRasterStorageContractsTests: XCTestCase {
    func testDerivedRasterRecordValidatesAndCodableRoundTrips_STORAGE_CONTRACT_PT_001() throws {
        let record = try makeRecord()
        XCTAssertTrue(record.isValidPersistentRecord())
        XCTAssertTrue(record.isValidPersistentRecord(storedUnder: record.artifactKeyDigest))
        XCTAssertFalse(record.isValidPersistentRecord(storedUnder: t100StorageDigest("f")))

        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(DerivedRasterRecord.self, from: encoded)
        XCTAssertEqual(decoded, record)
    }

    func testDerivedRasterRecordRejectsInvalidPersistentShape_STORAGE_CONTRACT_PT_002() throws {
        XCTAssertThrowsError(try makeRecord(artifactKeyDigest: "ABC"))
        XCTAssertThrowsError(
            try makeRecord(
                containerContentID: "sha256:\(t100StorageDigest("d")):0",
                containerByteCount: 0
            )
        )
        XCTAssertThrowsError(try makeRecord(formatIdentifier: "contains space"))
        XCTAssertThrowsError(try makeRecord(pixelLayoutFingerprint: ""))
        XCTAssertThrowsError(
            try makeRecord(pixelDigestHex: String(repeating: "A", count: 64))
        )
        XCTAssertThrowsError(try makeRecord(pixelWidth: 0))
        XCTAssertThrowsError(try makeRecord(pixelHeight: 65_537))
        XCTAssertThrowsError(
            try makeRecord(createdAt: Date(timeIntervalSinceReferenceDate: .nan))
        )
    }

    func testDecodingRevalidatesSchemaAndPersistentShape_STORAGE_CONTRACT_PT_003() throws {
        let record = try makeRecord()
        let encoded = try JSONEncoder().encode(record)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 999
        let wrongSchema = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(DerivedRasterRecord.self, from: wrongSchema))

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["pixelWidth"] = 0
        let wrongGeometry = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(DerivedRasterRecord.self, from: wrongGeometry))
    }

    func testWriteBudgetErrorProjectsStableDiagnosticFields_STORAGE_CONTRACT_PT_004() {
        let error = DerivedRasterStoreError.writeBudgetExceeded(
            logicalWriteChargeBytes: 321,
            maximumWriteBytesPerWindow: 123
        )
        XCTAssertEqual(error.diagnosticReason, "derived-raster-global-write-budget")
        XCTAssertEqual(error.logicalWriteChargeBytes, 321)
    }

    func testStorageProtocolsRemainExplicitOptInContracts_STORAGE_CONTRACT_PT_005() async throws {
        let store = ContractStore()
        let permission = AllowPublication()
        let record = try makeRecord()
        let artifact = DerivedRasterStoredArtifact(record: record, container: Data([1, 2, 3]))
        try await store.commit(
            container: artifact.container,
            record: artifact.record,
            publicationPermission: permission
        )
        let loaded = try await store.load(
            artifactKeyDigest: record.artifactKeyDigest,
            namespaceFingerprint: record.namespaceFingerprint,
            namespaceGeneration: record.namespaceGeneration
        )
        XCTAssertEqual(loaded?.record, record)
        XCTAssertEqual(loaded?.container, Data([1, 2, 3]))
    }

    private func makeRecord(
        artifactKeyDigest: String = t100StorageDigest("a"),
        containerContentID: String = "sha256:\(t100StorageDigest("d")):3",
        containerByteCount: Int = 3,
        formatIdentifier: String = "raw-rgb24",
        pixelLayoutFingerprint: String = "rgb24-v1",
        pixelDigestHex: String = t100StorageDigest("e"),
        pixelWidth: Int = 1,
        pixelHeight: Int = 1,
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 1_000)
    ) throws -> DerivedRasterRecord {
        try DerivedRasterRecord(
            artifactKeyDigest: artifactKeyDigest,
            baseKeyDigest: t100StorageDigest("b"),
            variantKeyDigest: t100StorageDigest("c"),
            namespaceFingerprint: StorageNamespaceFingerprint(
                validatedValue: t100StorageDigest("9")
            ),
            namespaceGeneration: 7,
            containerContentID: containerContentID,
            containerByteCount: containerByteCount,
            formatIdentifier: formatIdentifier,
            formatSemanticVersion: 1,
            pixelLayoutFingerprint: pixelLayoutFingerprint,
            pixelDigestHex: pixelDigestHex,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            createdAt: createdAt
        )
    }
}

private func t100StorageDigest(_ nibble: Character) -> String {
    String(repeating: String(nibble), count: 64)
}

private struct AllowPublication: DerivedRasterPublicationPermission {
    func permitsPublication() async -> Bool { true }
}

private actor ContractStore: DerivedRasterStoring {
    private var artifact: DerivedRasterStoredArtifact?

    func load(
        artifactKeyDigest _: String,
        namespaceFingerprint _: StorageNamespaceFingerprint,
        namespaceGeneration _: UInt64
    ) async throws -> DerivedRasterStoredArtifact? {
        artifact
    }

    func commit(
        container: Data,
        record: DerivedRasterRecord,
        publicationPermission: any DerivedRasterPublicationPermission
    ) async throws {
        guard await publicationPermission.permitsPublication() else { return }
        artifact = DerivedRasterStoredArtifact(record: record, container: container)
    }

    func remove(
        artifactKeyDigest _: String,
        namespaceFingerprint _: StorageNamespaceFingerprint,
        namespaceGeneration _: UInt64
    ) async throws {
        artifact = nil
    }

    func removeAll(namespaceFingerprint _: StorageNamespaceFingerprint) async throws {
        artifact = nil
    }

    func removeAll(
        variantKeyDigest _: String,
        namespaceFingerprint _: StorageNamespaceFingerprint,
        namespaceGeneration _: UInt64
    ) async throws {
        artifact = nil
    }
}
