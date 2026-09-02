import FoveaCore
import XCTest

final class AnimationPresentationVisibilityTests: XCTestCase {
    func testEffectiveVisibilityRequiresEveryPresentationGate_W5_PT_125() {
        XCTAssertTrue(
            AnimationPresentationVisibility.isEffectivelyVisible(
                windowAttached: true,
                superviewAttached: true,
                hidden: false,
                alpha: 1,
                intersectsVisibleRegion: true
            )
        )
        let rejected: [(Bool, Bool, Bool, Double, Bool)] = [
            (false, true, false, 1, true),
            (true, false, false, 1, true),
            (true, true, true, 1, true),
            (true, true, false, 0, true),
            (true, true, false, -.infinity, true),
            (true, true, false, .nan, true),
            (true, true, false, 1, false),
        ]
        for value in rejected {
            XCTAssertFalse(
                AnimationPresentationVisibility.isEffectivelyVisible(
                    windowAttached: value.0,
                    superviewAttached: value.1,
                    hidden: value.2,
                    alpha: value.3,
                    intersectsVisibleRegion: value.4
                )
            )
        }
    }
}
