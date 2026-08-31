import AkashicCore
import CryptoKit
import FoveaCore
import FoveaPersistence
import FoveaStorage
import XCTest

final class DerivedRasterPersistenceTests: XCTestCase {
    func testCommitLoadDecodeAndReopen_W11_PT_015() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(namespace: "account-a", generation: 4, label: "primary")

        var store: AkashicDerivedRasterStore? = try await AkashicDerivedRasterStore.open(
            root: root, limits: permissiveStoreLimits())
        try await store?.commit(container: fixture.container, record: fixture.record)
        let loadedValue = try await store?.load(
            artifactKeyDigest: fixture.record.artifactKeyDigest,
            namespaceFingerprint: fixture.record.namespaceFingerprint,
            namespaceGeneration: fixture.record.namespaceGeneration
        )
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.container, fixture.container)
        let decoded = try DerivedRasterContainer.decode(
            loaded.container,
            expectedContainerDigestHex: sha256(loaded.container)
        )
        XCTAssertEqual(decoded.pixelData, fixture.pixels)
        store = nil
        await Task.yield()

        let reopened = try await AkashicDerivedRasterStore.open(
            root: root, limits: permissiveStoreLimits())
        let reopenedValue = try await reopened.load(
            artifactKeyDigest: fixture.record.artifactKeyDigest,
            namespaceFingerprint: fixture.record.namespaceFingerprint,
            namespaceGeneration: fixture.record.namespaceGeneration
        )
        let reopenedArtifact = try XCTUnwrap(reopenedValue)
        XCTAssertEqual(reopenedArtifact.record, fixture.record)
        XCTAssertEqual(reopenedArtifact.container, fixture.container)
    }

    func testSharedContainerReferenceSurvivesOneAliasRemoval_W11_PT_016() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeFixture(namespace: "account-a", generation: 1, label: "first")
        let secondRecord = try makeRecord(
            container: first.container,
            pixels: first.pixels,
            namespace: "account-a",
            generation: 1,
            label: "second",
            variantLabel: "shared-variant"
        )
        let store = try await AkashicDerivedRasterStore.open(
            root: root, limits: permissiveStoreLimits())
        try await store.commit(container: first.container, record: first.record)
        try await store.commit(container: first.container, record: secondRecord)
        let firstPhysical = await store.physicalIDForTesting(first.record)
        let physical = try XCTUnwrap(firstPhysical)
        let secondPhysical = await store.physicalIDForTesting(secondRecord)
        XCTAssertEqual(secondPhysical, physical)

        try await store.remove(
            artifactKeyDigest: first.record.artifactKeyDigest,
            namespaceFingerprint: first.record.namespaceFingerprint,
            namespaceGeneration: first.record.namespaceGeneration
        )
        let removedFirst = try await store.load(
            artifactKeyDigest: first.record.artifactKeyDigest,
            namespaceFingerprint: first.record.namespaceFingerprint,
            namespaceGeneration: first.record.namespaceGeneration
        )
        let retainedSecond = try await store.load(
            artifactKeyDigest: secondRecord.artifactKeyDigest,
            namespaceFingerprint: secondRecord.namespaceFingerprint,
            namespaceGeneration: secondRecord.namespaceGeneration
        )
        let retainedPhysical = await store.physicalIDForTesting(secondRecord)
        XCTAssertNil(removedFirst)
        XCTAssertNotNil(retainedSecond)
        XCTAssertEqual(retainedPhysical, physical)

        try await store.remove(
            artifactKeyDigest: secondRecord.artifactKeyDigest,
            namespaceFingerprint: secondRecord.namespaceFingerprint,
            namespaceGeneration: secondRecord.namespaceGeneration
        )
        let removedPhysical = await store.physicalIDForTesting(secondRecord)
        XCTAssertNil(removedPhysical)
    }

    func testNamespaceGenerationAndVariantRemovalAreExact_W11_PT_017() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeFixture(
            namespace: "account-a",
            generation: 7,
            label: "first",
            variantLabel: "variant-a"
        )
        let second = try makeFixture(
            namespace: "account-a",
            generation: 7,
            label: "second",
            variantLabel: "variant-b"
        )
        let store = try await AkashicDerivedRasterStore.open(
            root: root, limits: permissiveStoreLimits())
        try await store.commit(container: first.container, record: first.record)
        try await store.commit(container: second.container, record: second.record)

        let wrongGeneration = try await store.load(
            artifactKeyDigest: first.record.artifactKeyDigest,
            namespaceFingerprint: first.record.namespaceFingerprint,
            namespaceGeneration: 8
        )
        let wrongNamespace = try await store.load(
            artifactKeyDigest: first.record.artifactKeyDigest,
            namespaceFingerprint: StorageNamespaceFingerprint(namespace: "account-b"),
            namespaceGeneration: 7
        )
        XCTAssertNil(wrongGeneration)
        XCTAssertNil(wrongNamespace)

        try await store.removeAll(
            variantKeyDigest: first.record.variantKeyDigest,
            namespaceFingerprint: first.record.namespaceFingerprint,
            namespaceGeneration: 7
        )
        let removedVariant = try await store.load(
            artifactKeyDigest: first.record.artifactKeyDigest,
            namespaceFingerprint: first.record.namespaceFingerprint,
            namespaceGeneration: 7
        )
        let retainedVariant = try await store.load(
            artifactKeyDigest: second.record.artifactKeyDigest,
            namespaceFingerprint: second.record.namespaceFingerprint,
            namespaceGeneration: 7
        )
        XCTAssertNil(removedVariant)
        XCTAssertNotNil(retainedVariant)
    }

    func testSoftBudgetEvictsOldestPhysicalBlobAndAliasTogether_W11_PT_040() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeFixture(
            namespace: "account-a",
            generation: 1,
            label: "budget-first",
            pixelSalt: 1,
            createdAt: 1_000
        )
        let second = try makeFixture(
            namespace: "account-a",
            generation: 1,
            label: "budget-second",
            pixelSalt: 2,
            createdAt: 1_001
        )
        let maximumBlobBytes = max(first.container.count, second.container.count)
        let store = try await AkashicDerivedRasterStore.open(
            root: root,
            limits: DerivedRasterStoreLimits(
                softTotalBytes: maximumBlobBytes,
                maximumBlobBytes: maximumBlobBytes,
                maximumWriteBytesPerWindow: 1024 * 1024 * 1024,
                writeBudgetWindowNanoseconds: 60_000_000_000
            )
        )

        try await store.commit(container: first.container, record: first.record)
        try await store.commit(container: second.container, record: second.record)

        let evicted = try await store.load(
            artifactKeyDigest: first.record.artifactKeyDigest,
            namespaceFingerprint: first.record.namespaceFingerprint,
            namespaceGeneration: first.record.namespaceGeneration
        )
        let retained = try await store.load(
            artifactKeyDigest: second.record.artifactKeyDigest,
            namespaceFingerprint: second.record.namespaceFingerprint,
            namespaceGeneration: second.record.namespaceGeneration
        )
        let firstPhysical = await store.physicalIDForTesting(first.record)
        let secondPhysical = await store.physicalIDForTesting(second.record)
        let retainedRecords = await store.recordsForTesting()
        XCTAssertNil(evicted)
        XCTAssertNotNil(retained)
        XCTAssertNil(firstPhysical)
        XCTAssertNotNil(secondPhysical)
        XCTAssertEqual(retainedRecords, [second.record])
    }

    func testSoftBudgetEvictsAllAliasesForSharedPhysicalBlob_W11_PT_041() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeFixture(
            namespace: "account-a",
            generation: 1,
            label: "shared-budget-first",
            variantLabel: "shared-budget-a",
            pixelSalt: 3,
            createdAt: 1_000
        )
        let sharedAlias = try makeRecord(
            container: first.container,
            pixels: first.pixels,
            namespace: "account-a",
            generation: 1,
            label: "shared-budget-alias",
            variantLabel: "shared-budget-b",
            createdAt: 1_001
        )
        let second = try makeFixture(
            namespace: "account-a",
            generation: 1,
            label: "shared-budget-second",
            pixelSalt: 4,
            createdAt: 1_002
        )
        let maximumBlobBytes = max(first.container.count, second.container.count)
        let store = try await AkashicDerivedRasterStore.open(
            root: root,
            limits: DerivedRasterStoreLimits(
                softTotalBytes: maximumBlobBytes,
                maximumBlobBytes: maximumBlobBytes,
                maximumWriteBytesPerWindow: 1024 * 1024 * 1024,
                writeBudgetWindowNanoseconds: 60_000_000_000
            )
        )

        try await store.commit(container: first.container, record: first.record)
        try await store.commit(container: first.container, record: sharedAlias)
        let recordsBeforeTrim = await store.recordsForTesting()
        XCTAssertEqual(recordsBeforeTrim.count, 2)
        try await store.commit(container: second.container, record: second.record)

        let firstAlias = try await store.load(
            artifactKeyDigest: first.record.artifactKeyDigest,
            namespaceFingerprint: first.record.namespaceFingerprint,
            namespaceGeneration: first.record.namespaceGeneration
        )
        let secondAlias = try await store.load(
            artifactKeyDigest: sharedAlias.artifactKeyDigest,
            namespaceFingerprint: sharedAlias.namespaceFingerprint,
            namespaceGeneration: sharedAlias.namespaceGeneration
        )
        let sharedPhysical = await store.physicalIDForTesting(first.record)
        let recordsAfterTrim = await store.recordsForTesting()
        XCTAssertNil(firstAlias)
        XCTAssertNil(secondAlias)
        XCTAssertNil(sharedPhysical)
        XCTAssertEqual(recordsAfterTrim, [second.record])
    }

    func testSoftBudgetGivesRecentlyReadBlobOneSecondChance_W11_PT_042() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeFixture(
            namespace: "account-a", generation: 1, label: "recent-first", pixelSalt: 5,
            createdAt: 1_000
        )
        let second = try makeFixture(
            namespace: "account-a", generation: 1, label: "recent-second", pixelSalt: 6,
            createdAt: 1_001
        )
        let third = try makeFixture(
            namespace: "account-a", generation: 1, label: "recent-third", pixelSalt: 7,
            createdAt: 1_002
        )
        let pairByteLimit = max(
            first.container.count + second.container.count,
            max(
                first.container.count + third.container.count,
                second.container.count + third.container.count
            )
        )
        let store = try await AkashicDerivedRasterStore.open(
            root: root,
            limits: DerivedRasterStoreLimits(
                softTotalBytes: pairByteLimit,
                maximumBlobBytes: max(
                    first.container.count, max(second.container.count, third.container.count)
                ),
                maximumWriteBytesPerWindow: 1024 * 1024 * 1024,
                writeBudgetWindowNanoseconds: 60_000_000_000
            )
        )

        try await store.commit(container: first.container, record: first.record)
        try await store.commit(container: second.container, record: second.record)
        let firstHit = try await store.load(
            artifactKeyDigest: first.record.artifactKeyDigest,
            namespaceFingerprint: first.record.namespaceFingerprint,
            namespaceGeneration: first.record.namespaceGeneration
        )
        XCTAssertNotNil(firstHit)
        try await store.commit(container: third.container, record: third.record)

        let retainedRecent = try await store.load(
            artifactKeyDigest: first.record.artifactKeyDigest,
            namespaceFingerprint: first.record.namespaceFingerprint,
            namespaceGeneration: first.record.namespaceGeneration
        )
        let evictedCold = try await store.load(
            artifactKeyDigest: second.record.artifactKeyDigest,
            namespaceFingerprint: second.record.namespaceFingerprint,
            namespaceGeneration: second.record.namespaceGeneration
        )
        let retainedNewest = try await store.load(
            artifactKeyDigest: third.record.artifactKeyDigest,
            namespaceFingerprint: third.record.namespaceFingerprint,
            namespaceGeneration: third.record.namespaceGeneration
        )
        XCTAssertNotNil(retainedRecent)
        XCTAssertNil(evictedCold)
        XCTAssertNotNil(retainedNewest)
    }

    func testConcurrentNonisolatedLoadsPreserveArtifactIdentity_W11_PT_064() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(
            namespace: "account-a",
            generation: 1,
            label: "concurrent-read",
            pixelSalt: 17,
            createdAt: 1_000
        )
        let store = try await AkashicDerivedRasterStore.open(
            root: root,
            limits: permissiveStoreLimits()
        )
        try await store.commit(container: fixture.container, record: fixture.record)

        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    guard
                        let loaded = try await store.load(
                            artifactKeyDigest: fixture.record.artifactKeyDigest,
                            namespaceFingerprint: fixture.record.namespaceFingerprint,
                            namespaceGeneration: fixture.record.namespaceGeneration
                        )
                    else { return false }
                    return loaded.record == fixture.record
                        && loaded.container == fixture.container
                        && loaded.recordValidated
                        && loaded.containerContentDigestVerified
                }
            }
            for try await valid in group {
                XCTAssertTrue(valid)
            }
        }
    }

    func testDurableWriteBudgetChargesPayloadPlusAliasManifestBeforeBlob_W11_PT_043() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(
            namespace: "account-a",
            generation: 1,
            label: "write-budget-charge",
            pixelSalt: 8,
            createdAt: 1_000
        )
        let store = try await AkashicDerivedRasterStore.open(
            root: root,
            limits: DerivedRasterStoreLimits(
                softTotalBytes: max(64 * 1024, fixture.container.count),
                maximumBlobBytes: max(64 * 1024, fixture.container.count),
                maximumWriteBytesPerWindow: fixture.container.count,
                writeBudgetWindowNanoseconds: 60_000_000_000
            )
        )

        do {
            try await store.commit(container: fixture.container, record: fixture.record)
            XCTFail("payload-only budget must reject the additional alias-manifest rewrite cost")
        } catch let error as DerivedRasterStoreError {
            guard case .writeBudgetExceeded(let logicalWriteChargeBytes, let maximumBytes) = error
            else {
                return XCTFail("unexpected derived-raster store error: \(error)")
            }
            XCTAssertGreaterThan(logicalWriteChargeBytes, fixture.container.count)
            XCTAssertEqual(maximumBytes, fixture.container.count)
        }

        let physical = await store.physicalIDForTesting(fixture.record)
        let records = await store.recordsForTesting()
        XCTAssertNil(physical)
        XCTAssertTrue(records.isEmpty)
    }

    func testWriteBudgetReservationSurvivesReopenAndOnlyForwardTimeResets_W11_PT_044() async throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date(timeIntervalSinceReferenceDate: 10_000)
        let window: UInt64 = 10_000_000_000

        var budget: DerivedRasterWriteBudgetStore? = try await DerivedRasterWriteBudgetStore.open(
            root: root)
        let firstReservation =
            try await budget?.reserve(
                byteCount: 60,
                at: started,
                maximumBytes: 100,
                windowNanoseconds: window
            ) ?? false
        XCTAssertTrue(firstReservation)
        let overBudgetReservation =
            try await budget?.reserve(
                byteCount: 41,
                at: started.addingTimeInterval(1),
                maximumBytes: 100,
                windowNanoseconds: window
            ) ?? true
        XCTAssertFalse(overBudgetReservation)
        budget = nil

        let reopened = try await DerivedRasterWriteBudgetStore.open(root: root)
        let reservedAfterReopen = await reopened.reservedBytesForTesting()
        XCTAssertEqual(reservedAfterReopen, 60)
        let backwardClockReservation = try await reopened.reserve(
            byteCount: 41,
            at: started.addingTimeInterval(-100),
            maximumBytes: 100,
            windowNanoseconds: window
        )
        XCTAssertFalse(backwardClockReservation)
        let nextWindowReservation = try await reopened.reserve(
            byteCount: 41,
            at: started.addingTimeInterval(10),
            maximumBytes: 100,
            windowNanoseconds: window
        )
        XCTAssertTrue(nextWindowReservation)
        let reservedInNextWindow = await reopened.reservedBytesForTesting()
        XCTAssertEqual(reservedInNextWindow, 41)
    }

    func testFailedPublicationKeepsWriteReservationConsumed_W11_PT_046() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(
            namespace: "account-a",
            generation: 1,
            label: "write-budget-failed-publication",
            pixelSalt: 9
        )
        let projectionRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: projectionRoot) }
        let projection = try await DerivedRasterRecordStore.open(root: projectionRoot)
        let manifestBytes = try await projection.projectedManifestByteCount(putting: fixture.record)
        let exactCharge = fixture.container.count + manifestBytes
        let limits = DerivedRasterStoreLimits(
            softTotalBytes: max(64 * 1024, fixture.container.count),
            maximumBlobBytes: max(64 * 1024, fixture.container.count),
            maximumWriteBytesPerWindow: exactCharge,
            writeBudgetWindowNanoseconds: 60_000_000_000
        )
        let store = try await AkashicDerivedRasterStore.open(root: root, limits: limits)
        let permission = ScriptedDerivedRasterPublicationPermission([true, true, false])

        do {
            try await store.commit(
                container: fixture.container,
                record: fixture.record,
                publicationPermission: permission
            )
            XCTFail("closed post-blob fence must fail")
        } catch let error as AkashicError {
            XCTAssertEqual(error, .transactionConflict)
        }
        let physicalAfterFailedPublication = await store.physicalIDForTesting(fixture.record)
        XCTAssertNil(physicalAfterFailedPublication)

        do {
            try await store.commit(container: fixture.container, record: fixture.record)
            XCTFail("failed publication must not refund an already durable write reservation")
        } catch let error as DerivedRasterStoreError {
            guard case .writeBudgetExceeded = error else {
                return XCTFail("unexpected derived-raster store error: \(error)")
            }
        }
        let recordsAfterRejectedRetry = await store.recordsForTesting()
        XCTAssertTrue(recordsAfterRejectedRetry.isEmpty)
    }

    func testCorruptWriteBudgetStateFailsClosedOnReopen_W11_PT_047() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(
            namespace: "account-a", generation: 1, label: "write-budget-corrupt", pixelSalt: 10
        )
        var store: AkashicDerivedRasterStore? = try await AkashicDerivedRasterStore.open(
            root: root, limits: permissiveStoreLimits())
        try await store?.commit(container: fixture.container, record: fixture.record)
        store = nil
        await Task.yield()

        let budgetFile =
            root
            .appendingPathComponent("write-budget", isDirectory: true)
            .appendingPathComponent("derived-raster-write-budget.json")
        try Data(#"{"schemaVersion":2,"windowStartedAt":0,"reservedBytes":0}"#.utf8)
            .write(to: budgetFile)

        do {
            _ = try await AkashicDerivedRasterStore.open(
                root: root, limits: permissiveStoreLimits())
            XCTFail("corrupt or future write-budget state must not reset the budget")
        } catch let error as AkashicError {
            XCTAssertEqual(error, .invalidManifest)
        }
    }

    func testArtifactTimestampCannotAdvanceWriteBudgetWindow_W11_PT_048() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeFixture(
            namespace: "account-a",
            generation: 1,
            label: "timestamp-spoof",
            pixelSalt: 11,
            createdAt: 900_000_000
        )
        let replacement = try makeRecord(
            container: first.container,
            pixels: first.pixels,
            namespace: "account-a",
            generation: 1,
            label: "timestamp-spoof",
            variantLabel: "shared-variant",
            createdAt: 999_000_000
        )
        let projectionRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: projectionRoot) }
        let projection = try await DerivedRasterRecordStore.open(root: projectionRoot)
        let firstManifestBytes = try await projection.projectedManifestByteCount(
            putting: first.record)
        try await projection.put(first.record)
        let replacementManifestBytes = try await projection.projectedManifestByteCount(
            putting: replacement)
        XCTAssertEqual(firstManifestBytes, replacementManifestBytes)
        let exactCharge = first.container.count + firstManifestBytes
        let store = try await AkashicDerivedRasterStore.open(
            root: root,
            limits: DerivedRasterStoreLimits(
                softTotalBytes: max(64 * 1024, first.container.count),
                maximumBlobBytes: max(64 * 1024, first.container.count),
                maximumWriteBytesPerWindow: exactCharge,
                writeBudgetWindowNanoseconds: 60_000_000_000
            )
        )

        try await store.commit(container: first.container, record: first.record)
        do {
            try await store.commit(container: first.container, record: replacement)
            XCTFail("artifact createdAt must not advance the persistence-owned write window")
        } catch let error as DerivedRasterStoreError {
            guard case .writeBudgetExceeded = error else {
                return XCTFail("unexpected derived-raster store error: \(error)")
            }
        }
        let retained = try await store.load(
            artifactKeyDigest: first.record.artifactKeyDigest,
            namespaceFingerprint: first.record.namespaceFingerprint,
            namespaceGeneration: first.record.namespaceGeneration
        )
        XCTAssertEqual(retained?.record, first.record)
    }

    func testRecordPublicationFailureCleansUnreachableBlob_W11_PT_018() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(namespace: "account-a", generation: 1, label: "orphan")
        let store = try await AkashicDerivedRasterStore.open(
            root: root, limits: permissiveStoreLimits())
        let recordsRoot = root.appendingPathComponent("records", isDirectory: true)
        XCTAssertEqual(chmod(recordsRoot.path, 0o500), 0)
        defer { _ = chmod(recordsRoot.path, 0o700) }

        do {
            try await store.commit(container: fixture.container, record: fixture.record)
            XCTFail("record publication should fail when its directory is not writable")
        } catch {
            let unreachablePhysical = await store.physicalIDForTesting(fixture.record)
            XCTAssertNil(unreachablePhysical)
        }
        XCTAssertEqual(chmod(recordsRoot.path, 0o700), 0)
        let result = try await store.garbageCollect()
        XCTAssertEqual(result.removedBlobCount, 0)
        XCTAssertEqual(result.removedByteCount, 0)
        let retainedRecords = await store.recordsForTesting()
        XCTAssertTrue(retainedRecords.isEmpty)
    }

    func testClosedPublicationFenceAfterBlobPublishCleansBlob_W11_PT_021() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(namespace: "account-a", generation: 1, label: "fenced")
        let store = try await AkashicDerivedRasterStore.open(
            root: root, limits: permissiveStoreLimits())
        let permission = ScriptedDerivedRasterPublicationPermission([true, true, false])

        do {
            try await store.commit(
                container: fixture.container,
                record: fixture.record,
                publicationPermission: permission
            )
            XCTFail("closed publication fence must reject alias publication")
        } catch let error as AkashicError {
            XCTAssertEqual(error, .transactionConflict)
        }
        let unreachablePhysical = await store.physicalIDForTesting(fixture.record)
        let records = await store.recordsForTesting()
        XCTAssertNil(unreachablePhysical)
        XCTAssertTrue(records.isEmpty)

        let result = try await store.garbageCollect()
        XCTAssertEqual(result.removedBlobCount, 0)
        XCTAssertEqual(result.removedByteCount, 0)
    }

    func testClosedFenceAfterAliasPublicationRollsBackRecordAndBlob_W11_PT_034()
        async throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(
            namespace: "account-a",
            generation: 1,
            label: "post-alias-fenced"
        )
        let store = try await AkashicDerivedRasterStore.open(
            root: root, limits: permissiveStoreLimits())
        let permission = ScriptedDerivedRasterPublicationPermission([true, true, true, false])

        do {
            try await store.commit(
                container: fixture.container,
                record: fixture.record,
                publicationPermission: permission
            )
            XCTFail("closed post-alias fence must roll back publication")
        } catch let error as AkashicError {
            XCTAssertEqual(error, .transactionConflict)
        }

        let physical = await store.physicalIDForTesting(fixture.record)
        let records = await store.recordsForTesting()
        XCTAssertNil(physical)
        XCTAssertTrue(records.isEmpty)
    }

    func testPhysicalContainerCorruptionIsRejectedAndQuarantinedByAkashic_W11_PT_029() async throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(
            namespace: "account-a", generation: 1, label: "physical-corruption")
        let store = try await AkashicDerivedRasterStore.open(
            root: root, limits: permissiveStoreLimits())
        try await store.commit(container: fixture.container, record: fixture.record)
        let physicalValue = await store.physicalIDForTesting(fixture.record)
        let physical = try XCTUnwrap(physicalValue)
        let blobURL =
            root
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(physical.rawValue.uuidString.lowercased())
        var corrupted = try Data(contentsOf: blobURL)
        corrupted[corrupted.count - 1] ^= 0xFF
        try corrupted.write(to: blobURL)

        do {
            _ = try await store.load(
                artifactKeyDigest: fixture.record.artifactKeyDigest,
                namespaceFingerprint: fixture.record.namespaceFingerprint,
                namespaceGeneration: fixture.record.namespaceGeneration
            )
            XCTFail("Akashic must reject corrupt physical bytes")
        } catch let error as AkashicError {
            XCTAssertEqual(error, .integrityMismatch)
        }
        let quarantinedPhysical = await store.physicalIDForTesting(fixture.record)
        XCTAssertNil(quarantinedPhysical)
    }

    func testRecordManifestCorruptionFailsClosedOnReopen_W11_PT_019() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(namespace: "account-a", generation: 1, label: "corrupt")
        var store: AkashicDerivedRasterStore? = try await AkashicDerivedRasterStore.open(
            root: root, limits: permissiveStoreLimits())
        try await store?.commit(container: fixture.container, record: fixture.record)
        store = nil
        await Task.yield()

        let manifest =
            root
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("derived-raster-records.json")
        try Data(#"{"schemaVersion":8,"records":{}}"#.utf8).write(to: manifest)
        do {
            _ = try await AkashicDerivedRasterStore.open(
                root: root, limits: permissiveStoreLimits())
            XCTFail("future record schema must fail closed")
        } catch let error as AkashicError {
            XCTAssertEqual(error, .invalidManifest)
        }
    }

    func testOldRecordSchemaIsDeletedInsteadOfMigrated_W11_PT_063() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(namespace: "account-a", generation: 1, label: "old-schema")
        var store: AkashicDerivedRasterStore? = try await AkashicDerivedRasterStore.open(
            root: root, limits: permissiveStoreLimits())
        try await store?.commit(container: fixture.container, record: fixture.record)
        let physicalBefore = await store?.physicalIDForTesting(fixture.record)
        XCTAssertNotNil(physicalBefore)
        store = nil
        await Task.yield()

        let manifest =
            root
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("derived-raster-records.json")
        let encoded = try Data(contentsOf: manifest)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["schemaVersion"] = 6
        try JSONSerialization.data(withJSONObject: object).write(to: manifest)

        let reopened = try await AkashicDerivedRasterStore.open(
            root: root, limits: permissiveStoreLimits())
        let records = await reopened.recordsForTesting()
        XCTAssertTrue(records.isEmpty)
        let physicalAfter = await reopened.physicalIDForTesting(fixture.record)
        XCTAssertNil(physicalAfter)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
    }

    func testCommitRejectsContainerRecordDigestMismatch_W11_PT_020() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(namespace: "account-a", generation: 1, label: "mismatch")
        let store = try await AkashicDerivedRasterStore.open(
            root: root, limits: permissiveStoreLimits())
        var tampered = fixture.container
        tampered[tampered.count - 1] ^= 0xFF
        do {
            try await store.commit(container: tampered, record: fixture.record)
            XCTFail("record content ID must bind the exact container bytes")
        } catch let error as AkashicError {
            XCTAssertEqual(error, .integrityMismatch)
        }
        let retainedRecords = await store.recordsForTesting()
        XCTAssertTrue(retainedRecords.isEmpty)
    }

    private struct Fixture {
        let pixels: Data
        let container: Data
        let record: DerivedRasterRecord
    }

    private func makeFixture(
        namespace: String,
        generation: UInt64,
        label: String,
        variantLabel: String = "shared-variant",
        pixelSalt: Int = 0,
        createdAt: TimeInterval = 1_000
    ) throws -> Fixture {
        let width = 31
        let height = 19
        var pixels = Data(count: width * height * 3)
        for pixel in 0..<(width * height) {
            let offset = pixel * 3
            pixels[offset] = UInt8(truncatingIfNeeded: pixel * 29 + pixelSalt * 17)
            pixels[offset + 1] = UInt8(truncatingIfNeeded: pixel * 37 + 5)
            pixels[offset + 2] = UInt8(truncatingIfNeeded: pixel * 43 + 11)
        }
        let container = try DerivedRasterContainer.encode(
            pixelData: pixels,
            width: width,
            height: height
        )
        let record = try makeRecord(
            container: container,
            pixels: pixels,
            namespace: namespace,
            generation: generation,
            label: label,
            variantLabel: variantLabel,
            createdAt: createdAt
        )
        return Fixture(pixels: pixels, container: container, record: record)
    }

    private func makeRecord(
        container: Data,
        pixels: Data,
        namespace: String,
        generation: UInt64,
        label: String,
        variantLabel: String,
        createdAt: TimeInterval = 1_000
    ) throws -> DerivedRasterRecord {
        let format = DerivedRasterContainer.formatIdentity
        return try DerivedRasterRecord(
            artifactKeyDigest: sha256(Data("artifact:\(label)".utf8)),
            baseKeyDigest: sha256(Data("base".utf8)),
            variantKeyDigest: sha256(Data("variant:\(variantLabel)".utf8)),
            namespaceFingerprint: StorageNamespaceFingerprint(namespace: namespace),
            namespaceGeneration: generation,
            containerContentID: BlobDigest.sha256(of: container).canonicalString,
            containerByteCount: container.count,
            formatIdentifier: format.identifier,
            formatSemanticVersion: format.semanticVersion,
            pixelLayoutFingerprint: format.pixelLayoutFingerprint,
            pixelDigestHex: sha256(pixels),
            pixelWidth: 31,
            pixelHeight: 19,
            createdAt: Date(timeIntervalSinceReferenceDate: createdAt)
        )
    }

    private func permissiveStoreLimits() -> DerivedRasterStoreLimits {
        DerivedRasterStoreLimits(
            softTotalBytes: 64 * 1024 * 1024,
            maximumBlobBytes: 16 * 1024 * 1024,
            maximumWriteBytesPerWindow: 1024 * 1024 * 1024,
            writeBudgetWindowNanoseconds: 60_000_000_000
        )
    }

    private func temporaryDirectory() throws -> URL {
        try makeTemporaryDirectory("derived-raster-\(UUID().uuidString.lowercased())")
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private actor ScriptedDerivedRasterPublicationPermission:
    DerivedRasterPublicationPermission
{
    private var values: [Bool]

    init(_ values: [Bool]) {
        self.values = values
    }

    func permitsPublication() -> Bool {
        values.isEmpty ? false : values.removeFirst()
    }
}
