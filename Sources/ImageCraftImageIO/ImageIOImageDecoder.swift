import CoreGraphics
import Foundation
import ImageCraftCore
import ImageIO

public struct ImageIOImageDecoder: ImageDecoding {
  public init() {}

  public func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
    guard data.count <= limits.maximumEncodedBytes else {
      throw ImageCraftError.encodedBytesExceeded
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }

    let frameCount = CGImageSourceGetCount(source)
    guard frameCount > 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
    guard frameCount <= limits.maximumFrameCount else {
      throw ImageCraftError.frameLimitExceeded
    }
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
      let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int
    else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }

    let orientation = orientationValue(properties[kCGImagePropertyOrientation])
    let swapsDimensions = (5...8).contains(orientation)
    let width = swapsDimensions ? rawHeight : rawWidth
    let height = swapsDimensions ? rawWidth : rawHeight
    try validate(width: width, height: height, limits: limits)
    return ImageProbe(
      pixelWidth: width,
      pixelHeight: height,
      frameCount: frameCount,
      orientation: orientation
    )
  }

  public func decode(
    data: Data,
    target: TargetPixels,
    limits: DecodeLimits = .phase0a
  ) throws -> DecodedImage {
    let probe = try probe(data: data, limits: limits)
    return try decode(data: data, probe: probe, target: target, limits: limits)
  }

  public func decode(
    data: Data,
    probe: ImageProbe,
    target: TargetPixels,
    limits: DecodeLimits = .phase0a
  ) throws -> DecodedImage {
    guard probe.frameCount <= limits.maximumFrameCount else {
      throw ImageCraftError.frameLimitExceeded
    }
    let widthScale = Double(target.width) / Double(probe.pixelWidth)
    let heightScale = Double(target.height) / Double(probe.pixelHeight)
    let scale = min(1, widthScale, heightScale)
    let thumbnailSize = max(
      1,
      min(
        limits.maximumDimension,
        Int(floor(Double(max(probe.pixelWidth, probe.pixelHeight)) * scale))
      )
    )

    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }

    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]

    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw ImageCraftError.decodeFailed
    }
    try validate(width: image.width, height: image.height, limits: limits)
    guard image.width <= target.width, image.height <= target.height else {
      throw ImageCraftError.decodeFailed
    }
    return DecodedImage(cgImage: image)
  }

  private func orientationValue(_ value: Any?) -> UInt32 {
    if let number = value as? NSNumber { return number.uint32Value }
    if let value = value as? UInt32 { return value }
    if let value = value as? Int, value >= 1 { return UInt32(value) }
    return 1
  }

  private func validate(width: Int, height: Int, limits: DecodeLimits) throws {
    guard width > 0, height > 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
    guard width <= limits.maximumDimension, height <= limits.maximumDimension else {
      throw ImageCraftError.dimensionLimitExceeded
    }
    let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
    guard !overflow, pixels <= limits.maximumPixelCount else {
      throw ImageCraftError.pixelLimitExceeded
    }
  }
}
