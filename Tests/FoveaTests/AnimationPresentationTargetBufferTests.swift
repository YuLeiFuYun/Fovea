import FoveaCore
import XCTest

final class AnimationPresentationTargetBufferTests: XCTestCase {
    func testNewestOnlyBufferIsBoundedAndRejectsNonmonotonicTargets_W5_PT_131() {
        var buffer = AnimationPresentationTargetBuffer()

        XCTAssertTrue(buffer.offer(10))
        XCTAssertTrue(buffer.offer(20))
        XCTAssertEqual(buffer.takeNewest(), 20)
        XCTAssertNil(buffer.takeNewest())

        XCTAssertFalse(buffer.offer(20))
        XCTAssertFalse(buffer.offer(19))
        XCTAssertTrue(buffer.offer(30))
        buffer.clearPending()
        XCTAssertFalse(buffer.hasPending)
        XCTAssertEqual(buffer.lastAcceptedForTesting, 30)

        XCTAssertFalse(buffer.offer(29))
        XCTAssertTrue(buffer.offer(31))
        XCTAssertEqual(buffer.takeNewest(), 31)

        let snapshot = buffer.snapshot
        XCTAssertEqual(snapshot.acceptedTargetCount, 4)
        XCTAssertEqual(snapshot.consumedTargetCount, 2)
        XCTAssertEqual(snapshot.supersededPendingTargetCount, 1)
        XCTAssertEqual(snapshot.rejectedNonmonotonicTargetCount, 3)
        XCTAssertEqual(snapshot.lifecycleClearedPendingTargetCount, 1)
        XCTAssertFalse(snapshot.hasPending)
        XCTAssertEqual(snapshot.lastAcceptedTarget, 31)
    }
    func testBufferDiagnosticsSeparateSupersessionFromLifecycleClear_W5_PT_137() {
        var buffer = AnimationPresentationTargetBuffer()

        XCTAssertTrue(buffer.offer(100))
        XCTAssertTrue(buffer.offer(110))
        buffer.clearPending()
        XCTAssertTrue(buffer.offer(120))
        XCTAssertEqual(buffer.takeNewest(), 120)
        XCTAssertFalse(buffer.offer(120))

        let snapshot = buffer.snapshot
        XCTAssertEqual(snapshot.acceptedTargetCount, 3)
        XCTAssertEqual(snapshot.consumedTargetCount, 1)
        XCTAssertEqual(snapshot.supersededPendingTargetCount, 1)
        XCTAssertEqual(snapshot.lifecycleClearedPendingTargetCount, 1)
        XCTAssertEqual(snapshot.rejectedNonmonotonicTargetCount, 1)
        XCTAssertFalse(snapshot.hasPending)
        XCTAssertEqual(snapshot.lastAcceptedTarget, 120)
    }

}
