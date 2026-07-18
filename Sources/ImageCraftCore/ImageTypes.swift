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
  public var pixelCount: Int { width.multipliedReportingOverflow(by: height).partialValue }
}

public struct DecodeLimits: Hashable, Sendable, Codable {
  public let maximumEncodedBytes: Int
  public let maximumDimension: Int
  public let maximumPixelCount: Int

  public init(
    maximumEncodedBytes: Int = 64 * 1024 * 1024,
    maximumDimension: Int = 16_384,
    maximumPixelCount: Int = 100_000_000
  ) {
    self.maximumEncodedBytes = maximumEncodedBytes
    self.maximumDimension = maximumDimension
    self.maximumPixelCount = maximumPixelCount
  }

  public static let phase0a = DecodeLimits()
}

public enum ImageCraftError: Error, Equatable, Sendable {
  case invalidTarget
  case encodedBytesExceeded
  case unsupportedOrCorruptImage
  case dimensionLimitExceeded
  case pixelLimitExceeded
  case decodeFailed
}

public struct ImageProbe: Hashable, Sendable {
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let frameCount: Int

  public init(pixelWidth: Int, pixelHeight: Int, frameCount: Int) {
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.frameCount = frameCount
  }
}

public struct DecodedImage: Sendable {
  public let cgImage: CGImage
  public let pixelWidth: Int
  public let pixelHeight: Int

  public init(cgImage: CGImage) {
    self.cgImage = cgImage
    self.pixelWidth = cgImage.width
    self.pixelHeight = cgImage.height
  }

  public var estimatedByteCost: Int {
    pixelWidth.multipliedReportingOverflow(by: pixelHeight).partialValue
      .multipliedReportingOverflow(by: 4).partialValue
  }
}
