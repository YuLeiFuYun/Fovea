import FoveaCore
import XCTest

final class T100AnimationPlaybackPolicyAdoptionTests: XCTestCase {
    func testReduceMotionTruthTableNeverBroadensRequestedMode_ANIM_POLICY_PT_001() {
        XCTAssertEqual(
            AnimationPlaybackPolicy(
                requestedMode: .normal,
                reduceMotionBehavior: .firstFrame
            ).resolvedMode(reduceMotionEnabled: true),
            .firstFrame
        )
        XCTAssertEqual(
            AnimationPlaybackPolicy(
                requestedMode: .normal,
                reduceMotionBehavior: .playOnce
            ).resolvedMode(reduceMotionEnabled: true),
            .playOnce
        )
        XCTAssertEqual(
            AnimationPlaybackPolicy(
                requestedMode: .firstFrame,
                reduceMotionBehavior: .playOnce
            ).resolvedMode(reduceMotionEnabled: true),
            .firstFrame
        )
        XCTAssertEqual(
            AnimationPlaybackPolicy(
                requestedMode: .playOnce,
                reduceMotionBehavior: .preserveRequestedMode
            ).resolvedMode(reduceMotionEnabled: true),
            .playOnce
        )
        XCTAssertEqual(
            AnimationPlaybackPolicy(requestedMode: .normal)
                .resolvedMode(reduceMotionEnabled: false),
            .normal
        )
    }

    func testReduceMotionResolutionIsIdempotentAcrossAllModes_ANIM_POLICY_PT_002() {
        let modes: [AnimationPlaybackMode] = [.normal, .playOnce, .firstFrame]
        let behaviors: [AnimationReduceMotionBehavior] = [
            .preserveRequestedMode, .playOnce, .firstFrame,
        ]
        for requested in modes {
            for behavior in behaviors {
                let policy = AnimationPlaybackPolicy(
                    requestedMode: requested,
                    reduceMotionBehavior: behavior
                )
                let first = policy.resolvedMode(reduceMotionEnabled: true)
                let second = AnimationPlaybackPolicy(
                    requestedMode: first,
                    reduceMotionBehavior: behavior
                ).resolvedMode(reduceMotionEnabled: true)
                XCTAssertEqual(second, first)
            }
        }
    }
}
