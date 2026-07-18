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

public struct DecodeLimits: Hashable, Sendable, Codable {
  public let maximumEncodedBytes: Int
  public let maximumDimension: Int
  public let maximumPixelCount: Int
  public let maximumFrameCount: Int

  public init(
    maximumEncodedBytes: Int = 64 * 1024 * 1024,
    maximumDimension: Int = 16_384,
    maximumPixelCount: Int = 100_000_000,
    maximumFrameCount: Int = 1
  ) {
    self.maximumEncodedBytes = max(1, maximumEncodedBytes)
    self.maximumDimension = max(1, maximumDimension)
    self.maximumPixelCount = max(1, maximumPixelCount)
    self.maximumFrameCount = max(1, maximumFrameCount)
  }

  public static let phase0a = DecodeLimits()
}

public protocol ImageDecoding: Sendable {
  func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe
  func decode(
    data: Data,
    probe: ImageProbe,
    target: TargetPixels,
    limits: DecodeLimits
  ) throws -> DecodedImage
}

public enum ImageCraftError: Error, Equatable, Sendable {
  case invalidTarget
  case encodedBytesExceeded
  case unsupportedOrCorruptImage
  case dimensionLimitExceeded
  case pixelLimitExceeded
  case frameLimitExceeded
  case decodeFailed
}

public struct ImageProbe: Hashable, Sendable {
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let frameCount: Int
  public let orientation: UInt32

  public init(
    pixelWidth: Int,
    pixelHeight: Int,
    frameCount: Int,
    orientation: UInt32 = 1
  ) {
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.frameCount = frameCount
    self.orientation = orientation
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
    let (result, overflow) = cgImage.bytesPerRow.multipliedReportingOverflow(by: pixelHeight)
    return overflow ? Int.max : result
  }
}
