import AkashicCore
import AkashicDisk
import Foundation
import FoveaCore
import FoveaPersistence
import XCTest

final class StoreGenerationTests: XCTestCase {
    func
        testPersistentStoreBundleReusesCompatibleGenerationAndIsolatesIncompatibleOne_CACHE_PT_019()
        async throws
    {
        let root = try makeTemporaryDirectory()
        let first = try await FoveaPersistentStores.open(
            root: root,
            compatibilityFingerprint: "schema-v1"
        )
        let data = Data("generation-data".utf8)
        let contentID = ContentID(data: data).description
        _ = try await first.encoded.commit(
            data: data,
            contentID: contentID,
            namespace: "public:tests"
        )

        let same = try await FoveaPersistentStores.open(
            root: root,
            compatibilityFingerprint: "schema-v1"
        )
        XCTAssertEqual(first.generation.identifier, same.generation.identifier)
        XCTAssertTrue(first.encoded === same.encoded)
        XCTAssertTrue(first.records === same.records)
        let reopenedData = try await same.encoded.read(
            contentID: contentID,
            namespace: "public:tests"
        )
        XCTAssertEqual(reopenedData, data)

        let switched = try await FoveaPersistentStores.open(
            root: root,
            compatibilityFingerprint: "schema-v2"
        )
        XCTAssertNotEqual(first.generation.identifier, switched.generation.identifier)
        await assertThrowsErrorAsync {
            _ = try await switched.encoded.read(contentID: contentID, namespace: "public:tests")
        }
    }
    func testPersistentStoreRegistryDoesNotRetainReleasedStoreActors() async throws {
        let root = try makeTemporaryDirectory()
        var stores: FoveaPersistentStores? = try await FoveaPersistentStores.open(root: root)
        weak let releasedEncoded = stores?.encoded
        weak let releasedRecords = stores?.records
        stores = nil
        try await waitUntil("store actors 释放后允许重新打开") {
            releasedEncoded == nil && releasedRecords == nil
        }

        XCTAssertNil(releasedEncoded)
        XCTAssertNil(releasedRecords)

        let reopened = try await FoveaPersistentStores.open(root: root)
        let data = Data("reopened-after-release".utf8)
        let contentID = ContentID(data: data).description
        _ = try await reopened.encoded.commit(
            data: data,
            contentID: contentID,
            namespace: "public:tests"
        )
        let reopenedData = try await reopened.encoded.read(
            contentID: contentID,
            namespace: "public:tests"
        )
        XCTAssertEqual(reopenedData, data)
    }

    func testPersistentStoreRegistryPrunesReleasedHighCardinalityRoots() async throws {
        for index in 0..<64 {
            var stores: FoveaPersistentStores? = try await FoveaPersistentStores.open(
                root: try makeTemporaryDirectory("registry-root-\(index)")
            )
            XCTAssertNotNil(stores)
            stores = nil
        }

        _ = try await FoveaPersistentStores.open(
            root: try makeTemporaryDirectory("registry-root-final")
        )
        let entryCount = await FoveaPersistentStores.registryEntryCountForTesting()
        XCTAssertLessThanOrEqual(entryCount, 1)
    }

    func testReleasedGenerationCanReopenWithDifferentRuntimeBudget() async throws {
        let root = try makeTemporaryDirectory("released-budget-reopen")
        var stores: FoveaPersistentStores? = try await FoveaPersistentStores.open(
            root: root,
            compatibilityFingerprint: "schema-v1",
            encodedSoftTotalBytes: 1_024
        )
        weak let releasedEncoded = stores?.encoded
        stores = nil
        try await waitUntil("旧预算 store actor 释放") {
            releasedEncoded == nil
        }
        XCTAssertNil(releasedEncoded)

        let reopened = try await FoveaPersistentStores.open(
            root: root,
            compatibilityFingerprint: "schema-v1",
            encodedSoftTotalBytes: 2_048
        )
        XCTAssertFalse(reopened.generation.identifier.rawValue.uuidString.isEmpty)
    }

    func testActiveGenerationRejectsDivergentStoreConfiguration_CACHE_PT_024() async throws {
        let root = try makeTemporaryDirectory()
        let active = try await FoveaPersistentStores.open(
            root: root,
            compatibilityFingerprint: "schema-v1",
            encodedSoftTotalBytes: 1024
        )

        do {
            _ = try await FoveaPersistentStores.open(
                root: root,
                compatibilityFingerprint: "schema-v1",
                encodedSoftTotalBytes: 2048
            )
            XCTFail("同一活动 generation 不得创建不同预算的第二 store actor")
        } catch let error as FoveaPersistenceError {
            XCTAssertEqual(error, .incompatibleActiveConfiguration)
        }

        do {
            _ = try await FoveaPersistentStores.open(
                root: root,
                compatibilityFingerprint: "schema-v1",
                encodedSoftTotalBytes: 1024,
                maximumTrackedNamespaces: 8_192
            )
            XCTFail("同一活动 generation 不得复用不同 namespace 容量的世代存储")
        } catch let error as FoveaPersistenceError {
            XCTAssertEqual(error, .incompatibleActiveConfiguration)
        }
        XCTAssertFalse(active.generation.identifier.rawValue.uuidString.isEmpty)
    }

}
