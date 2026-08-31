import Foundation

package enum AnimationMemoryPressureLevel: String, Codable, Hashable, Sendable {
    case normal
    case warning
    case critical
}

package enum AnimationFrameWindowPlannerError: Error, Equatable, Sendable {
    case invalidFrameCount
    case frameIndexOutOfRange
}

package struct AnimationFrameWindowPolicy: Equatable, Sendable {
    package let normalFrameCount: Int
    package let warningFrameCount: Int
    package let criticalFrameCount: Int

    package init(
        normalFrameCount: Int,
        warningFrameCount: Int,
        criticalFrameCount: Int = 1
    ) {
        let normal = min(64, max(1, normalFrameCount))
        let warning = min(normal, max(1, warningFrameCount))
        self.normalFrameCount = normal
        self.warningFrameCount = warning
        self.criticalFrameCount = min(warning, max(1, criticalFrameCount))
    }

    package func frameCount(for pressure: AnimationMemoryPressureLevel) -> Int {
        switch pressure {
        case .normal: normalFrameCount
        case .warning: warningFrameCount
        case .critical: criticalFrameCount
        }
    }
}

package struct AnimationFrameDecodePlan: Equatable, Sendable {
    package let ranges: [Range<Int>]

    package init(ranges: [Range<Int>]) {
        self.ranges = ranges
    }

    package var frameCount: Int { ranges.reduce(0) { $0 + $1.count } }
}

/// 为连续 provider 生成有界窗口；跨 loop 最多拆成两个 range，且不重复任何帧。
package enum AnimationFrameWindowPlanner {
    package static func plan(
        startingAt frameIndex: Int,
        frameCount: Int,
        maximumWindowSize: Int
    ) throws -> AnimationFrameDecodePlan {
        guard frameCount > 0 else {
            throw AnimationFrameWindowPlannerError.invalidFrameCount
        }
        guard (0..<frameCount).contains(frameIndex) else {
            throw AnimationFrameWindowPlannerError.frameIndexOutOfRange
        }
        let window = min(frameCount, max(1, maximumWindowSize))
        let firstCount = min(window, frameCount - frameIndex)
        let firstUpperBound = frameIndex + firstCount
        var ranges = [frameIndex..<firstUpperBound]
        let remaining = window - firstCount
        if remaining > 0 { ranges.append(0..<remaining) }
        return AnimationFrameDecodePlan(ranges: ranges)
    }

    package static func missingRanges(
        from plan: AnimationFrameDecodePlan,
        contains: (Int) -> Bool
    ) -> AnimationFrameDecodePlan {
        var ranges: [Range<Int>] = []
        for sourceRange in plan.ranges {
            var runStart: Int?
            for index in sourceRange {
                if contains(index) {
                    if let start = runStart {
                        ranges.append(start..<index)
                        runStart = nil
                    }
                } else if runStart == nil {
                    runStart = index
                }
            }
            if let runStart { ranges.append(runStart..<sourceRange.upperBound) }
        }
        return AnimationFrameDecodePlan(ranges: ranges)
    }
}
