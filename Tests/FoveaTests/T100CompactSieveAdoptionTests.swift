import Dispatch
import XCTest

@testable import FoveaCore

final class T100CompactSieveAdoptionTests: XCTestCase {
    func testCountLimitReplacementAndClampPreserveResidents_T100_AUTH_PT_018() {
        let cache = FoveaCompactSieveCache<Int, Int>(costLimit: 100, countLimit: 2)
        cache.insert(1, for: 1, cost: 1)
        cache.insert(2, for: 2, cost: 1)

        cache.insert(10, for: 1, cost: 1)

        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.currentCost, 2)
        XCTAssertEqual(cache.value(for: 1), 10)
        XCTAssertEqual(cache.value(for: 2), 2)

        let clamped = FoveaCompactSieveCache<Int, Int>(costLimit: 100, countLimit: 0)
        clamped.insert(1, for: 1, cost: 1)
        clamped.insert(2, for: 2, cost: 1)
        XCTAssertEqual(clamped.count, 1)
        XCTAssertEqual(clamped.currentCost, 1)
        XCTAssertFalse(clamped.contains(1))
        XCTAssertTrue(clamped.contains(2))
    }

    func testTrimReportsExactSIEVEVictimsAndClamp_T100_AUTH_PT_019() {
        let cache = FoveaCompactSieveCache<Int, Int>(costLimit: 10)
        cache.insert(1, for: 1, cost: 4)
        cache.insert(2, for: 2, cost: 3)
        cache.insert(3, for: 3, cost: 2)
        XCTAssertEqual(cache.value(for: 1), 1)

        XCTAssertEqual(cache.trimReportingEvictions(toCost: 4), [2, 3])
        XCTAssertEqual(cache.currentCost, 4)
        XCTAssertEqual(cache.count, 1)
        XCTAssertTrue(cache.contains(1))
        XCTAssertEqual(cache.trimReportingEvictions(toCost: .max), [])
        XCTAssertEqual(cache.trimReportingEvictions(toCost: -1), [1])
        XCTAssertEqual(cache.currentCost, 0)
        XCTAssertEqual(cache.count, 0)
    }

    func testPredicateRemovalSummaryMatchesActualResidents_T100_AUTH_PT_020() {
        let cache = FoveaCompactSieveCache<Int, Int>(costLimit: 20)
        cache.insert(1, for: 1, cost: 2)
        cache.insert(2, for: 2, cost: 3)
        cache.insert(3, for: 3, cost: 4)
        cache.insert(4, for: 4, cost: 5)

        let summary = cache.removeAllAndReport { $0.isMultiple(of: 2) }

        XCTAssertEqual(summary.itemCount, 2)
        XCTAssertEqual(summary.costBytes, 8)
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.currentCost, 6)
        XCTAssertTrue(cache.contains(1))
        XCTAssertFalse(cache.contains(2))
        XCTAssertTrue(cache.contains(3))
        XCTAssertFalse(cache.contains(4))
    }

    func testIntMaxCostBoundaryEvictsWithoutOverflow_T100_AUTH_PT_021() {
        let cache = FoveaCompactSieveCache<Int, Int>(costLimit: .max, countLimit: 2)
        cache.insert(1, for: 1, cost: .max)
        XCTAssertEqual(cache.currentCost, Int.max)
        XCTAssertEqual(cache.count, 1)

        XCTAssertEqual(cache.insertReportingEvictions(2, for: 2, cost: 1), [1])
        XCTAssertEqual(cache.currentCost, 1)
        XCTAssertEqual(cache.count, 1)
        XCTAssertFalse(cache.contains(1))
        XCTAssertTrue(cache.contains(2))

        let summary = cache.removeAllAndReport()
        XCTAssertEqual(summary.itemCount, 1)
        XCTAssertEqual(summary.costBytes, 1)
        XCTAssertEqual(cache.currentCost, 0)
        XCTAssertEqual(cache.count, 0)
    }

    func testConcurrentOperationsPreserveBoundsAndClearSummary_T100_AUTH_PT_022() {
        let cache = FoveaCompactSieveCache<Int, Int>(costLimit: 64, countLimit: 16)

        DispatchQueue.concurrentPerform(iterations: 1_024) { iteration in
            let key = iteration % 41
            switch iteration % 5 {
            case 0:
                cache.insert(iteration, for: key, cost: (iteration % 7) + 1)
            case 1:
                _ = cache.value(for: key)
            case 2:
                _ = cache.contains(key)
            case 3:
                cache.remove(key)
            default:
                _ = cache.insertReportingEvictions(
                    iteration,
                    for: key,
                    cost: (iteration % 5) + 1
                )
            }
        }

        let count = cache.count
        let cost = cache.currentCost
        XCTAssertGreaterThanOrEqual(count, 0)
        XCTAssertLessThanOrEqual(count, 16)
        XCTAssertGreaterThanOrEqual(cost, 0)
        XCTAssertLessThanOrEqual(cost, 64)

        let summary = cache.removeAllAndReport()
        XCTAssertEqual(summary.itemCount, count)
        XCTAssertEqual(summary.costBytes, cost)
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.currentCost, 0)
    }
}
