import Foundation
import ImageCraftCore

package protocol MonotonicTimeSource: Sendable {
    func nowNanoseconds() -> UInt64
}

package struct SystemMonotonicTimeSource: MonotonicTimeSource {
    package init() {}
    package func nowNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

/// 识别同一展示类别中的连续取消，并决定共享 fetch 是否可进入有界交接。
///
/// 状态通过短临界区锁线性化。控制器不延迟前台请求、不合并内容身份，也不预测
/// SwiftUI 的下一次生命周期事件；它只在观察到至少两个同 cohort 取消后，为后续请求
/// 标记“取消时允许 fetch orphan-handoff”，并要求当前展示严格跨过同一 cohort 内
/// 最大已观测取消周期后才进入解码和发布。该门是经验不确定集上满足“不得早于任何
/// 已观测替换时刻”约束的最小等待；两个事件是识别周期所需的最小样本。
package final class AdaptiveImageLoadAdmission: @unchecked Sendable {
    package struct Ticket: Sendable {
        fileprivate let key: Key
        /// 线性化 begin 相对前序 cancellation 的顺序，区分并发 fan-out 与顺序替换。
        fileprivate let admissionSequence: UInt64
        package let preservesFetchOnCancellation: Bool
        /// 当前请求必须自身存活的严格稳定窗口；等于 cohort 最大已观测周期加一个纳秒。
        package let stabilizationNanoseconds: UInt64
    }

    package struct CancellationObservation: Sendable {
        /// 已经观察到至少一个同 cohort 的前序取消，可启动被取消身份的低优先级验证订阅。
        package let shouldWarmCancelledRequest: Bool
        /// 最近两个取消时间戳之间的周期；仅用于诊断与敏感性分析，不驱动前台延迟。
        package let observedPeriodNanoseconds: UInt64?
    }

    package struct Key: Hashable, Sendable {
        /// 取消交接只允许发生在调用方声明的同一逻辑来源内。
        /// 不同图片不能因展示几何相同而互相预热；同一来源可显式跨轮换 locator 交接。
        let logicalSource: LogicalSourceID
        let namespace: SecurityNamespaceID
        let authorizationContext: AuthorizationContextID
        let targetWidth: Int
        let targetHeight: Int
        let contentMode: ImageContentMode
        let geometryPolicyFingerprint: String
        let priority: ImageRequestPriority
        let networkPolicyFingerprint: String
    }

    private struct State: Sendable {
        var previousCancellationNanoseconds: UInt64?
        var latestCancellationNanoseconds: UInt64?
        var maximumObservedPeriodNanoseconds: UInt64?
        var latestCancellationSequence: UInt64?
        var lastTouchedNanoseconds: UInt64
    }

    private let lock = NSLock()
    private let maximumStateCount: Int
    private let timeSource: any MonotonicTimeSource
    private var states: [Key: State] = [:]
    private var eventSequence: UInt64 = 0

    package init(
        maximumStateCount: Int,
        timeSource: any MonotonicTimeSource = SystemMonotonicTimeSource()
    ) {
        self.maximumStateCount = max(1, maximumStateCount)
        self.timeSource = timeSource
    }

    package func begin(for request: ImageRequest) -> Ticket {
        atomic {
            let now = timeSource.nowNanoseconds()
            let key = Self.key(for: request)
            let admissionSequence = nextEventSequence()
            var state = normalized(states[key], now: now)
            let maximumPeriod = state.maximumObservedPeriodNanoseconds
            state.lastTouchedNanoseconds = now
            states[key] = state
            trimIfNeeded()
            return Ticket(
                key: key,
                admissionSequence: admissionSequence,
                preservesFetchOnCancellation: maximumPeriod != nil,
                stabilizationNanoseconds: maximumPeriod.map { $0 + 1 } ?? 0
            )
        }
    }

    package func finish(_ ticket: Ticket) {
        atomic {
            let now = timeSource.nowNanoseconds()
            var state = normalized(states[ticket.key], now: now)
            state.lastTouchedNanoseconds = now
            states[ticket.key] = state
            trimIfNeeded()
        }
    }

    @discardableResult
    package func recordCancellation(_ ticket: Ticket) -> CancellationObservation {
        atomic {
            let now = timeSource.nowNanoseconds()
            let cancellationSequence = nextEventSequence()
            var state = normalized(states[ticket.key], now: now)

            // 多个订阅者若在同一取消发生前已全部 admission，它们属于一个并发
            // fan-out，而不是 UI 先取消后替换的顺序 cohort。只有在最近一次取消之后
            // 才 begin 的 ticket，才可贡献新的周期或触发预热。
            if let latestCancellationSequence = state.latestCancellationSequence,
                ticket.admissionSequence < latestCancellationSequence
            {
                state.lastTouchedNanoseconds = now
                states[ticket.key] = state
                trimIfNeeded()
                return CancellationObservation(
                    shouldWarmCancelledRequest: false,
                    observedPeriodNanoseconds: nil
                )
            }

            let previousLatest = state.latestCancellationNanoseconds
            let isSameCohort =
                previousLatest.map {
                    now &- $0 <= CancellationCohortPolicy.retentionNanoseconds
                } ?? false
            state.previousCancellationNanoseconds = isSameCohort ? previousLatest : nil
            state.latestCancellationNanoseconds = now
            state.latestCancellationSequence = cancellationSequence
            let period = state.previousCancellationNanoseconds.map { now - $0 }
            if let period, period > 0,
                period <= CancellationCohortPolicy.retentionNanoseconds
            {
                state.maximumObservedPeriodNanoseconds = max(
                    state.maximumObservedPeriodNanoseconds ?? 0,
                    period
                )
            } else if !isSameCohort {
                state.maximumObservedPeriodNanoseconds = nil
            }
            state.lastTouchedNanoseconds = now
            states[ticket.key] = state
            trimIfNeeded()

            return CancellationObservation(
                shouldWarmCancelledRequest: period != nil,
                observedPeriodNanoseconds: period
            )
        }
    }

    package func trackedStateCount() -> Int { atomic { states.count } }

    @inline(__always)
    private func atomic<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func normalized(_ existing: State?, now: UInt64) -> State {
        guard var state = existing else {
            return State(lastTouchedNanoseconds: now)
        }
        if let latest = state.latestCancellationNanoseconds,
            now &- latest > CancellationCohortPolicy.retentionNanoseconds
        {
            state.previousCancellationNanoseconds = nil
            state.latestCancellationNanoseconds = nil
            state.maximumObservedPeriodNanoseconds = nil
            state.latestCancellationSequence = nil
        }
        return state
    }

    private static func key(for request: ImageRequest) -> Key {
        Key(
            logicalSource: request.logicalSource,
            namespace: request.namespace,
            authorizationContext: request.authorizationContext,
            targetWidth: request.target.width,
            targetHeight: request.target.height,
            contentMode: request.contentMode,
            geometryPolicyFingerprint: request.geometryPolicyFingerprint,
            priority: request.priority,
            networkPolicyFingerprint: request.networkPolicy.executionFingerprint
        )
    }

    private func nextEventSequence() -> UInt64 {
        let next = eventSequence.addingReportingOverflow(1)
        if next.overflow {
            // 实际不可达；若发生则清除依赖旧顺序的短期经验状态，避免 ABA。
            states.removeAll(keepingCapacity: true)
            eventSequence = 1
        } else {
            eventSequence = next.partialValue
        }
        return eventSequence
    }

    private func trimIfNeeded() {
        guard states.count > maximumStateCount else { return }
        let overflow = states.count - maximumStateCount
        let victims = states.sorted {
            $0.value.lastTouchedNanoseconds < $1.value.lastTouchedNanoseconds
        }.prefix(overflow)
        for victim in victims { states.removeValue(forKey: victim.key) }
    }
}
