import AkashicCore
import AkashicDisk
import Foundation
import FoveaCore
import FoveaPersistence
import XCTest

final class AkashicHostAdapterTests: XCTestCase {
    func testTypedContentAndPartitionAdapterPreservesExactIdentity_AKASHIC_CT_022()
        async throws
    {
        let root = try makeTemporaryDirectory("akashic-adapter-identity")
        let store = try await AkashicOriginalEncodedStore.open(root: root)
        let data = Data("typed-adapter-identity".utf8)
        let contentID = ContentID(data: data).description
        let namespace = "private:account-secret"

        let publication = try await store.commit(
            data: data,
            contentID: contentID,
            namespace: namespace
        )
        let restored = try await store.read(contentID: contentID, namespace: namespace)
        let manifest = try String(
            decoding: Data(contentsOf: root.appendingPathComponent("manifest.json")),
            as: UTF8.self
        )

        XCTAssertEqual(publication.byteCount, data.count)
        XCTAssertTrue(publication.wasCreated)
        XCTAssertEqual(restored, data)
        XCTAssertTrue(manifest.contains(contentID))
        XCTAssertFalse(manifest.contains(namespace))
    }

    func testTypedStageRemainsInvisibleUntilHostPublication_AKASHIC_CT_023() async throws {
        let root = try makeTemporaryDirectory("akashic-adapter-stage")
        let store = try await AkashicOriginalEncodedStore.open(root: root)
        let data = Data("typed-stage".utf8)
        let contentID = ContentID(data: data).description
        let namespace = "public:typed-stage"

        let stage = try await store.stage(
            data: data,
            contentID: contentID,
            namespace: namespace
        )
        await assertThrowsErrorAsync {
            _ = try await store.read(contentID: contentID, namespace: namespace)
        }
        let publication = try await store.publish(stage)
        XCTAssertTrue(publication.wasCreated)
        let publishedData = try await store.read(
            contentID: contentID,
            namespace: namespace
        )
        XCTAssertEqual(publishedData, data)

        let discardedData = Data("typed-discard".utf8)
        let discardedID = ContentID(data: discardedData).description
        let discardedStage = try await store.stage(
            data: discardedData,
            contentID: discardedID,
            namespace: namespace
        )
        await store.discard(discardedStage)
        await store.discard(discardedStage)
        await assertThrowsErrorAsync {
            _ = try await store.read(contentID: discardedID, namespace: namespace)
        }
    }

    func testTypedPartitionRemovalRevokesOnlySelectedNamespace_AKASHIC_CT_024()
        async throws
    {
        let root = try makeTemporaryDirectory("akashic-adapter-revoke")
        let store = try await AkashicOriginalEncodedStore.open(root: root)
        let data = Data("shared-content".utf8)
        let contentID = ContentID(data: data).description

        _ = try await store.commit(data: data, contentID: contentID, namespace: "account-a")
        _ = try await store.commit(data: data, contentID: contentID, namespace: "account-b")
        let firstPhysicalValue = await store.physicalID(
            contentID: contentID,
            namespace: "account-a"
        )
        let secondPhysicalValue = await store.physicalID(
            contentID: contentID,
            namespace: "account-b"
        )
        let firstPhysical = try XCTUnwrap(firstPhysicalValue)
        let secondPhysical = try XCTUnwrap(secondPhysicalValue)
        XCTAssertNotEqual(firstPhysical, secondPhysical)

        try await store.removeAll(namespace: "account-a")
        await assertThrowsErrorAsync {
            _ = try await store.read(contentID: contentID, namespace: "account-a")
        }
        let retainedData = try await store.read(
            contentID: contentID,
            namespace: "account-b"
        )
        XCTAssertEqual(retainedData, data)
    }

    func testTypedDefaultUsesNewStoreGeneration_AKASHIC_CT_025() async throws {
        let root = try makeTemporaryDirectory("akashic-adapter-generation")
        let legacyFingerprint =
            "fovea-store-v1:original-4:representation-6:namespace-generation-1"
        let legacy = try await StoreGenerationDirectory.open(
            root: root,
            compatibilityFingerprint: legacyFingerprint
        )
        let current = try await FoveaPersistentStores.open(root: root)

        XCTAssertNotEqual(legacy.identifier, current.generation.identifier)
        XCTAssertNotEqual(legacy.root, current.generation.root)
        XCTAssertTrue(
            FoveaPersistentStores.currentCompatibilityFingerprint.hasPrefix(
                "fovea-store-v2:akashic-file-"
            )
        )
    }

    func testTypedStoreHostTracePersistsAcrossReopen_AKASHIC_CT_026() async throws {
        let root = try makeTemporaryDirectory("akashic-typed-host-trace")
        let data = Data("trace-reopen".utf8)
        let contentID = ContentID(data: data).description
        let namespace = "public:typed-host-trace"

        var initial: AkashicOriginalEncodedStore? = try await reopenAkashicOriginalEncodedStore(
            root: root)
        let first = try await initial!.commit(
            data: data,
            contentID: contentID,
            namespace: namespace
        )
        let second = try await initial!.commit(
            data: data,
            contentID: contentID,
            namespace: namespace
        )
        XCTAssertTrue(first.wasCreated)
        XCTAssertFalse(second.wasCreated)
        XCTAssertEqual(first.byteCount, data.count)
        XCTAssertEqual(first.physicalID, second.physicalID)

        initial = nil
        await Task.yield()

        var reopened: AkashicOriginalEncodedStore? = try await reopenAkashicOriginalEncodedStore(
            root: root)
        let reopenedData = try await reopened!.read(
            contentID: contentID,
            namespace: namespace
        )
        XCTAssertEqual(reopenedData, data)
        try await reopened!.remove(contentID: contentID, namespace: namespace)
        reopened = nil
        await Task.yield()

        let afterRemoval = try await reopenAkashicOriginalEncodedStore(root: root)
        await assertThrowsErrorAsync {
            _ = try await afterRemoval.read(contentID: contentID, namespace: namespace)
        }
    }

}
