import Foundation

/// Platform presenters use this pure predicate to avoid scheduling animation work that cannot be seen.
///
/// The platform layer remains responsible for deriving ancestor-hidden and visible-region state. Keeping
/// the predicate in Core gives UIKit, AppKit and tests one fail-closed contract without importing UI APIs.
package enum AnimationPresentationVisibility {
    package static func isEffectivelyVisible(
        windowAttached: Bool,
        superviewAttached: Bool,
        hidden: Bool,
        alpha: Double,
        intersectsVisibleRegion: Bool
    ) -> Bool {
        windowAttached
            && superviewAttached
            && !hidden
            && alpha.isFinite
            && alpha > 0
            && intersectsVisibleRegion
    }
}
