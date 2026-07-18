import CoreGraphics
import Foundation
import ImageCraftCore
import ImageCraftImageIO
import ImageIO
import UniformTypeIdentifiers
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

extension ImageDecoderTests {
  func testPhase0aRejectsMultiFrameImagesSecCase003() throws {
    let data = try makeAnimatedGIF()
    XCTAssertThrowsError(
      try ImageIOImageDecoder().decode(
        data: data,
        target: try TargetPixels(width: 20, height: 20)
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .frameLimitExceeded)
    }
  }

  func testExifOrientationParticipatesInTargetGeometryImgPt001() throws {
    let data = try makeOrientedJPEG(width: 120, height: 60, orientation: 6)
    let decoder = ImageIOImageDecoder()
    let probe = try decoder.probe(data: data, limits: .phase0a)
    XCTAssertEqual(probe.pixelWidth, 60)
    XCTAssertEqual(probe.pixelHeight, 120)

    let decoded = try decoder.decode(
      data: data,
      probe: probe,
      target: try TargetPixels(width: 30, height: 60),
      limits: .phase0a
    )
    XCTAssertEqual(decoded.pixelWidth, 30)
    XCTAssertEqual(decoded.pixelHeight, 60)
  }

  func testTargetPixelCountSaturatesOnOverflow() throws {
    let target = try TargetPixels(width: Int.max, height: Int.max)
    XCTAssertEqual(target.pixelCount, Int.max)
  }
}

private func makeAnimatedGIF() throws -> Data {
  let image = try makeTestCGImage(width: 4, height: 4)
  let data = NSMutableData()
  guard
    let destination = CGImageDestinationCreateWithData(
      data,
      UTType.gif.identifier as CFString,
      2,
      nil
    )
  else { throw ImageFixtureError.creationFailed }
  CGImageDestinationAddImage(destination, image, nil)
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { throw ImageFixtureError.creationFailed }
  return data as Data
}

private func makeOrientedJPEG(
  width: Int,
  height: Int,
  orientation: UInt32
) throws -> Data {
  let image = try makeTestCGImage(width: width, height: height)
  let data = NSMutableData()
  guard
    let destination = CGImageDestinationCreateWithData(
      data,
      UTType.jpeg.identifier as CFString,
      1,
      nil
    )
  else { throw ImageFixtureError.creationFailed }
  let properties = [kCGImagePropertyOrientation: orientation] as CFDictionary
  CGImageDestinationAddImage(destination, image, properties)
  guard CGImageDestinationFinalize(destination) else { throw ImageFixtureError.creationFailed }
  return data as Data
}

private func makeTestCGImage(width: Int, height: Int) throws -> CGImage {
  let bytesPerRow = width * 4
  let bytes = Data(repeating: 127, count: bytesPerRow * height)
  guard let provider = CGDataProvider(data: bytes as CFData),
    let image = CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  else { throw ImageFixtureError.creationFailed }
  return image
}

private enum ImageFixtureError: Error {
  case creationFailed
}
