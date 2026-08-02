import Foundation

/// 根据端到端加载延迟的经验分布和内容消费速度估计有界预取窗口。
///
/// 规划器只保留最近一段有限历史，以便网络状态变化后旧样本可以退出。对于固定的
/// i.i.d. 样本，DKW–Massart 不等式给出经验分布与真实分布之间的一致置信带；这里
/// 用该带宽把目标分位数向尾部移动，再转换成“消费速度 × 延迟”的预取数量。
///
/// 真实请求通常相关且网络并非平稳，滚动窗口也不是预先固定的独立样本，因此界只
/// 是可审计的风险调节规则，而不是生产漏载概率承诺。样本不足时使用显式回退值，
/// 最终结果始终受静态下限和上限约束。
struct WorkbenchPrefetchPlanner: Sendable {
    private static let maximumSampleCount = 128
    private var latencySamplesSeconds: [Double] = []

    var sampleCount: Int { latencySamplesSeconds.count }

    var meanLatencySeconds: Double {
        guard !latencySamplesSeconds.isEmpty else { return 0 }
        return latencySamplesSeconds.reduce(0, +) / Double(latencySamplesSeconds.count)
    }

    var maximumObservedLatencySeconds: Double {
        latencySamplesSeconds.max() ?? 0
    }

    var sampleVarianceSecondsSquared: Double {
        guard latencySamplesSeconds.count > 1 else { return 0 }
        let mean = meanLatencySeconds
        let squaredDeviations = latencySamplesSeconds.reduce(0) { partial, sample in
            let delta = sample - mean
            return partial + delta * delta
        }
        return squaredDeviations / Double(latencySamplesSeconds.count - 1)
    }

    mutating func record(durationNanoseconds: UInt64) {
        let seconds = min(60, Double(durationNanoseconds) / 1_000_000_000)
        guard seconds.isFinite, seconds >= 0 else { return }

        latencySamplesSeconds.append(seconds)
        if latencySamplesSeconds.count > Self.maximumSampleCount {
            latencySamplesSeconds.removeFirst(
                latencySamplesSeconds.count - Self.maximumSampleCount
            )
        }
    }

    func recommendedItemCount(
        estimatedConsumptionRate: Double,
        targetMissProbability: Double = 0.10,
        confidenceLevel: Double = 0.90,
        minimum: Int = 8,
        maximum: Int = 64,
        fallbackLatencySeconds: Double = 0.75
    ) -> Int {
        let lower = max(0, minimum)
        let upper = max(lower, maximum)
        let rate = estimatedConsumptionRate.isFinite ? max(0, estimatedConsumptionRate) : 0
        let missProbability =
            targetMissProbability.isFinite
            ? min(0.49, max(0.01, targetMissProbability)) : 0.10
        let confidence =
            confidenceLevel.isFinite
            ? min(0.999, max(0.50, confidenceLevel)) : 0.90
        let fallback =
            fallbackLatencySeconds.isFinite
            ? min(10, max(0, fallbackLatencySeconds)) : 0.75

        let conservativeLatency: Double
        if latencySamplesSeconds.count < 2 {
            conservativeLatency = min(10, max(fallback, maximumObservedLatencySeconds))
        } else {
            let margin = distributionConfidenceMargin(confidenceLevel: confidence)
            let adjustedQuantile = min(1, 1 - missProbability + margin)
            conservativeLatency = min(
                10,
                max(fallback, empiricalQuantile(adjustedQuantile))
            )
        }

        let predicted = Int(ceil(rate * conservativeLatency))
        // 额外两个条目吸收 Cell 创建和主线程发布抖动，但仍受硬上限约束。
        return min(upper, max(lower, predicted + 2))
    }

    /// 返回双侧 DKW–Massart 置信带半宽 `sqrt(log(2/α) / (2n))`。
    /// 当样本来自相关或变化中的分布时，该值只能作为保守度旋钮使用。
    func distributionConfidenceMargin(confidenceLevel: Double = 0.90) -> Double {
        guard !latencySamplesSeconds.isEmpty else { return 1 }
        let confidence = min(0.999, max(0.50, confidenceLevel))
        let alpha = 1 - confidence
        return sqrt(log(2 / alpha) / (2 * Double(latencySamplesSeconds.count)))
    }

    mutating func reset() {
        latencySamplesSeconds.removeAll(keepingCapacity: true)
    }

    private func empiricalQuantile(_ probability: Double) -> Double {
        guard !latencySamplesSeconds.isEmpty else { return 0 }
        let ordered = latencySamplesSeconds.sorted()
        let boundedProbability = min(1, max(0, probability))
        let rank = max(0, Int(ceil(boundedProbability * Double(ordered.count))) - 1)
        return ordered[min(rank, ordered.count - 1)]
    }
}
