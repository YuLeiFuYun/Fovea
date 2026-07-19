import CoreGraphics
import Foundation
import FoveaCore
import ImageCraftCore
import ImageCraftImageIO
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class ImageDecoderTests: XCTestCase {
  func testP3AndSRGBPoliciesProduceDistinctRenderKeys_IMG_PT_002() throws {
    let data = try makeColorManagedPNG(
      colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
    )
    let contentID = ContentID(data: data)
    let preserve = DecodeKey(
      contentID: contentID,
      targetWidth: 16,
      targetHeight: 8,
      contentMode: .fit,
      geometryPolicyFingerprint: "exact-v1",
      colorPolicy: .preserveSource,
      decoderVersion: 1
    )
    let converted = DecodeKey(
      contentID: contentID,
      targetWidth: 16,
      targetHeight: 8,
      contentMode: .fit,
      geometryPolicyFingerprint: "exact-v1",
      colorPolicy: .convertToSRGB,
      decoderVersion: 1
    )

    XCTAssertNotEqual(preserve, converted)
    XCTAssertNotEqual(
      RenderKey(decodeKey: preserve, renderVersion: 1),
      RenderKey(decodeKey: converted, renderVersion: 1)
    )

    let decoder = ImageIOImageDecoder()
    let probe = try decoder.probe(data: data, limits: .coreV1)
    let preservedImage = try decoder.decode(
      data: data,
      probe: probe,
      request: ImageDecodeRequest(
        target: try TargetPixels(width: 16, height: 8),
        colorPolicy: .preserveSource
      ),
      limits: .coreV1
    )
    let convertedImage = try decoder.decode(
      data: data,
      probe: probe,
      request: ImageDecodeRequest(
        target: try TargetPixels(width: 16, height: 8),
        colorPolicy: .convertToSRGB
      ),
      limits: .coreV1
    )
    XCTAssertEqual(
      preservedImage.colorDescription.outputColorSpaceName,
      CGColorSpace.displayP3 as String
    )
    XCTAssertEqual(
      convertedImage.colorDescription.outputColorSpaceName,
      CGColorSpace.sRGB as String
    )
  }

  func testMissingColorProfileUsesStableSRGBFallback_IMG_PT_003() throws {
    let tagged = try makeColorManagedPNG(
      colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
    )
    let data = try removingPNGChunks(["iCCP", "sRGB", "gAMA", "cHRM"], from: tagged)
    let decoder = ImageIOImageDecoder()
    let target = try TargetPixels(width: 16, height: 8)
    let first = try decoder.decode(data: data, target: target)
    let second = try decoder.decode(data: data, target: target)

    XCTAssertEqual(first.colorDescription.sourceProfile, .absent)
    XCTAssertEqual(first.colorDescription.outputColorSpaceName, CGColorSpace.sRGB as String)
    XCTAssertEqual(second.colorDescription, first.colorDescription)
  }

  func testDownsamplePreservesEmbeddedP3Description_IMG_PT_006() throws {
    let data = try makeColorManagedPNG(
      width: 64,
      height: 32,
      colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
    )
    let decoder = ImageIOImageDecoder()
    let probe = try decoder.probe(data: data, limits: .coreV1)
    let decoded = try decoder.decode(
      data: data,
      probe: probe,
      request: ImageDecodeRequest(
        target: try TargetPixels(width: 16, height: 16),
        colorPolicy: .preserveSource
      ),
      limits: .coreV1
    )

    XCTAssertEqual(probe.sourceColorProfile, .embeddedICC)
    XCTAssertEqual(decoded.colorDescription.sourceProfile, .embeddedICC)
    XCTAssertEqual(
      decoded.colorDescription.outputColorSpaceName,
      CGColorSpace.displayP3 as String
    )
    XCTAssertEqual(decoded.pixelWidth, 16)
    XCTAssertEqual(decoded.pixelHeight, 8)
  }

  func testAlphaAndPixelFormatMatchTransparentReference_IMG_PT_007() throws {
    let data = try makeColorManagedPNG(
      width: 8,
      height: 8,
      colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
      rgba: (32, 16, 8, 64)
    )
    let decoded = try ImageIOImageDecoder().decode(
      data: data,
      target: try TargetPixels(width: 8, height: 8)
    )

    XCTAssertEqual(decoded.alphaMode, .premultipliedFirst)
    XCTAssertEqual(decoded.pixelFormat.bitsPerComponent, 8)
    XCTAssertEqual(decoded.pixelFormat.bitsPerPixel, 32)
    XCTAssertEqual(try centerAlpha(of: decoded.cgImage), 64, accuracy: 2)
  }

  func testFullyDecodedImageDisplayPreparationIsIdempotent_IMG_PT_008() throws {
    let decoded = try ImageIOImageDecoder().decode(
      data: makePNG(width: 16, height: 8),
      target: try TargetPixels(width: 16, height: 8)
    )
    let prepared = decoded.preparedForDisplay()

    XCTAssertEqual(decoded.displayReadiness, .fullyDecodedCPU)
    XCTAssertEqual(prepared.displayReadiness, .fullyDecodedCPU)
    XCTAssertTrue(decoded.cgImage === prepared.cgImage)
  }

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

private func makeColorManagedPNG(
  width: Int = 16,
  height: Int = 8,
  colorSpace: CGColorSpace,
  rgba: (UInt8, UInt8, UInt8, UInt8) = (180, 90, 40, 255)
) throws -> Data {
  let bytesPerRow = width * 4
  var bytes = Data(capacity: bytesPerRow * height)
  for _ in 0..<(width * height) {
    bytes.append(rgba.0)
    bytes.append(rgba.1)
    bytes.append(rgba.2)
    bytes.append(rgba.3)
  }
  guard let provider = CGDataProvider(data: bytes as CFData),
    let image = CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  else { throw ImageFixtureError.creationFailed }
  let output = NSMutableData()
  guard
    let destination = CGImageDestinationCreateWithData(
      output,
      UTType.png.identifier as CFString,
      1,
      nil
    )
  else { throw ImageFixtureError.creationFailed }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { throw ImageFixtureError.creationFailed }
  return output as Data
}

private func removingPNGChunks(_ removedTypes: Set<String>, from data: Data) throws -> Data {
  guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
    throw ImageFixtureError.creationFailed
  }
  var result = Data(data.prefix(8))
  var offset = 8
  while offset + 12 <= data.count {
    let length =
      Int(data[offset]) << 24
      | Int(data[offset + 1]) << 16
      | Int(data[offset + 2]) << 8
      | Int(data[offset + 3])
    let end = offset + 12 + length
    guard end <= data.count,
      let type = String(data: data[(offset + 4)..<(offset + 8)], encoding: .ascii)
    else { throw ImageFixtureError.creationFailed }
    if !removedTypes.contains(type) {
      result.append(data[offset..<end])
    }
    offset = end
    if type == "IEND" { break }
  }
  guard offset <= data.count else { throw ImageFixtureError.creationFailed }
  return result
}

private func centerAlpha(of image: CGImage) throws -> Double {
  var pixel = [UInt8](repeating: 0, count: 4)
  guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
      data: &pixel,
      width: 1,
      height: 1,
      bitsPerComponent: 8,
      bytesPerRow: 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  else { throw ImageFixtureError.creationFailed }
  context.setBlendMode(.copy)
  context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
  return Double(pixel[3])
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
