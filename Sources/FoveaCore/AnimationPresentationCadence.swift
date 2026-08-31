/// Exact-boundary cadence candidate for animation presentation experiments.
///
/// The alignment quantum is the greatest duration that divides both one second and every normalized source
/// frame duration. Therefore an integer-FPS display cadence derived from it has an ideal sample boundary at
/// every source-frame transition. This is only a recommendation: platform refresh quantization and scheduling
/// still require physical-device timing and energy evidence before changing production defaults.
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

    /// Returns an integer preferred FPS only when it reduces callback frequency below the supplied platform
    /// maximum. Returning nil preserves the platform maximum-refresh behavior.
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
