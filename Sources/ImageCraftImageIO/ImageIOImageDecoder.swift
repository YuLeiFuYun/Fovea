import CoreGraphics
import Foundation
import ImageCraftCore
import ImageIO

public struct ImageIOImageDecoder: ImageDecoding {
  public init() {}

  public func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
    try inspect(data: data, limits: limits).probe
  }

  public func decode(
    data: Data,
    target: TargetPixels,
    limits: DecodeLimits = .coreV1
  ) throws -> DecodedImage {
    let probe = try probe(data: data, limits: limits)
    return try decode(data: data, probe: probe, target: target, limits: limits)
  }

  public func decode(
    data: Data,
    probe: ImageProbe,
    target: TargetPixels,
    limits: DecodeLimits = .coreV1
  ) throws -> DecodedImage {
    let inspection = try inspect(data: data, limits: limits)
    let verifiedProbe = inspection.probe
    guard verifiedProbe == probe else { throw ImageCraftError.probeMismatch }
    let widthScale = Double(target.width) / Double(verifiedProbe.pixelWidth)
    let heightScale = Double(target.height) / Double(verifiedProbe.pixelHeight)
    let scale = min(1, widthScale, heightScale)
    let thumbnailSize = max(
      1,
      min(
        limits.maximumDimension,
        Int(
          floor(
            Double(max(verifiedProbe.pixelWidth, verifiedProbe.pixelHeight)) * scale
          )
        )
      )
    )

    let source = inspection.source
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

  private func inspect(
    data: Data,
    limits: DecodeLimits
  ) throws -> (source: CGImageSource, probe: ImageProbe) {
    guard data.count <= limits.maximumEncodedBytes else {
      throw ImageCraftError.encodedBytesExceeded
    }
    let container = try EncodedImageSecurityInspector.inspect(data)
    guard limits.allowedFormats.contains(container.format) else {
      throw ImageCraftError.unsupportedFormat
    }
    guard container.metadataByteCount <= limits.maximumMetadataBytes else {
      throw ImageCraftError.metadataLimitExceeded
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    guard sourceFormat(source) == container.format else {
      throw ImageCraftError.formatMismatch
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

    let propertyMetadataBytes = serializedPropertySize(properties)
    let metadataByteCount = max(container.metadataByteCount, propertyMetadataBytes)
    guard metadataByteCount <= limits.maximumMetadataBytes else {
      throw ImageCraftError.metadataLimitExceeded
    }
    let auxiliaryAttachmentCount = auxiliaryAttachmentCount(in: source)
    guard auxiliaryAttachmentCount <= limits.maximumAuxiliaryAttachments else {
      throw ImageCraftError.auxiliaryAttachmentLimitExceeded
    }

    let orientation = orientationValue(properties[kCGImagePropertyOrientation])
    let swapsDimensions = (5...8).contains(orientation)
    let width = swapsDimensions ? rawHeight : rawWidth
    let height = swapsDimensions ? rawWidth : rawHeight
    try validate(width: width, height: height, limits: limits)
    return (
      source,
      ImageProbe(
        pixelWidth: width,
        pixelHeight: height,
        frameCount: frameCount,
        orientation: orientation,
        format: container.format,
        metadataByteCount: metadataByteCount,
        auxiliaryAttachmentCount: auxiliaryAttachmentCount
      )
    )
  }

  private func sourceFormat(_ source: CGImageSource) -> EncodedImageFormat? {
    guard let type = CGImageSourceGetType(source) as String? else { return nil }
    switch type {
    case "public.png": return .png
    case "public.jpeg": return .jpeg
    case "com.compuserve.gif": return .gif
    default: return nil
    }
  }

  private func serializedPropertySize(_ properties: [CFString: Any]) -> Int {
    guard PropertyListSerialization.propertyList(properties, isValidFor: .binary),
      let data = try? PropertyListSerialization.data(
        fromPropertyList: properties,
        format: .binary,
        options: 0
      )
    else { return 0 }
    return data.count
  }

  private func auxiliaryAttachmentCount(in source: CGImageSource) -> Int {
    let types: [CFString] = [
      kCGImageAuxiliaryDataTypeDisparity,
      kCGImageAuxiliaryDataTypeDepth,
      kCGImageAuxiliaryDataTypePortraitEffectsMatte,
    ]
    return types.reduce(into: 0) { count, type in
      if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) != nil {
        count += 1
      }
    }
  }

  private var sourceOptions: CFDictionary {
    [kCGImageSourceShouldCache: false] as CFDictionary
  }

  private func orientationValue(_ value: Any?) -> UInt32 {
    let candidate: UInt32
    if let number = value as? NSNumber {
      candidate = number.uint32Value
    } else if let value = value as? UInt32 {
      candidate = value
    } else if let value = value as? Int, value >= 1 {
      candidate = UInt32(value)
    } else {
      candidate = 1
    }
    return (1...8).contains(candidate) ? candidate : 1
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
