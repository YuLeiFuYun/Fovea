import FoveaStorage
import XCTest

@testable import FoveaCore

final class DerivedRasterReuseObservationTrackerTests: XCTestCase {
    func testObservedReuseThresholdSuppressesPrematureRecompression_W11_PT_049() async {
        let tracker = DerivedRasterReuseObservationTracker()
        let namespace = StorageNamespaceFingerprint(namespace: "reuse-threshold")

        let first = await tracker.observe(
            keyDigest: "artifact-a",
            namespaceFingerprint: namespace
        )
        XCTAssertEqual(first.hitCount, 1)
        XCTAssertTrue(first.shouldAttemptCreation)

        await tracker.recordRejection(
            .insufficientObservedReuse(required: 5, observed: 1),
            keyDigest: "artifact-a"
        )
        for expectedHitCount in 2...4 {
            let observation = await tracker.observe(
                keyDigest: "artifact-a",
                namespaceFingerprint: namespace
            )
            XCTAssertEqual(observation.hitCount, expectedHitCount)
            XCTAssertFalse(observation.shouldAttemptCreation)
        }

        let fifth = await tracker.observe(
            keyDigest: "artifact-a",
            namespaceFingerprint: namespace
        )
        XCTAssertEqual(fifth.hitCount, 5)
        XCTAssertTrue(fifth.shouldAttemptCreation)
    }

    func testTransientCostRejectionUsesExponentialRetryBackoff_W11_PT_050() async {
        let tracker = DerivedRasterReuseObservationTracker()
        let namespace = StorageNamespaceFingerprint(namespace: "reuse-backoff")

        for _ in 0..<5 {
            _ = await tracker.observe(
                keyDigest: "artifact-b",
                namespaceFingerprint: namespace
            )
        }
        await tracker.recordRejection(.noReadSavings, keyDigest: "artifact-b")

        for expectedHitCount in 6...9 {
            let observation = await tracker.observe(
                keyDigest: "artifact-b",
                namespaceFingerprint: namespace
            )
            XCTAssertEqual(observation.hitCount, expectedHitCount)
            XCTAssertFalse(observation.shouldAttemptCreation)
        }
        let tenth = await tracker.observe(
            keyDigest: "artifact-b",
            namespaceFingerprint: namespace
        )
        XCTAssertEqual(tenth.hitCount, 10)
        XCTAssertTrue(tenth.shouldAttemptCreation)
    }

    func testHardRejectionStopsExactIdentityUntilStateIsDiscarded_W11_PT_051() async {
        let tracker = DerivedRasterReuseObservationTracker()
        let namespace = StorageNamespaceFingerprint(namespace: "reuse-hard-reject")

        _ = await tracker.observe(
            keyDigest: "artifact-c",
            namespaceFingerprint: namespace
        )
        await tracker.recordRejection(
            .byteBudgetExceeded(actual: 2_048, maximum: 1_024),
            keyDigest: "artifact-c"
        )
        for _ in 0..<4 {
            let observation = await tracker.observe(
                keyDigest: "artifact-c",
                namespaceFingerprint: namespace
            )
            XCTAssertFalse(observation.shouldAttemptCreation)
        }

        await tracker.markPublished(keyDigest: "artifact-c")
        let reset = await tracker.observe(
            keyDigest: "artifact-c",
            namespaceFingerprint: namespace
        )
        XCTAssertEqual(reset.hitCount, 1)
        XCTAssertTrue(reset.shouldAttemptCreation)
    }

    func testNamespaceRemovalDoesNotEraseOtherObservationCohorts_W11_PT_052() async {
        let tracker = DerivedRasterReuseObservationTracker()
        let namespaceA = StorageNamespaceFingerprint(namespace: "reuse-a")
        let namespaceB = StorageNamespaceFingerprint(namespace: "reuse-b")

        _ = await tracker.observe(keyDigest: "artifact-a", namespaceFingerprint: namespaceA)
        _ = await tracker.observe(keyDigest: "artifact-b", namespaceFingerprint: namespaceB)
        await tracker.recordRejection(
            .insufficientObservedReuse(required: 3, observed: 1),
            keyDigest: "artifact-a"
        )
        await tracker.recordRejection(
            .insufficientObservedReuse(required: 3, observed: 1),
            keyDigest: "artifact-b"
        )

        await tracker.removeAll(namespaceFingerprint: namespaceA)

        let resetA = await tracker.observe(
            keyDigest: "artifact-a",
            namespaceFingerprint: namespaceA
        )
        let retainedB = await tracker.observe(
            keyDigest: "artifact-b",
            namespaceFingerprint: namespaceB
        )
        XCTAssertEqual(resetA, .init(hitCount: 1, shouldAttemptCreation: true))
        XCTAssertEqual(retainedB, .init(hitCount: 2, shouldAttemptCreation: false))
        let trackedCount = await tracker.trackedEntryCountForTesting()
        XCTAssertEqual(trackedCount, 2)
    }
}
