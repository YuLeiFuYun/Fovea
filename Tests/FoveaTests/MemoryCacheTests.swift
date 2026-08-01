import AkashicMemory
import XCTest
@testable import FoveaCore

final class MemoryCacheTests: XCTestCase {
    func testSIEVEHitProtectsEntryForOneEvictionCycle_MATH_PT_007() async {
        let cache = MemoryCache<String, String>(costLimit: 8)
        cache.insert("first", for: "a", cost: 4)
        cache.insert("second", for: "b", cost: 4)
        let promoted = cache.value(for: "a")
        XCTAssertEqual(promoted, "first")
        cache.insert("third", for: "c", cost: 4)

        let a = cache.value(for: "a")
        let b = cache.value(for: "b")
        let c = cache.value(for: "c")
        XCTAssertEqual(a, "first")
        XCTAssertNil(b)
        XCTAssertEqual(c, "third")
        let count = cache.count
        XCTAssertEqual(count, 2)
    }

    func testOversizedValueDoesNotRemainResident() async {
        let cache = MemoryCache<Int, String>(costLimit: 4)
        cache.insert("oversized", for: 1, cost: 8)
        let value = cache.value(for: 1)
        let count = cache.count
        XCTAssertNil(value)
        XCTAssertEqual(count, 0)
    }
    func testSIEVEProtectsVisitedHotSetFromSequentialScan_MATH_PT_007() async {
        let cache = MemoryCache<String, String>(costLimit: 3)
        for key in ["hot-a", "hot-b", "cold"] {
            cache.insert(key, for: key, cost: 1)
        }
        for index in 0..<16 {
            // 热点在扫描间持续被访问；SIEVE 命中只重置访问位，不移动对象。
            _ = cache.value(for: "hot-a")
            _ = cache.value(for: "hot-b")
            let key = "scan-\(index)"
            cache.insert(key, for: key, cost: 1)
        }

        let hotA = cache.value(for: "hot-a")
        let hotB = cache.value(for: "hot-b")
        let count = cache.count
        let cost = cache.currentCost
        XCTAssertEqual(hotA, "hot-a")
        XCTAssertEqual(hotB, "hot-b")
        XCTAssertEqual(count, 3)
        XCTAssertEqual(cost, 3)
    }

    func testAllVisitedEpochResetPreservesClassicSIEVEVictim_MATH_PT_007() async {
        let cache = MemoryCache<String, String>(costLimit: 3)
        for key in ["a", "b", "c"] {
            cache.insert(key, for: key, cost: 1)
            XCTAssertEqual(cache.value(for: key), key)
        }

        cache.insert("d", for: "d", cost: 1)

        XCTAssertNil(cache.value(for: "a"))
        XCTAssertEqual(cache.value(for: "b"), "b")
        XCTAssertEqual(cache.value(for: "c"), "c")
        XCTAssertEqual(cache.value(for: "d"), "d")
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache.currentCost, 3)
    }

    func testSeededSIEVEMatchesIndependentClockModel_MATH_PT_008() async {
        let costLimit = 17
        for seed in 1...32 {
            let cache = MemoryCache<Int, String>(costLimit: costLimit)
            var model = ReferenceSIEVE<Int, String>(costLimit: costLimit)
            var generator = DeterministicGenerator(seed: UInt64(seed))

            for step in 0..<800 {
                let key = generator.nextInt(upperBound: 23)
                let action = generator.nextInt(upperBound: 100)
                if action < 48 {
                    let cost = generator.nextInt(upperBound: 25) + 1
                    let value = "seed-\(seed)-step-\(step)"
                    cache.insert(value, for: key, cost: cost)
                    model.insert(value, for: key, cost: cost)
                } else if action < 82 {
                    let actual = cache.value(for: key)
                    let expected = model.value(for: key)
                    XCTAssertEqual(actual, expected, "seed=\(seed) step=\(step)")
                } else if action < 96 {
                    cache.remove(key)
                    model.remove(key)
                } else {
                    cache.removeAll()
                    model.removeAll()
                }

                if step.isMultiple(of: 40) {
                    for auditKey in 0..<23 {
                        let actual = cache.value(for: auditKey)
                        let expected = model.value(for: auditKey)
                        XCTAssertEqual(
                            actual,
                            expected,
                            "SIEVE 审计失败：seed=\(seed) step=\(step) key=\(auditKey)"
                        )
                    }
                }
                let actualCost = cache.currentCost
                let actualCount = cache.count
                XCTAssertEqual(actualCost, model.currentCost)
                XCTAssertEqual(actualCount, model.count)
                XCTAssertLessThanOrEqual(actualCost, costLimit)
            }
        }
    }

    func testCostAccountingCannotOverflowPastLimit_RES_PT_001() async {
        let cache = MemoryCache<String, String>(costLimit: Int.max)
        cache.insert("huge", for: "huge", cost: Int.max - 5)
        cache.insert("small", for: "small", cost: 10)

        let huge = cache.value(for: "huge")
        let small = cache.value(for: "small")
        let currentCost = cache.currentCost
        let count = cache.count
        XCTAssertNil(huge)
        XCTAssertEqual(small, "small")
        XCTAssertEqual(currentCost, 10)
        XCTAssertEqual(count, 1)
    }

    func testCompactSieveMatchesReferenceAcrossDeterministicTrace_CACHE_PT_047() {
        let reference = MemoryCache<Int, Int>(costLimit: 31)
        let compact = FoveaCompactSieveCache<Int, Int>(costLimit: 31)
        var state: UInt64 = 0xA076_1D64_78BD_642F

        func next() -> UInt64 {
            state &*= 6_364_136_223_846_793_005
            state &+= 1_442_695_040_888_963_407
            return state
        }

        for step in 0..<4_096 {
            let draw = next()
            let key = Int((draw >> 8) % 23)
            switch draw % 5 {
            case 0, 1:
                let value = Int((draw >> 16) & 0xFFFF)
                let cost = Int((draw >> 32) % 13) + 1
                reference.insert(value, for: key, cost: cost)
                compact.insert(value, for: key, cost: cost)
            case 2:
                XCTAssertEqual(compact.value(for: key), reference.value(for: key), "step=\(step)")
            case 3:
                reference.remove(key)
                compact.remove(key)
            default:
                let modulus = Int((draw >> 24) % 7) + 2
                reference.removeAll { $0 % modulus == 0 }
                compact.removeAll { $0 % modulus == 0 }
            }
            XCTAssertEqual(compact.count, reference.count, "step=\(step)")
            XCTAssertEqual(compact.currentCost, reference.currentCost, "step=\(step)")
        }

        for key in 0..<23 {
            XCTAssertEqual(compact.value(for: key), reference.value(for: key), "final key=\(key)")
        }
        XCTAssertEqual(compact.removeAllAndReport(), reference.removeAllAndReport())
    }
}

private struct ReferenceSIEVE<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var cost: Int
        var visited: Bool
    }

    private let costLimit: Int
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var hand: Key?
    private(set) var currentCost = 0

    init(costLimit: Int) {
        self.costLimit = max(1, costLimit)
    }

    var count: Int { entries.count }

    mutating func value(for key: Key) -> Value? {
        guard let value = entries[key]?.value else { return nil }
        entries[key]?.visited = true
        return value
    }

    mutating func insert(_ value: Value, for key: Key, cost: Int) {
        remove(key)
        let normalized = max(1, cost)
        guard normalized <= costLimit else { return }
        while currentCost > costLimit - normalized {
            guard let victim = victim() else { break }
            remove(victim)
        }
        entries[key] = Entry(value: value, cost: normalized, visited: false)
        order.append(key)
        currentCost += normalized
    }

    mutating func remove(_ key: Key) {
        guard let entry = entries[key], let index = order.firstIndex(of: key) else { return }
        if hand == key {
            if order.count == 1 {
                hand = nil
            } else {
                hand =
                    index + 1 < order.count ? order[index + 1] : order.first(where: { $0 != key })
            }
        }
        entries.removeValue(forKey: key)
        order.remove(at: index)
        if let hand, entries[hand] == nil { self.hand = order.first }
        currentCost -= entry.cost
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        hand = nil
        currentCost = 0
    }

    private mutating func victim() -> Key? {
        guard !order.isEmpty else { return nil }
        if hand == nil || entries[hand!] == nil { hand = order.first }
        while let candidate = hand, var entry = entries[candidate],
            let index = order.firstIndex(of: candidate)
        {
            let previous = index + 1 < order.count ? order[index + 1] : order.first
            if entry.visited {
                entry.visited = false
                entries[candidate] = entry
                hand = previous
            } else {
                hand = previous == candidate ? nil : previous
                return candidate
            }
        }
        return order.first
    }
}

private struct DeterministicGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9e37_79b9_7f4a_7c15 : seed
    }

    mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(state % UInt64(upperBound))
    }

}
