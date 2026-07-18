import AkashicMemory
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class MemoryCacheTests: XCTestCase {
  func testLRUHitPromotesEntryBeforeEviction() async throws {
    let image = try ImageIOImageDecoder().decode(
      data: makePNG(width: 10, height: 10),
      target: TargetPixels(width: 10, height: 10)
    )
    let cache = RenderedMemoryCache<String>(costLimit: image.estimatedByteCost * 2)
    await cache.insert(image, for: "a")
    await cache.insert(image, for: "b")
    let promoted = await cache.image(for: "a")
    XCTAssertNotNil(promoted)
    await cache.insert(image, for: "c")

    let a = await cache.image(for: "a")
    let b = await cache.image(for: "b")
    let c = await cache.image(for: "c")
    XCTAssertNotNil(a)
    XCTAssertNil(b)
    XCTAssertNotNil(c)
    let count = await cache.count
    XCTAssertEqual(count, 2)
  }
}
