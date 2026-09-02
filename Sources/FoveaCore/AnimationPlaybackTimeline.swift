import Foundation

package enum AnimationPlaybackTimelineError: Error, Equatable, Sendable {
    case emptyTimeline
    case invalidZeroDurationReplacement
    case durationOverflow
    case frameIndexOutOfRange
}

/// 把已验证容器时长转换为单调播放使用的纳秒时间轴。
///
/// 非零时长保持原值；只有零时长使用显式、版本化的替代值。累计结束偏移严格递增，
/// 因此 frame lookup 可以使用二分搜索，不需要在每个 display tick 线性扫描全部帧。
package struct AnimationPlaybackTimeline: Equatable, Sendable {
    package let frameDurationsNanoseconds: [UInt64]
    package let frameEndOffsetsNanoseconds: [UInt64]
    package let totalDurationNanoseconds: UInt64
    package let additionalRepeatCount: UInt32?
    package let timingPolicyVersion: UInt16

    package init(
        frameDurationsNanoseconds: [UInt64],
        additionalRepeatCount: UInt32?,
        zeroDurationReplacementNanoseconds: UInt64,
        timingPolicyVersion: UInt16
    ) throws {
        guard !frameDurationsNanoseconds.isEmpty else {
            throw AnimationPlaybackTimelineError.emptyTimeline
        }
        guard zeroDurationReplacementNanoseconds > 0 else {
            throw AnimationPlaybackTimelineError.invalidZeroDurationReplacement
        }

        var normalized: [UInt64] = []
        var ends: [UInt64] = []
        normalized.reserveCapacity(frameDurationsNanoseconds.count)
        ends.reserveCapacity(frameDurationsNanoseconds.count)
        var cumulative: UInt64 = 0
        for duration in frameDurationsNanoseconds {
            let value = duration == 0 ? zeroDurationReplacementNanoseconds : duration
            let next = cumulative.addingReportingOverflow(value)
            guard !next.overflow else { throw AnimationPlaybackTimelineError.durationOverflow }
            cumulative = next.partialValue
            normalized.append(value)
            ends.append(cumulative)
        }

        self.frameDurationsNanoseconds = normalized
        self.frameEndOffsetsNanoseconds = ends
        self.totalDurationNanoseconds = cumulative
        self.additionalRepeatCount = additionalRepeatCount
        self.timingPolicyVersion = timingPolicyVersion
    }

    package var frameCount: Int { frameDurationsNanoseconds.count }

    package func frameStartOffsetNanoseconds(at index: Int) throws -> UInt64 {
        guard frameDurationsNanoseconds.indices.contains(index) else {
            throw AnimationPlaybackTimelineError.frameIndexOutOfRange
        }
        return index == 0 ? 0 : frameEndOffsetsNanoseconds[index - 1]
    }

    package func frameEndOffsetNanoseconds(at index: Int) throws -> UInt64 {
        guard frameEndOffsetsNanoseconds.indices.contains(index) else {
            throw AnimationPlaybackTimelineError.frameIndexOutOfRange
        }
        return frameEndOffsetsNanoseconds[index]
    }

    package func frameIndex(atLoopOffsetNanoseconds offset: UInt64) -> Int {
        precondition(offset < totalDurationNanoseconds)
        var lower = 0
        var upper = frameEndOffsetsNanoseconds.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if offset < frameEndOffsetsNanoseconds[middle] {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }
}
