import Foundation

public enum ImageContentMode: String, Codable, Hashable, Sendable {
  case fit
  case fill
}

public enum RenderCacheAdmission: String, Codable, Hashable, Sendable {
  case transient
  case stable
}

public struct TargetGeometryPolicy: Codable, Hashable, Sendable {
  public let schemaVersion: UInt16
  public let bucketStep: Int
  public let growthHysteresisPermille: Int
  public let shrinkHysteresisPermille: Int
  public let maximumDimension: Int
  public let maximumPixelCount: Int

  public init(
    schemaVersion: UInt16 = 1,
    bucketStep: Int = 16,
    growthHysteresisPermille: Int = 125,
    shrinkHysteresisPermille: Int = 250,
    maximumDimension: Int = 16_384,
    maximumPixelCount: Int = 100_000_000
  ) {
    self.schemaVersion = schemaVersion
    self.bucketStep = max(1, bucketStep)
    self.growthHysteresisPermille = max(0, growthHysteresisPermille)
    self.shrinkHysteresisPermille = max(0, shrinkHysteresisPermille)
    self.maximumDimension = max(1, maximumDimension)
    self.maximumPixelCount = max(1, maximumPixelCount)
  }

  public static let coreV1 = TargetGeometryPolicy()

  public var fingerprint: String {
    [
      "geometry-v\(schemaVersion)",
      "bucket:\(bucketStep)",
      "grow:\(growthHysteresisPermille)",
      "shrink:\(shrinkHysteresisPermille)",
      "dimension:\(maximumDimension)",
      "pixels:\(maximumPixelCount)",
    ].joined(separator: "|")
  }
}

public struct ResolvedImageTarget: Codable, Hashable, Sendable {
  public let pixels: TargetPixels
  public let contentMode: ImageContentMode
  public let geometryPolicyFingerprint: String
  public let cacheAdmission: RenderCacheAdmission

  public init(
    pixels: TargetPixels,
    contentMode: ImageContentMode = .fit,
    geometryPolicyFingerprint: String = "exact-v1",
    cacheAdmission: RenderCacheAdmission = .stable
  ) {
    self.pixels = pixels
    self.contentMode = contentMode
    self.geometryPolicyFingerprint = geometryPolicyFingerprint
    self.cacheAdmission = cacheAdmission
  }
}

public struct TargetGeometryResolver: Sendable {
  public let policy: TargetGeometryPolicy
  private var current: ResolvedImageTarget?

  public init(policy: TargetGeometryPolicy = .coreV1) {
    self.policy = policy
  }

  public mutating func reset() {
    current = nil
  }

  public mutating func resolve(
    widthPoints: Double,
    heightPoints: Double,
    scale: Double,
    contentMode: ImageContentMode = .fit,
    isStable: Bool
  ) throws -> ResolvedImageTarget? {
    guard widthPoints.isFinite, heightPoints.isFinite, scale.isFinite,
      widthPoints >= 0, heightPoints >= 0, scale > 0
    else {
      throw ImageCraftError.invalidTarget
    }
    guard widthPoints > 0, heightPoints > 0 else { return nil }

    let rawWidth = try pixelExtent(points: widthPoints, scale: scale)
    let rawHeight = try pixelExtent(points: heightPoints, scale: scale)
    let resolvedPixels: TargetPixels
    if let current,
      current.contentMode == contentMode,
      remainsInsideHysteresis(
        rawWidth: rawWidth,
        rawHeight: rawHeight,
        current: current.pixels
      )
    {
      resolvedPixels = current.pixels
    } else {
      resolvedPixels = try validatedPixels(
        width: bucket(rawWidth),
        height: bucket(rawHeight)
      )
    }

    let resolved = ResolvedImageTarget(
      pixels: resolvedPixels,
      contentMode: contentMode,
      geometryPolicyFingerprint: policy.fingerprint,
      cacheAdmission: isStable ? .stable : .transient
    )
    current = resolved
    return resolved
  }

  private func pixelExtent(points: Double, scale: Double) throws -> Int {
    let product = points * scale
    guard product.isFinite, product > 0, product <= Double(Int.max) else {
      throw ImageCraftError.targetLimitExceeded
    }
    return max(1, Int(ceil(product)))
  }

  private func bucket(_ value: Int) -> Int {
    let quotient = value.quotientAndRemainder(dividingBy: policy.bucketStep)
    guard quotient.remainder != 0 else { return value }
    let next = quotient.quotient.addingReportingOverflow(1)
    guard !next.overflow else { return Int.max }
    let result = next.partialValue.multipliedReportingOverflow(by: policy.bucketStep)
    return result.overflow ? Int.max : result.partialValue
  }

  private func validatedPixels(width: Int, height: Int) throws -> TargetPixels {
    guard width <= policy.maximumDimension, height <= policy.maximumDimension else {
      throw ImageCraftError.targetLimitExceeded
    }
    let product = width.multipliedReportingOverflow(by: height)
    guard !product.overflow, product.partialValue <= policy.maximumPixelCount else {
      throw ImageCraftError.targetLimitExceeded
    }
    return try TargetPixels(width: width, height: height)
  }

  private func remainsInsideHysteresis(
    rawWidth: Int,
    rawHeight: Int,
    current: TargetPixels
  ) -> Bool {
    insideHysteresis(raw: rawWidth, current: current.width)
      && insideHysteresis(raw: rawHeight, current: current.height)
  }

  private func insideHysteresis(raw: Int, current: Int) -> Bool {
    if raw > current {
      return raw
        <= scaledBoundary(
          current: current,
          permille: 1_000 + policy.growthHysteresisPermille
        )
    }
    if raw < current {
      return raw
        >= scaledBoundary(
          current: current,
          permille: max(0, 1_000 - policy.shrinkHysteresisPermille)
        )
    }
    return true
  }

  private func scaledBoundary(current: Int, permille: Int) -> Int {
    let product = current.multipliedReportingOverflow(by: permille)
    guard !product.overflow else { return Int.max }
    return product.partialValue / 1_000
  }
}
