import CoreGraphics
import Foundation

public struct TargetPixels: Hashable, Sendable, Codable {
  public let width: Int
  public let height: Int

  public init(width: Int, height: Int) throws {
    guard width > 0, height > 0 else { throw ImageCraftError.invalidTarget }
    self.width = width
    self.height = height
  }

  public var maximumDimension: Int { max(width, height) }

  public var pixelCount: Int {
    let (result, overflow) = width.multipliedReportingOverflow(by: height)
    return overflow ? Int.max : result
  }
}

public enum EncodedImageFormat: String, CaseIterable, Codable, Hashable, Sendable {
  case png
  case jpeg
  case gif
}

public struct DecodeLimits: Hashable, Sendable, Codable {
  public let maximumEncodedBytes: Int
  public let maximumDimension: Int
  public let maximumPixelCount: Int
  public let maximumFrameCount: Int
  public let maximumMetadataBytes: Int
  public let maximumAuxiliaryAttachments: Int
  public let allowedFormats: Set<EncodedImageFormat>

  public init(
    maximumEncodedBytes: Int = 64 * 1024 * 1024,
    maximumDimension: Int = 16_384,
    maximumPixelCount: Int = 100_000_000,
    maximumFrameCount: Int = 1,
    maximumMetadataBytes: Int = 4 * 1024 * 1024,
    maximumAuxiliaryAttachments: Int = 0,
    allowedFormats: Set<EncodedImageFormat> = Set(EncodedImageFormat.allCases)
  ) {
    self.maximumEncodedBytes = max(1, maximumEncodedBytes)
    self.maximumDimension = max(1, maximumDimension)
    self.maximumPixelCount = max(1, maximumPixelCount)
    self.maximumFrameCount = max(1, maximumFrameCount)
    self.maximumMetadataBytes = max(0, maximumMetadataBytes)
    self.maximumAuxiliaryAttachments = max(0, maximumAuxiliaryAttachments)
    self.allowedFormats = allowedFormats
  }

  public static let coreV1 = DecodeLimits()
}

public enum ImageColorPolicy: String, Codable, Hashable, Sendable {
  case preserveSource
  case convertToSRGB
}

public enum SourceColorProfile: String, Codable, Hashable, Sendable {
  case embeddedICC
  case standardSRGB
  case absent
  case unknown
}

public struct ImageDecodeRequest: Codable, Hashable, Sendable {
  public let target: TargetPixels
  public let contentMode: ImageContentMode
  public let geometryPolicyFingerprint: String
  public let colorPolicy: ImageColorPolicy

  public init(
    target: TargetPixels,
    contentMode: ImageContentMode = .fit,
    geometryPolicyFingerprint: String = "exact-v1",
    colorPolicy: ImageColorPolicy = .preserveSource
  ) {
    self.target = target
    self.contentMode = contentMode
    self.geometryPolicyFingerprint = geometryPolicyFingerprint
    self.colorPolicy = colorPolicy
  }
}

public protocol ImageDecoding: Sendable {
  func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe
  func decode(
    data: Data,
    probe: ImageProbe,
    request: ImageDecodeRequest,
    limits: DecodeLimits
  ) throws -> DecodedImage
}

public enum ImageCraftError: Error, Equatable, Sendable {
  case invalidTarget
  case targetLimitExceeded
  case encodedBytesExceeded
  case unsupportedOrCorruptImage
  case unsupportedFormat
  case formatMismatch
  case metadataLimitExceeded
  case auxiliaryAttachmentLimitExceeded
  case dimensionLimitExceeded
  case pixelLimitExceeded
  case frameLimitExceeded
  case probeMismatch
  case decodeFailed
}

public struct ImageProbe: Hashable, Sendable {
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let frameCount: Int
  public let orientation: UInt32
  public let format: EncodedImageFormat
  public let metadataByteCount: Int
  public let auxiliaryAttachmentCount: Int
  public let sourceColorProfile: SourceColorProfile

  public init(
    pixelWidth: Int,
    pixelHeight: Int,
    frameCount: Int,
    orientation: UInt32 = 1,
    format: EncodedImageFormat = .png,
    metadataByteCount: Int = 0,
    auxiliaryAttachmentCount: Int = 0,
    sourceColorProfile: SourceColorProfile = .unknown
  ) {
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.frameCount = frameCount
    self.orientation = orientation
    self.format = format
    self.metadataByteCount = metadataByteCount
    self.auxiliaryAttachmentCount = auxiliaryAttachmentCount
    self.sourceColorProfile = sourceColorProfile
  }
}

public struct ImageColorDescription: Hashable, Sendable {
  public let sourceProfile: SourceColorProfile
  public let outputColorSpaceName: String

  public init(sourceProfile: SourceColorProfile, outputColorSpaceName: String) {
    self.sourceProfile = sourceProfile
    self.outputColorSpaceName = outputColorSpaceName
  }
}

public enum ImageAlphaMode: String, Codable, Hashable, Sendable {
  case none
  case premultipliedFirst
  case premultipliedLast
  case straightFirst
  case straightLast
  case alphaOnly
  case unknown
}

public struct ImagePixelFormatDescription: Hashable, Sendable {
  public let bitsPerComponent: Int
  public let bitsPerPixel: Int
  public let bytesPerRow: Int
  public let bitmapInfoRawValue: UInt32

  public init(
    bitsPerComponent: Int,
    bitsPerPixel: Int,
    bytesPerRow: Int,
    bitmapInfoRawValue: UInt32
  ) {
    self.bitsPerComponent = bitsPerComponent
    self.bitsPerPixel = bitsPerPixel
    self.bytesPerRow = bytesPerRow
    self.bitmapInfoRawValue = bitmapInfoRawValue
  }
}

public enum ImageDisplayReadiness: String, Codable, Hashable, Sendable {
  case fullyDecodedCPU
  case platformPrepared
}

/// 不可变的解码像素。受支持 SDK 会将 CoreGraphics 的 `CGImage` 导入为 `Sendable`；
/// Fovea 既不暴露可变的底层存储，也不会在构造后修改图像。
public struct DecodedImage: Sendable {
  public let cgImage: CGImage
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let colorDescription: ImageColorDescription
  public let alphaMode: ImageAlphaMode
  public let pixelFormat: ImagePixelFormatDescription
  public let displayReadiness: ImageDisplayReadiness

  public init(
    cgImage: CGImage,
    sourceColorProfile: SourceColorProfile = .unknown,
    displayReadiness: ImageDisplayReadiness = .fullyDecodedCPU
  ) {
    self.cgImage = cgImage
    self.pixelWidth = cgImage.width
    self.pixelHeight = cgImage.height
    self.colorDescription = ImageColorDescription(
      sourceProfile: sourceColorProfile,
      outputColorSpaceName: (cgImage.colorSpace?.name as String?) ?? "unknown"
    )
    self.alphaMode = Self.alphaMode(for: cgImage.alphaInfo)
    self.pixelFormat = ImagePixelFormatDescription(
      bitsPerComponent: cgImage.bitsPerComponent,
      bitsPerPixel: cgImage.bitsPerPixel,
      bytesPerRow: cgImage.bytesPerRow,
      bitmapInfoRawValue: cgImage.bitmapInfo.rawValue
    )
    self.displayReadiness = displayReadiness
  }

  public var estimatedByteCost: Int {
    let (result, overflow) = cgImage.bytesPerRow.multipliedReportingOverflow(by: pixelHeight)
    return overflow ? Int.max : result
  }

  /// ImageIO 使用立即缓存完成 CPU 解码；再次请求显示准备时直接复用同一不可变表面。
  public func preparedForDisplay() -> DecodedImage { self }

  private static func alphaMode(for info: CGImageAlphaInfo) -> ImageAlphaMode {
    switch info {
    case .none, .noneSkipFirst, .noneSkipLast: .none
    case .premultipliedFirst: .premultipliedFirst
    case .premultipliedLast: .premultipliedLast
    case .first: .straightFirst
    case .last: .straightLast
    case .alphaOnly: .alphaOnly
    @unknown default: .unknown
    }
  }
}
