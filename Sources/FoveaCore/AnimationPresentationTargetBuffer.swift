package struct AnimationPresentationTargetBufferSnapshot: Equatable, Sendable {
    package let acceptedTargetCount: UInt64
    package let consumedTargetCount: UInt64
    package let supersededPendingTargetCount: UInt64
    package let rejectedNonmonotonicTargetCount: UInt64
    package let lifecycleClearedPendingTargetCount: UInt64
    package let hasPending: Bool
    package let lastAcceptedTarget: UInt64?
}

/// Bounded newest-only buffer for externally supplied presentation timestamps.
///
/// The buffer accepts strictly increasing monotonic targets, retains at most one pending target, and never
/// replays an older callback after a newer refresh prediction arrives. Clearing pending work intentionally
/// preserves the monotonic high-water mark across lifecycle pauses. Counters are saturating so diagnostics
/// cannot introduce a new overflow failure mode during long-lived playback.
package struct AnimationPresentationTargetBuffer: Sendable {
    private var lastAcceptedTarget: UInt64?
    private var pendingTarget: UInt64?
    private var acceptedTargetCount: UInt64 = 0
    private var consumedTargetCount: UInt64 = 0
    private var supersededPendingTargetCount: UInt64 = 0
    private var rejectedNonmonotonicTargetCount: UInt64 = 0
    private var lifecycleClearedPendingTargetCount: UInt64 = 0

    package init() {}

    @discardableResult
    package mutating func offer(_ target: UInt64) -> Bool {
        if let lastAcceptedTarget, target <= lastAcceptedTarget {
            increment(&rejectedNonmonotonicTargetCount)
            return false
        }
        increment(&acceptedTargetCount)
        if pendingTarget != nil { increment(&supersededPendingTargetCount) }
        lastAcceptedTarget = target
        pendingTarget = target
        return true
    }

    package mutating func takeNewest() -> UInt64? {
        defer { pendingTarget = nil }
        guard let pendingTarget else { return nil }
        increment(&consumedTargetCount)
        return pendingTarget
    }

    package mutating func clearPending() {
        if pendingTarget != nil { increment(&lifecycleClearedPendingTargetCount) }
        pendingTarget = nil
    }

    package var hasPending: Bool {
        pendingTarget != nil
    }

    package var lastAcceptedForTesting: UInt64? {
        lastAcceptedTarget
    }

    package var snapshot: AnimationPresentationTargetBufferSnapshot {
        AnimationPresentationTargetBufferSnapshot(
            acceptedTargetCount: acceptedTargetCount,
            consumedTargetCount: consumedTargetCount,
            supersededPendingTargetCount: supersededPendingTargetCount,
            rejectedNonmonotonicTargetCount: rejectedNonmonotonicTargetCount,
            lifecycleClearedPendingTargetCount: lifecycleClearedPendingTargetCount,
            hasPending: pendingTarget != nil,
            lastAcceptedTarget: lastAcceptedTarget
        )
    }

    private func increment(_ value: inout UInt64) {
        if value < .max { value += 1 }
    }
}
