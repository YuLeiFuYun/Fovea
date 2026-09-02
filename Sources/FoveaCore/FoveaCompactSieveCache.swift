import AkashicMemory
import Foundation

/// 为 Fovea transport handoff 提供连续值槽的短生命周期 SIEVE 索引。
///
/// 该实现属于 Fovea 宿主热路径，不依赖 Akashic 的 package-only CompactSieveCache。哈希表只保存
/// `Key -> slot index`，FIFO/SIEVE 链使用整数索引；删除槽由 free-list 复用，因此不会为
/// 每次插入创建独立节点对象。所有状态仍在一个短临界区内线性化。
package final class FoveaCompactSieveCache<Key: Hashable & Sendable, Value: Sendable>:
    @unchecked Sendable
{
    private struct Slot {
        var key: Key
        var value: Value
        var cost: Int
        var visitedEpoch: UInt64
        var previous: Int?
        var next: Int?
    }

    private let lock = NSLock()
    private let costLimit: Int
    private let countLimit: Int
    private var totalCost = 0
    private var residentCount = 0
    private var visitedCount = 0
    private var visitEpoch: UInt64 = 1
    private var indices: [Key: Int] = [:]
    private var slots: [Slot?] = []
    private var freeSlots: [Int] = []
    private var leastRecent: Int?
    private var mostRecent: Int?
    private var sieveHand: Int?

    package init(costLimit: Int, countLimit: Int = .max) {
        self.costLimit = max(1, costLimit)
        self.countLimit = max(1, countLimit)
    }

    package func value(for key: Key) -> Value? {
        atomic {
            guard let index = indices[key], var slot = slots[index] else { return nil }
            if slot.visitedEpoch != visitEpoch {
                slot.visitedEpoch = visitEpoch
                slots[index] = slot
                visitedCount += 1
            }
            return slot.value
        }
    }

    /// 只查询驻留身份，不提升 SIEVE 访问位。
    package func contains(_ key: Key) -> Bool {
        atomic {
            guard let index = indices[key] else { return false }
            return slots[index] != nil
        }
    }

    package func insert(_ value: Value, for key: Key, cost: Int) {
        _ = insertReportingEvictions(value, for: key, cost: cost)
    }

    /// 插入值并返回因容量约束被驱逐的键；同键更新不计作驱逐。
    package func insertReportingEvictions(
        _ value: Value,
        for key: Key,
        cost: Int
    ) -> [Key] {
        atomic {
            var evicted: [Key] = []
            let normalizedCost = max(1, cost)
            let reusableIndex = indices[key]
            if let reusableIndex { detachLocked(reusableIndex) }

            guard normalizedCost <= costLimit else {
                if let reusableIndex { releaseSlotLocked(reusableIndex) }
                return evicted
            }

            let maximumExistingCost = costLimit - normalizedCost
            while insertionRequiresEvictionLocked(maximumExistingCost: maximumExistingCost),
                let victim = nextSieveVictimLocked()
            {
                if let slot = slots[victim] { evicted.append(slot.key) }
                removeLocked(victim)
            }

            let index: Int
            if let reusableIndex {
                index = reusableIndex
                slots[index] = Slot(
                    key: key,
                    value: value,
                    cost: normalizedCost,
                    visitedEpoch: 0,
                    previous: mostRecent,
                    next: nil
                )
            } else if let recycled = freeSlots.popLast() {
                index = recycled
                slots[index] = Slot(
                    key: key,
                    value: value,
                    cost: normalizedCost,
                    visitedEpoch: 0,
                    previous: mostRecent,
                    next: nil
                )
                indices[key] = index
            } else {
                index = slots.count
                slots.append(
                    Slot(
                        key: key,
                        value: value,
                        cost: normalizedCost,
                        visitedEpoch: 0,
                        previous: mostRecent,
                        next: nil
                    )
                )
                indices[key] = index
            }

            if let previous = mostRecent, var previousSlot = slots[previous] {
                previousSlot.next = index
                slots[previous] = previousSlot
            }
            if leastRecent == nil { leastRecent = index }
            mostRecent = index
            residentCount += 1
            totalCost += normalizedCost
            return evicted
        }
    }

    package func remove(_ key: Key) {
        atomic {
            guard let index = indices[key] else { return }
            removeLocked(index)
        }
    }

    /// 使用同一 SIEVE victim policy 将驻留条目裁剪到请求总成本；返回实际驱逐的 key，并把请求上限夹到 cache 固定 cap。
    package func trimReportingEvictions(toCost requestedCost: Int) -> [Key] {
        atomic {
            let target = min(costLimit, max(0, requestedCost))
            var evicted: [Key] = []
            while totalCost > target, let victim = nextSieveVictimLocked() {
                if let slot = slots[victim] { evicted.append(slot.key) }
                removeLocked(victim)
            }
            return evicted
        }
    }

    package func removeAll(where predicate: @Sendable (Key) -> Bool) {
        _ = removeAllAndReport(where: predicate)
    }

    package func removeAllAndReport(
        where predicate: @Sendable (Key) -> Bool
    ) -> MemoryCacheRemovalSummary {
        atomic {
            let victims = indices.compactMap { predicate($0.key) ? $0.value : nil }
            var itemCount = 0
            var costBytes = 0
            for index in victims {
                guard let slot = slots[index] else { continue }
                itemCount += 1
                let next = costBytes.addingReportingOverflow(slot.cost)
                costBytes = next.overflow ? Int.max : next.partialValue
                removeLocked(index)
            }
            return MemoryCacheRemovalSummary(itemCount: itemCount, costBytes: costBytes)
        }
    }

    package func removeAllReportingKeys(
        where predicate: @Sendable (Key) -> Bool
    ) -> [Key] {
        atomic {
            let victims = indices.compactMap { predicate($0.key) ? ($0.key, $0.value) : nil }
            for (_, index) in victims where slots[index] != nil { removeLocked(index) }
            return victims.map(\.0)
        }
    }

    package func removeAll() {
        _ = removeAllAndReport()
    }

    package func removeAllAndReport() -> MemoryCacheRemovalSummary {
        removeAllAndReportKeys().summary
    }

    package func removeAllAndReportKeys() -> (
        summary: MemoryCacheRemovalSummary,
        keys: [Key]
    ) {
        atomic {
            let summary = MemoryCacheRemovalSummary(
                itemCount: indices.count,
                costBytes: totalCost
            )
            let keys = Array(indices.keys)
            indices.removeAll(keepingCapacity: false)
            slots.removeAll(keepingCapacity: false)
            freeSlots.removeAll(keepingCapacity: false)
            leastRecent = nil
            mostRecent = nil
            sieveHand = nil
            totalCost = 0
            residentCount = 0
            visitedCount = 0
            visitEpoch = 1
            return (summary, keys)
        }
    }

    package var currentCost: Int { atomic { totalCost } }
    package var count: Int { atomic { indices.count } }

    private func insertionRequiresEvictionLocked(maximumExistingCost: Int) -> Bool {
        totalCost > maximumExistingCost || residentCount >= countLimit
    }

    private func nextSieveVictimLocked() -> Int? {
        guard residentCount > 0, let leastRecent else { return nil }
        if sieveHand == nil { sieveHand = leastRecent }
        if visitedCount == residentCount { advanceVisitEpochLocked() }

        while let candidate = sieveHand, var slot = slots[candidate] {
            let next = slot.next ?? leastRecent
            if slot.visitedEpoch == visitEpoch {
                slot.visitedEpoch = 0
                slots[candidate] = slot
                visitedCount -= 1
                sieveHand = next
            } else {
                sieveHand = next == candidate ? nil : next
                return candidate
            }
        }
        return leastRecent
    }

    private func advanceVisitEpochLocked() {
        if visitEpoch == .max {
            var index = leastRecent
            while let current = index, var slot = slots[current] {
                slot.visitedEpoch = 0
                slots[current] = slot
                index = slot.next
            }
            visitEpoch = 1
        } else {
            visitEpoch += 1
        }
        visitedCount = 0
    }

    private func detachLocked(_ index: Int) {
        guard var slot = slots[index] else { return }
        if slot.visitedEpoch == visitEpoch { visitedCount -= 1 }
        residentCount -= 1

        if sieveHand == index {
            sieveHand = slot.next ?? (leastRecent == index ? nil : leastRecent)
        }
        if leastRecent == index { leastRecent = slot.next }
        if mostRecent == index { mostRecent = slot.previous }

        if let previous = slot.previous, var previousSlot = slots[previous] {
            previousSlot.next = slot.next
            slots[previous] = previousSlot
        }
        if let next = slot.next, var nextSlot = slots[next] {
            nextSlot.previous = slot.previous
            slots[next] = nextSlot
        }

        slot.previous = nil
        slot.next = nil
        slots[index] = slot
        totalCost -= slot.cost
        if leastRecent == nil {
            mostRecent = nil
            sieveHand = nil
            residentCount = 0
            visitedCount = 0
        }
    }

    private func removeLocked(_ index: Int) {
        detachLocked(index)
        releaseSlotLocked(index)
    }

    private func releaseSlotLocked(_ index: Int) {
        guard let slot = slots[index] else { return }
        indices.removeValue(forKey: slot.key)
        slots[index] = nil
        freeSlots.append(index)
    }

    @inline(__always)
    private func atomic<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
