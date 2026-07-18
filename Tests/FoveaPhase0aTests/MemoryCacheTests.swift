import AkashicMemory
import XCTest

final class MemoryCacheTests: XCTestCase {
  func testLRUHitPromotesEntryBeforeEviction() async {
    let cache = MemoryCache<String, String>(costLimit: 8)
    await cache.insert("first", for: "a", cost: 4)
    await cache.insert("second", for: "b", cost: 4)
    let promoted = await cache.value(for: "a")
    XCTAssertEqual(promoted, "first")
    await cache.insert("third", for: "c", cost: 4)

    let a = await cache.value(for: "a")
    let b = await cache.value(for: "b")
    let c = await cache.value(for: "c")
    XCTAssertEqual(a, "first")
    XCTAssertNil(b)
    XCTAssertEqual(c, "third")
    let count = await cache.count
    XCTAssertEqual(count, 2)
  }

  func testOversizedValueDoesNotRemainResident() async {
    let cache = MemoryCache<Int, String>(costLimit: 4)
    await cache.insert("oversized", for: 1, cost: 8)
    let value = await cache.value(for: 1)
    let count = await cache.count
    XCTAssertNil(value)
    XCTAssertEqual(count, 0)
  }
}
