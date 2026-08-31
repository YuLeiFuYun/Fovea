package struct AnimationPresentationTargetBufferSnapshot: Equatable, Sendable {
    package let acceptedTargetCount: UInt64
    package let consumedTargetCount: UInt64
    package let supersededPendingTargetCount: UInt64
    package let rejectedNonmonotonicTargetCount: UInt64
    package let lifecycleClearedPendingTargetCount: UInt64
    package let hasPending: Bool
    package let lastAcceptedTarget: UInt64?
}

/// 外部 presentation timestamp 的有界 newest-only 缓冲区。
///
/// 只接受严格递增的单调 target，最多保留一个 pending target；新刷新预测到达后绝不重放旧回调。
/// 清除 pending 工作时有意跨生命周期暂停保留单调高水位；计数器采用饱和语义，避免长时播放的诊断逻辑引入新的溢出故障。
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
