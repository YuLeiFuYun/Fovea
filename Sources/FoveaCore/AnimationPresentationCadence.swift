/// 动画展示实验的精确边界 cadence 候选。
///
/// 对齐量子取同时整除一秒和所有归一化源帧时长的最大时长，因此由它导出的整数 FPS cadence 在每个源帧切换点都有理想采样边界。
/// 这只是建议值；修改生产默认值前，平台刷新量化与调度仍需真机时序和能耗证据。
package struct AnimationPresentationCadenceRecommendation: Equatable, Sendable {
    package let alignmentQuantumNanoseconds: UInt64

    package init?(frameDurationsNanoseconds: [UInt64]) {
        guard !frameDurationsNanoseconds.isEmpty,
            frameDurationsNanoseconds.allSatisfy({ $0 > 0 })
        else { return nil }

        var quantum: UInt64 = 1_000_000_000
        for duration in frameDurationsNanoseconds {
            quantum = Self.greatestCommonDivisor(quantum, duration)
            if quantum == 1 { break }
        }
        guard quantum > 0 else { return nil }
        alignmentQuantumNanoseconds = quantum
    }

    /// 只有整数 preferred FPS 能把回调频率降到给定平台上限以下时才返回它；返回 nil 表示保持平台最大刷新行为。
    package func preferredFramesPerSecond(maximumFramesPerSecond: Int) -> Int? {
        guard maximumFramesPerSecond > 1,
            1_000_000_000 % alignmentQuantumNanoseconds == 0
        else { return nil }
        let framesPerSecond = 1_000_000_000 / alignmentQuantumNanoseconds
        guard framesPerSecond > 0,
            framesPerSecond < UInt64(maximumFramesPerSecond),
            framesPerSecond <= UInt64(Int.max)
        else { return nil }
        return Int(framesPerSecond)
    }

    private static func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var a = lhs
        var b = rhs
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return a
    }
}
