import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class ImageDecoderTests: XCTestCase {
  func testTargetDecodeAvoidsFullSizeBitmap() throws {
    let data = try makePNG(width: 100, height: 50)
    let decoded = try ImageIOImageDecoder().decode(
      data: data,
      target: try TargetPixels(width: 20, height: 20)
    )
    XCTAssertEqual(decoded.pixelWidth, 20)
    XCTAssertEqual(decoded.pixelHeight, 10)
  }

  func testTargetDecodeRespectsBothDimensions() throws {
    let data = try makePNG(width: 100, height: 50)
    let decoded = try ImageIOImageDecoder().decode(
      data: data,
      target: try TargetPixels(width: 200, height: 20)
    )
    XCTAssertEqual(decoded.pixelWidth, 40)
    XCTAssertEqual(decoded.pixelHeight, 20)
  }

  func testCorruptImageIsRejectedBeforeCommit() throws {
    XCTAssertThrowsError(
      try ImageIOImageDecoder().decode(
        data: Data("not-an-image".utf8),
        target: try TargetPixels(width: 20, height: 20)
      )
    )
  }
}
