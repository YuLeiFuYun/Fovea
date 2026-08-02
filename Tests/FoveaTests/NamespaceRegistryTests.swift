import AkashicCore
import FoveaCore
import FoveaStorage
import XCTest

final class NamespaceRegistryTests: XCTestCase {
    func testNamespaceGenerationExhaustionFailsClosedWithoutWraparound_AUTH_PT_016() async throws {
        let namespace = SecurityNamespaceID("generation-exhaustion")
        let registry = NamespaceRegistry(
            initialGenerations: [namespace: NamespaceGeneration(UInt64.max)]
        )

        let before = try await registry.generation(for: namespace)
        let exhausted = try await registry.revoke(namespace)
        let repeated = try await registry.revoke(namespace)

        XCTAssertEqual(before, NamespaceGeneration(UInt64.max))
        XCTAssertEqual(exhausted, NamespaceGeneration(UInt64.max))
        XCTAssertEqual(repeated, NamespaceGeneration(UInt64.max))
        let maxIsActive = await registry.isActive(before, for: namespace)
        let zeroIsActive = await registry.isActive(NamespaceGeneration(0), for: namespace)
        XCTAssertFalse(maxIsActive)
        XCTAssertFalse(zeroIsActive)
    }

    func testUnknownNamespaceStartsAtActiveGenerationZero() async throws {
        let namespace = SecurityNamespaceID("new-namespace")
        let registry = NamespaceRegistry()

        let zeroIsActive = await registry.isActive(NamespaceGeneration(0), for: namespace)
        let generation = try await registry.generation(for: namespace)
        XCTAssertTrue(zeroIsActive)
        XCTAssertEqual(generation, NamespaceGeneration(0))
    }
    func testRevocationBarrierRejectsNewGenerationUntilEveryCleanupLeaseFinishes_AUTH_PT_019()
        async throws
    {
        let namespace = SecurityNamespaceID("revocation-barrier")
        let registry = NamespaceRegistry()
        let original = try await registry.generation(for: namespace)

        let first = try await registry.beginRevocation(namespace)
        let second = try await registry.beginRevocation(namespace)
        XCTAssertEqual(first, NamespaceGeneration(1))
        XCTAssertEqual(second, first)
        let countDuringConcurrentCleanup = await registry.activeRevocationCount(for: namespace)
        let originalActiveDuringCleanup = await registry.isActive(original, for: namespace)
        let currentActiveDuringCleanup = await registry.isActive(first, for: namespace)
        XCTAssertEqual(countDuringConcurrentCleanup, 2)
        XCTAssertFalse(originalActiveDuringCleanup)
        XCTAssertFalse(currentActiveDuringCleanup)

        do {
            _ = try await registry.generation(for: namespace)
            XCTFail("A namespace must remain unavailable while cleanup is active")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .namespaceRevoked)
        }

        await registry.finishRevocation(namespace, generation: first)
        let countAfterFirstCleanup = await registry.activeRevocationCount(for: namespace)
        XCTAssertEqual(countAfterFirstCleanup, 1)
        do {
            _ = try await registry.generation(for: namespace)
            XCTFail("One remaining cleanup lease must keep the barrier closed")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .namespaceRevoked)
        }

        await registry.finishRevocation(namespace, generation: second)
        let countAfterAllCleanup = await registry.activeRevocationCount(for: namespace)
        let reopenedGeneration = try await registry.generation(for: namespace)
        let reopenedIsActive = await registry.isActive(first, for: namespace)
        XCTAssertEqual(countAfterAllCleanup, 0)
        XCTAssertEqual(reopenedGeneration, first)
        XCTAssertTrue(reopenedIsActive)
    }

    func testCancelledRevocationCallerStillReceivesCleanupLease() async throws {
        let persistence = BlockingNamespaceGenerationPersistence()
        let registry = NamespaceRegistry(
            maximumTrackedNamespaces: 8,
            persistedGenerations: [:],
            persistence: persistence
        )
        let namespace = SecurityNamespaceID("cancelled-revocation-caller")
        let task = Task { try await registry.beginRevocation(namespace) }

        await persistence.waitUntilPersisting()
        task.cancel()
        await persistence.release()
        let generation = try await task.value

        let activeBeforeFinish = await registry.activeRevocationCount(for: namespace)
        XCTAssertEqual(generation, NamespaceGeneration(1))
        XCTAssertEqual(activeBeforeFinish, 1)

        await registry.finishRevocation(namespace, generation: generation)
        let activeAfterFinish = await registry.activeRevocationCount(for: namespace)
        let reopened = try await registry.generation(for: namespace)
        XCTAssertEqual(activeAfterFinish, 0)
        XCTAssertEqual(reopened, generation)
    }

    func testNamespaceCapacityRejectsNewEntriesWithoutDisturbingTrackedState() async throws {
        let first = SecurityNamespaceID("capacity-first")
        let second = SecurityNamespaceID("capacity-second")
        let rejected = SecurityNamespaceID("capacity-rejected")
        let registry = NamespaceRegistry(maximumTrackedNamespaces: 2)

        let firstGeneration = try await registry.generation(for: first)
        _ = try await registry.generation(for: second)
        do {
            _ = try await registry.generation(for: rejected)
            XCTFail("A full namespace registry must reject a new namespace")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .resourceLimit)
            XCTAssertEqual(failure.stage, .requestValidation)
            XCTAssertEqual(failure.reasonCode, "namespace-registry-capacity-exceeded")
        }

        let trackedCount = await registry.trackedNamespaceCount()
        let firstIsActive = await registry.isActive(firstGeneration, for: first)
        XCTAssertEqual(trackedCount, 2)
        XCTAssertTrue(firstIsActive)
        let revoked = try await registry.revoke(first)
        XCTAssertEqual(revoked, NamespaceGeneration(1))
        let firstIsRevoked = await registry.isActive(firstGeneration, for: first)
        XCTAssertFalse(firstIsRevoked)
    }

    func testRevokingUnknownNamespaceAtCapacityFailsClosed() async throws {
        let registry = NamespaceRegistry(maximumTrackedNamespaces: 1)
        _ = try await registry.generation(for: SecurityNamespaceID("tracked"))

        do {
            _ = try await registry.revoke(SecurityNamespaceID("unknown"))
            XCTFail("Revoking an untracked namespace must not bypass the registry capacity")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .resourceLimit)
            XCTAssertEqual(failure.stage, .revocation)
            XCTAssertEqual(failure.reasonCode, "namespace-registry-capacity-exceeded")
        }
        let trackedCount = await registry.trackedNamespaceCount()
        XCTAssertEqual(trackedCount, 1)
    }

}

private actor BlockingNamespaceGenerationPersistence: NamespaceGenerationPersisting {
    private var persistStarted = false
    private var releaseRequested = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func load(maximumCount: Int) async throws -> [StorageNamespaceFingerprint: UInt64] {
        [:]
    }

    func persist(
        _ generation: UInt64,
        for namespace: StorageNamespaceFingerprint
    ) async throws {
        persistStarted = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll(keepingCapacity: false)
        guard !releaseRequested else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilPersisting() async {
        guard !persistStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseRequested = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll(keepingCapacity: false)
    }
}
