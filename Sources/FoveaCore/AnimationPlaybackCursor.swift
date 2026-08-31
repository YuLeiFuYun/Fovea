import Foundation

package enum AnimationPlaybackMode: String, Codable, Hashable, Sendable {
    case normal
    case playOnce
    case firstFrame
}

package enum AnimationPlaybackPauseReason: String, Codable, Hashable, Sendable {
    case explicit
    case offscreen
    case applicationBackground
    case memoryPressure
}

package enum AnimationPlaybackCursorError: Error, Equatable, Sendable {
    case notStarted
    case nonMonotonicClock
    case elapsedTimeOverflow
    case frameOrdinalOverflow
    case cancelled
}

package struct AnimationPlaybackDecision: Equatable, Sendable {
    package let frameIndex: Int
    package let loopIndex: UInt64
    package let droppedFrameCount: UInt64
    package let isFinished: Bool
    package let nanosecondsUntilNextFrame: UInt64?
    package let pauseReasons: Set<AnimationPlaybackPauseReason>
}

/// 纯确定性的动画播放游标。
///
/// 调用方提供单调纳秒时间；游标不创建 display link、timer 或 sleep。多个 pause reason 可以
/// 重叠，只有最后一个 reason 移除后时间才继续。采样跨越多帧时按时间轴直接前进并报告
/// dropped frames，禁止通过加速逐帧追赶。
package struct AnimationPlaybackCursor: Sendable {
    package let timeline: AnimationPlaybackTimeline
    package let mode: AnimationPlaybackMode

    private var accumulatedActiveNanoseconds: UInt64 = 0
    private var activeAnchorNanoseconds: UInt64?
    private var lastObservedNanoseconds: UInt64?
    private var lastAbsoluteFrameOrdinal: UInt64?
    private var pauseReasons: Set<AnimationPlaybackPauseReason> = []
    private var isCancelled = false

    package init(timeline: AnimationPlaybackTimeline, mode: AnimationPlaybackMode) {
        self.timeline = timeline
        self.mode = mode
    }

    package mutating func start(at monotonicNanoseconds: UInt64) {
        accumulatedActiveNanoseconds = 0
        activeAnchorNanoseconds = monotonicNanoseconds
        lastObservedNanoseconds = monotonicNanoseconds
        lastAbsoluteFrameOrdinal = nil
        pauseReasons.removeAll(keepingCapacity: true)
        isCancelled = false
    }

    package mutating func restart(at monotonicNanoseconds: UInt64) throws {
        try requireMonotonic(monotonicNanoseconds)
        accumulatedActiveNanoseconds = 0
        activeAnchorNanoseconds = monotonicNanoseconds
        lastAbsoluteFrameOrdinal = nil
        pauseReasons.removeAll(keepingCapacity: true)
        isCancelled = false
    }

    package mutating func setPaused(
        _ paused: Bool,
        reason: AnimationPlaybackPauseReason,
        at monotonicNanoseconds: UInt64
    ) throws {
        try requireUsableAndMonotonic(monotonicNanoseconds)
        if paused {
            guard !pauseReasons.contains(reason) else { return }
            if pauseReasons.isEmpty {
                accumulatedActiveNanoseconds = try activeElapsedNanoseconds(
                    at: monotonicNanoseconds)
                activeAnchorNanoseconds = nil
            }
            pauseReasons.insert(reason)
        } else {
            guard pauseReasons.remove(reason) != nil else { return }
            if pauseReasons.isEmpty { activeAnchorNanoseconds = monotonicNanoseconds }
        }
    }

    package mutating func seek(
        toFrame index: Int,
        at monotonicNanoseconds: UInt64
    ) throws {
        try requireUsableAndMonotonic(monotonicNanoseconds)
        accumulatedActiveNanoseconds = try timeline.frameStartOffsetNanoseconds(at: index)
        activeAnchorNanoseconds = pauseReasons.isEmpty ? monotonicNanoseconds : nil
        lastAbsoluteFrameOrdinal = nil
    }

    package mutating func cancel() {
        isCancelled = true
        activeAnchorNanoseconds = nil
    }

    /// Returns the monotonic host-time anchor that makes wall-clock animation elapsed time
    /// equal the cursor's active playback elapsed time. Paused wall time is therefore excluded.
    package func effectivePlaybackStartNanosecondsForPresentation(
        at monotonicNanoseconds: UInt64
    ) throws -> UInt64? {
        guard !isCancelled else { throw AnimationPlaybackCursorError.cancelled }
        guard activeAnchorNanoseconds != nil || !pauseReasons.isEmpty else {
            throw AnimationPlaybackCursorError.notStarted
        }
        let elapsed = try activeElapsedNanoseconds(at: monotonicNanoseconds)
        let anchor = monotonicNanoseconds.subtractingReportingOverflow(elapsed)
        return anchor.overflow ? nil : anchor.partialValue
    }

    package mutating func sample(
        at monotonicNanoseconds: UInt64
    ) throws -> AnimationPlaybackDecision {
        try requireUsableAndMonotonic(monotonicNanoseconds)

        if mode == .firstFrame {
            lastAbsoluteFrameOrdinal = 0
            return AnimationPlaybackDecision(
                frameIndex: 0,
                loopIndex: 0,
                droppedFrameCount: 0,
                isFinished: false,
                nanosecondsUntilNextFrame: nil,
                pauseReasons: pauseReasons
            )
        }

        let elapsed = try activeElapsedNanoseconds(at: monotonicNanoseconds)
        let finitePlayCount = effectiveFinitePlayCount
        if let finitePlayCount,
            let finiteDuration = multipliedOrNil(
                timeline.totalDurationNanoseconds,
                finitePlayCount
            ),
            elapsed >= finiteDuration
        {
            let loopIndex = finitePlayCount - 1
            let ordinal = try absoluteFrameOrdinal(
                loopIndex: loopIndex,
                frameIndex: timeline.frameCount - 1
            )
            let dropped = droppedFrames(before: ordinal)
            lastAbsoluteFrameOrdinal = ordinal
            return AnimationPlaybackDecision(
                frameIndex: timeline.frameCount - 1,
                loopIndex: loopIndex,
                droppedFrameCount: dropped,
                isFinished: true,
                nanosecondsUntilNextFrame: nil,
                pauseReasons: pauseReasons
            )
        }

        let loopIndex = elapsed / timeline.totalDurationNanoseconds
        let loopOffset = elapsed % timeline.totalDurationNanoseconds
        let frameIndex = timeline.frameIndex(atLoopOffsetNanoseconds: loopOffset)
        let ordinal = try absoluteFrameOrdinal(loopIndex: loopIndex, frameIndex: frameIndex)
        let dropped = droppedFrames(before: ordinal)
        lastAbsoluteFrameOrdinal = ordinal
        let frameEnd = try timeline.frameEndOffsetNanoseconds(at: frameIndex)
        return AnimationPlaybackDecision(
            frameIndex: frameIndex,
            loopIndex: loopIndex,
            droppedFrameCount: dropped,
            isFinished: false,
            nanosecondsUntilNextFrame: pauseReasons.isEmpty ? frameEnd - loopOffset : nil,
            pauseReasons: pauseReasons
        )
    }

    private var effectiveFinitePlayCount: UInt64? {
        switch mode {
        case .firstFrame:
            return nil
        case .playOnce:
            return 1
        case .normal:
            return timeline.additionalRepeatCount.map { UInt64($0) + 1 }
        }
    }

    private mutating func requireUsableAndMonotonic(_ value: UInt64) throws {
        guard !isCancelled else { throw AnimationPlaybackCursorError.cancelled }
        try requireMonotonic(value)
        guard activeAnchorNanoseconds != nil || !pauseReasons.isEmpty else {
            throw AnimationPlaybackCursorError.notStarted
        }
    }

    private mutating func requireMonotonic(_ value: UInt64) throws {
        if let lastObservedNanoseconds, value < lastObservedNanoseconds {
            throw AnimationPlaybackCursorError.nonMonotonicClock
        }
        lastObservedNanoseconds = value
    }

    private func activeElapsedNanoseconds(at now: UInt64) throws -> UInt64 {
        guard pauseReasons.isEmpty else { return accumulatedActiveNanoseconds }
        guard let activeAnchorNanoseconds else {
            throw AnimationPlaybackCursorError.notStarted
        }
        let delta = now - activeAnchorNanoseconds
        let total = accumulatedActiveNanoseconds.addingReportingOverflow(delta)
        guard !total.overflow else { throw AnimationPlaybackCursorError.elapsedTimeOverflow }
        return total.partialValue
    }

    private func absoluteFrameOrdinal(
        loopIndex: UInt64,
        frameIndex: Int
    ) throws -> UInt64 {
        let product = loopIndex.multipliedReportingOverflow(by: UInt64(timeline.frameCount))
        guard !product.overflow else { throw AnimationPlaybackCursorError.frameOrdinalOverflow }
        let sum = product.partialValue.addingReportingOverflow(UInt64(frameIndex))
        guard !sum.overflow else { throw AnimationPlaybackCursorError.frameOrdinalOverflow }
        return sum.partialValue
    }

    private func droppedFrames(before ordinal: UInt64) -> UInt64 {
        guard let lastAbsoluteFrameOrdinal, ordinal > lastAbsoluteFrameOrdinal else { return 0 }
        return ordinal - lastAbsoluteFrameOrdinal - 1
    }

    private func multipliedOrNil(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let value = lhs.multipliedReportingOverflow(by: rhs)
        return value.overflow ? nil : value.partialValue
    }
}
