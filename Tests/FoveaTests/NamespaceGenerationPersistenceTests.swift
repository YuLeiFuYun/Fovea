import AkashicCore
import Foundation
import FoveaCore
import FoveaPersistence
import FoveaStorage
import XCTest

final class NamespaceGenerationPersistenceTests: XCTestCase {
    func testDurableAdvancePreventsStaleGenerationAfterRegistryRecreation_AUTH_PT_020()
        async throws
    {
        let root = try makeTemporaryDirectory("namespace-generation-restart")
        let namespace = SecurityNamespaceID("account-with-sensitive-identifier")
        var store: NamespaceGenerationStore? = try await NamespaceGenerationStore.open(
            root: root,
            maximumCount: 16
        )
        let firstStore = try XCTUnwrap(store)
        let firstRegistry = try await NamespaceRegistry.open(
            maximumTrackedNamespaces: 16,
            persistence: firstStore
        )

        let advanced = try await firstRegistry.beginRevocation(namespace)
        XCTAssertEqual(advanced, NamespaceGeneration(1))
        // 模拟持久缓存 cleanup 失败后进程结束：世代已发布，但不删除任何旧数据。
        await firstRegistry.finishRevocation(namespace, generation: advanced)
        store = nil

        let reopenedStore = try await NamespaceGenerationStore.open(root: root, maximumCount: 16)
        let reopenedRegistry = try await NamespaceRegistry.open(
            maximumTrackedNamespaces: 16,
            persistence: reopenedStore
        )

        let staleGenerationIsActive = await reopenedRegistry.isActive(
            NamespaceGeneration(0),
            for: namespace
        )
        let current = try await reopenedRegistry.generation(for: namespace)
        XCTAssertFalse(staleGenerationIsActive)
        XCTAssertEqual(current, NamespaceGeneration(1))

        let manifestURL = root.appendingPathComponent("namespace-generations.json")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertFalse(manifest.contains(namespace.value))
        XCTAssertTrue(
            manifest.contains(StorageNamespaceFingerprint(namespace: namespace.value).value))
    }

    func testConcurrentRevocationsShareOneDurableAdvance_AUTH_PT_020() async throws {
        let persistence = RecordingNamespaceGenerationPersistence()
        let registry = NamespaceRegistry(
            maximumTrackedNamespaces: 8,
            persistedGenerations: [:],
            persistence: persistence
        )
        let namespace = SecurityNamespaceID("concurrent-durable-revoke")

        async let first = registry.beginRevocation(namespace)
        async let second = registry.beginRevocation(namespace)
        let generations = try await [first, second]

        let persistCount = await persistence.persistCount
        let activeRevocationCount = await registry.activeRevocationCount(for: namespace)
        XCTAssertEqual(generations, [NamespaceGeneration(1), NamespaceGeneration(1)])
        XCTAssertEqual(persistCount, 1)
        XCTAssertEqual(activeRevocationCount, 2)
        await registry.finishRevocation(namespace, generation: generations[0])
        await registry.finishRevocation(namespace, generation: generations[1])
    }

    func testPersistenceFailureLeavesPreviousGenerationActive_AUTH_PT_020() async throws {
        let persistence = RecordingNamespaceGenerationPersistence(shouldFail: true)
        let registry = NamespaceRegistry(
            maximumTrackedNamespaces: 8,
            persistedGenerations: [:],
            persistence: persistence
        )
        let namespace = SecurityNamespaceID("failed-durable-revoke")

        do {
            _ = try await registry.beginRevocation(namespace)
            XCTFail("A failed durable publication must fail the revocation before cleanup")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.stage, .revocation)
            XCTAssertEqual(failure.reasonCode, "namespace-generation-persistence-failed")
            XCTAssertEqual(failure.disposition, .terminal)
        }

        let currentGeneration = try await registry.generation(for: namespace)
        let previousGenerationIsActive = await registry.isActive(
            NamespaceGeneration(0),
            for: namespace
        )
        let activeRevocationCount = await registry.activeRevocationCount(for: namespace)
        XCTAssertEqual(currentGeneration, NamespaceGeneration(0))
        XCTAssertTrue(previousGenerationIsActive)
        XCTAssertEqual(activeRevocationCount, 0)
    }

    func testFutureNamespaceGenerationManifestFailsClosedWithoutRewrite_CACHE_PT_021() async throws
    {
        let root = try makeTemporaryDirectory("namespace-generation-future-schema")
        let fileURL = root.appendingPathComponent("namespace-generations.json")
        let original = Data(#"{"schemaVersion":999,"generations":{}}"#.utf8)
        try original.write(to: fileURL, options: .atomic)

        do {
            _ = try await NamespaceGenerationStore.open(root: root, maximumCount: 16)
            XCTFail("未来 namespace generation schema 必须失败关闭")
        } catch {
            XCTAssertEqual(error as? NamespaceGenerationStoreError, .invalidManifest)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }
}

private actor RecordingNamespaceGenerationPersistence: NamespaceGenerationPersisting {
    private let shouldFail: Bool
    private var values: [StorageNamespaceFingerprint: UInt64] = [:]
    private(set) var persistCount = 0

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func load(
        maximumCount: Int
    ) async throws -> [StorageNamespaceFingerprint: UInt64] {
        values
    }

    func persist(
        _ generation: UInt64,
        for namespace: StorageNamespaceFingerprint
    ) async throws {
        persistCount += 1
        if shouldFail { throw TestPersistenceError.rejected }
        values[namespace] = generation
    }
}

private enum TestPersistenceError: Error {
    case rejected
}
