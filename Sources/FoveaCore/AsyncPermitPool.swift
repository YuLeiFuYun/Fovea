import Foundation

package enum PermitPoolError: Error, Sendable {
    case queueLimitExceeded
    case requestExceedsLimit
}

/// 支持优先级、防饥饿与带权容量的可取消异步许可池。
///
/// 未触发防饥饿时，同优先级请求按工作量估计从小到大准入。该顺序对应
/// 等权单机调度中的最短处理时间优先规则；在这里它只用于降低平均排队时间，
/// 不宣称对多许可、多资源或估计误差场景全局最优。等待者被普通调度绕过
/// 八次后进入饥饿集合；集合内部按原始到达顺序服务，非饥饿工作不得插队。
package actor AsyncPermitPool {
    package struct Permit: ~Copyable, Sendable {
        fileprivate let identifier: UUID
        fileprivate let pool: AsyncPermitPool

        /// 消耗许可令牌并释放对应容量；不可复制语义阻止同一许可被重复使用。
        package consuming func release() async {
            await pool.release(identifier)
        }

        /// 在持有许可期间执行操作，并在成功、失败或取消路径上恰好释放一次。
        /// 该方法消耗令牌，调用方无法复制许可后并发绕过容量上限。
        package consuming func withPermit<Result>(
            _ operation: () async throws -> Result
        ) async rethrows -> Result {
            let identifier = identifier
            let pool = pool
            defer { await pool.release(identifier) }
            return try await operation()
        }
    }

    private struct Waiter {
        let continuation: CheckedContinuation<Bool, Never>
        let units: Int
        var priority: ImageRequestPriority
        let workEstimate: Int
        var sequence: UInt64
        var bypassCount: Int
    }

    package static let maximumPriorityBypasses = 8

    private let capacity: Int
    private var available: Int
    private let queueLimit: Int
    private var granted: [UUID: Int] = [:]
    private var waiters: [UUID: Waiter] = [:]
    private var cancelledBeforeEnqueue: Set<UUID> = []
    private var nextSequence: UInt64 = 0
    private var reservedStarvedWaiter: UUID?

    package init(
        limit: Int,
        queueLimit: Int,
        initialSequence: UInt64 = 0
    ) {
        let capacity = max(1, limit)
        self.capacity = capacity
        self.available = capacity
        self.queueLimit = max(0, queueLimit)
        self.nextSequence = initialSequence
    }

    package func acquire(
        units: Int = 1,
        priority: ImageRequestPriority = .normal,
        workEstimate: Int? = nil,
        priorityUpdates: AsyncStream<ImageRequestPriority>? = nil
    ) async throws -> Permit {
        try Task.checkCancellation()
        let units = max(1, units)
        let workEstimate = max(1, workEstimate ?? units)
        guard units <= capacity else { throw PermitPoolError.requestExceedsLimit }

        let identifier = UUID()
        // 只有完全无排队义务时才能走立即获取快路径。已有等待者或容量保留时，
        // 新请求必须进入同一选择函数，否则持续到来的小请求可绕过 drain 模式。
        if waiters.isEmpty, reservedStarvedWaiter == nil, available >= units {
            available -= units
            granted[identifier] = units
            if Task.isCancelled {
                release(identifier)
                throw CancellationError()
            }
            return Permit(identifier: identifier, pool: self)
        }

        guard waiters.count < queueLimit else { throw PermitPoolError.queueLimitExceeded }
        let priorityObserver = priorityUpdates.map { updates in
            Task { @concurrent [weak self] in
                for await updatedPriority in updates {
                    await self?.updatePriority(identifier, to: updatedPriority)
                }
            }
        }
        defer { priorityObserver?.cancel() }

        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(
                    identifier,
                    units: units,
                    priority: priority,
                    workEstimate: workEstimate,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancel(identifier) }
        }

        guard acquired else { throw CancellationError() }
        if Task.isCancelled {
            release(identifier)
            throw CancellationError()
        }
        return Permit(identifier: identifier, pool: self)
    }

    package func queuedCount() -> Int { waiters.count }

    package func queuedPriorities() -> [ImageRequestPriority] {
        waiters.values.map(\.priority)
    }

    package var usedUnits: Int { capacity - available }

    private func enqueue(
        _ identifier: UUID,
        units: Int,
        priority: ImageRequestPriority,
        workEstimate: Int,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        if cancelledBeforeEnqueue.remove(identifier) != nil {
            continuation.resume(returning: false)
            return
        }
        waiters[identifier] = Waiter(
            continuation: continuation,
            units: units,
            priority: priority,
            workEstimate: workEstimate,
            sequence: nextSequenceValue(),
            bypassCount: 0
        )
        // 可用容量可能早已存在，只是之前的等待者装不下；新请求入队后立即重评估，
        // 避免必须等待一次无关 release 才能继续调度。
        grantFittingWaiters()
    }

    private func nextSequenceValue() -> UInt64 {
        if nextSequence == UInt64.max {
            let ordered = waiters.sorted { lhs, rhs in
                lhs.value.sequence < rhs.value.sequence
            }
            for (index, element) in ordered.enumerated() {
                var waiter = element.value
                waiter.sequence = UInt64(index + 1)
                waiters[element.key] = waiter
            }
            nextSequence = UInt64(ordered.count)
        }
        nextSequence += 1
        return nextSequence
    }

    private func updatePriority(_ identifier: UUID, to priority: ImageRequestPriority) {
        guard var waiter = waiters[identifier] else { return }
        waiter.priority = priority
        waiters[identifier] = waiter
    }

    private func cancel(_ identifier: UUID) {
        if let waiter = waiters.removeValue(forKey: identifier) {
            if reservedStarvedWaiter == identifier {
                reservedStarvedWaiter = nil
            }
            waiter.continuation.resume(returning: false)
            // 取消容量保留者后，现有空闲容量可能足以继续服务其他等待者。
            grantFittingWaiters()
            return
        }
        if granted[identifier] != nil {
            release(identifier)
            return
        }
        cancelledBeforeEnqueue.insert(identifier)
    }

    private func release(_ identifier: UUID) {
        guard let units = granted.removeValue(forKey: identifier) else { return }
        available = min(capacity, available + units)
        grantFittingWaiters()
    }

    private func grantFittingWaiters() {
        while let next = nextWaiterIdentifier(),
            let waiter = waiters.removeValue(forKey: next)
        {
            if reservedStarvedWaiter == next {
                reservedStarvedWaiter = nil
            }
            available -= waiter.units
            // 只有比本次获准请求更早到达、却被它插队的等待者才算真正被绕过。
            // 新到达请求不应仅因队列中有旧任务完成而同步老化；否则大队列会在八次
            // 授权后整体进入饥饿集合，使优先级调度退化为 FIFO。
            for (identifier, var other) in waiters where other.sequence < waiter.sequence {
                other.bypassCount = min(Self.maximumPriorityBypasses, other.bypassCount + 1)
                waiters[identifier] = other
            }
            granted[next] = waiter.units
            waiter.continuation.resume(returning: true)
        }
    }

    private func nextWaiterIdentifier() -> UUID? {
        // 一旦某个可容纳于总容量的请求达到绕过上限，就为它保留下一次足量容量。
        // 若它尚未装入当前空闲容量，调度器进入 drain 模式：不再把碎片容量发给
        // 新的小请求，而是等待在途许可释放。否则“八次绕过”只能限制被选择次数，
        // 无法限制带权请求在持续小流量下的实际等待时间。
        if let reservedStarvedWaiter {
            guard let waiter = waiters[reservedStarvedWaiter] else {
                self.reservedStarvedWaiter = nil
                return nextWaiterIdentifier()
            }
            return waiter.units <= available ? reservedStarvedWaiter : nil
        }

        if let starved = oldestStarvedWaiterIdentifier() {
            reservedStarvedWaiter = starved
            guard let waiter = waiters[starved] else { return nil }
            return waiter.units <= available ? starved : nil
        }

        let fitting = waiters.filter { $0.value.units <= available }
        guard !fitting.isEmpty else { return nil }
        return fitting.max { lhs, rhs in
            if lhs.value.priority != rhs.value.priority {
                return lhs.value.priority < rhs.value.priority
            }
            if lhs.value.workEstimate != rhs.value.workEstimate {
                return lhs.value.workEstimate > rhs.value.workEstimate
            }
            return lhs.value.sequence > rhs.value.sequence
        }?.key
    }

    private func oldestStarvedWaiterIdentifier() -> UUID? {
        waiters
            .filter { $0.value.bypassCount >= Self.maximumPriorityBypasses }
            .min { lhs, rhs in lhs.value.sequence < rhs.value.sequence }?
            .key
    }
}
