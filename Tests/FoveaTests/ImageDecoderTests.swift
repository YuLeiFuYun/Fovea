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

  func testFillDecodeCoversAndCenterCropsTargetGeoPt004() throws {
    let data = try makePNG(width: 100, height: 50)
    let decoder = ImageIOImageDecoder()
    let fit = try decoder.decode(
      data: data,
      request: ImageDecodeRequest(
        target: try TargetPixels(width: 20, height: 20),
        contentMode: .fit
      )
    )
    let fill = try decoder.decode(
      data: data,
      request: ImageDecodeRequest(
        target: try TargetPixels(width: 20, height: 20),
        contentMode: .fill
      )
    )

    XCTAssertEqual(fit.pixelWidth, 20)
    XCTAssertEqual(fit.pixelHeight, 10)
    XCTAssertEqual(fill.pixelWidth, 20)
    XCTAssertEqual(fill.pixelHeight, 20)
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
  func testCoreV1RejectsMultiFrameImagesSecCase003() throws {
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
    let probe = try decoder.probe(data: data, limits: .coreV1)
    XCTAssertEqual(probe.pixelWidth, 60)
    XCTAssertEqual(probe.pixelHeight, 120)

    let decoded = try decoder.decode(
      data: data,
      probe: probe,
      request: ImageDecodeRequest(target: try TargetPixels(width: 30, height: 60)),
      limits: .coreV1
    )
    XCTAssertEqual(decoded.pixelWidth, 30)
    XCTAssertEqual(decoded.pixelHeight, 60)
  }

  func testDecodeRejectsProbeFromDifferentBitstream() throws {
    let data = try makePNG(width: 100, height: 50)
    let forged = ImageProbe(pixelWidth: 10, pixelHeight: 10, frameCount: 1)
    XCTAssertThrowsError(
      try ImageIOImageDecoder().decode(
        data: data,
        probe: forged,
        request: ImageDecodeRequest(target: try TargetPixels(width: 20, height: 20)),
        limits: .coreV1
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .probeMismatch)
    }
  }

  func testOversizedContainerMetadataIsRejectedBeforeDecodeSecCase004() throws {
    let data = try makePNGWithTextMetadata(payloadBytes: 1_024)
    let limits = DecodeLimits(maximumMetadataBytes: 128)

    XCTAssertThrowsError(
      try ImageIOImageDecoder().probe(data: data, limits: limits)
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .metadataLimitExceeded)
    }
  }

  func testUnknownAndDisallowedFormatsAreRejectedSecCase021() throws {
    XCTAssertThrowsError(
      try ImageIOImageDecoder().probe(
        data: Data("BM-not-a-supported-core-format".utf8),
        limits: .coreV1
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .unsupportedFormat)
    }

    let png = try makePNG(width: 10, height: 10)
    XCTAssertThrowsError(
      try ImageIOImageDecoder().probe(
        data: png,
        limits: DecodeLimits(allowedFormats: [.jpeg])
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .unsupportedFormat)
    }
  }

  func testTargetPixelCountSaturatesOnOverflow() throws {
    let target = try TargetPixels(width: Int.max, height: Int.max)
    XCTAssertEqual(target.pixelCount, Int.max)
  }
}

private func makePNGWithTextMetadata(payloadBytes: Int) throws -> Data {
  var data = try makePNG(width: 10, height: 10)
  let iendSignature = Data([0, 0, 0, 0, 73, 69, 78, 68])
  guard let iend = data.range(of: iendSignature)?.lowerBound else {
    throw ImageFixtureError.creationFailed
  }
  var chunk = Data()
  let length = UInt32(payloadBytes).bigEndian
  withUnsafeBytes(of: length) { chunk.append(contentsOf: $0) }
  chunk.append(contentsOf: Data("tEXt".utf8))
  chunk.append(Data(repeating: 65, count: payloadBytes))
  chunk.append(Data(repeating: 0, count: 4))
  data.insert(contentsOf: chunk, at: iend)
  return data
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
