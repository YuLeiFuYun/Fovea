import Foundation
import ImageCraftCore

/// Fovea 响应式目标解析的稳定失败类型。
public enum TargetGeometryError: Error, Equatable, Sendable {
    case invalidTarget
    case limitExceeded
}

/// 控制已解析目标是否可以进入渲染内存缓存。

public enum RenderCacheAdmission: String, Codable, Hashable, Sendable {
    /// 几何仍是临时值，不得写入渲染内存缓存。
    case transient
    /// 几何已足够稳定，可以写入渲染内存缓存。
    case stable
}

/// 约束响应式图像目标的超采样与尺寸迟滞。

public struct TargetGeometryPolicy: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 3
    private static let maximumBucketStep = 65_536
    private static let maximumRelativeBucketPermille = 500
    private static let maximumHysteresisPermille = 1_000
    private static let maximumSupportedDimension = 65_536
    private static let maximumSupportedPixelCount = 1_000_000_000

    /// 策略的序列化模式版本。
    public let schemaVersion: UInt16
    /// 小尺寸线性量化以及大尺寸最小增量使用的像素步长。
    public let bucketStep: Int
    /// 大于阈值后，每个几何桶相对前一桶至少增长的千分比；零表示只使用线性桶。
    public let relativeBucketPermille: Int
    /// 启用几何桶的原始像素阈值。
    public let relativeBucketThreshold: Int
    /// 向上调整尺寸的千分比迟滞阈值。
    public let growthHysteresisPermille: Int
    /// 向下调整尺寸的千分比迟滞阈值。
    public let shrinkHysteresisPermille: Int
    /// 允许的最大解析维度。
    public let maximumDimension: Int
    /// 允许的最大解析像素总数。
    public let maximumPixelCount: Int

    /// 创建归一化目标几何策略。
    public init(
        bucketStep: Int = 16,
        relativeBucketPermille: Int = 64,
        relativeBucketThreshold: Int = 256,
        growthHysteresisPermille: Int = 125,
        shrinkHysteresisPermille: Int = 250,
        maximumDimension: Int = 16_384,
        maximumPixelCount: Int = 100_000_000
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.bucketStep = min(Self.maximumBucketStep, max(1, bucketStep))
        self.relativeBucketPermille = min(
            Self.maximumRelativeBucketPermille,
            max(0, relativeBucketPermille)
        )
        self.relativeBucketThreshold = min(
            Self.maximumSupportedDimension,
            max(self.bucketStep, relativeBucketThreshold)
        )
        self.growthHysteresisPermille = min(
            Self.maximumHysteresisPermille,
            max(0, growthHysteresisPermille)
        )
        self.shrinkHysteresisPermille = min(
            Self.maximumHysteresisPermille,
            max(0, shrinkHysteresisPermille)
        )
        self.maximumDimension = min(
            Self.maximumSupportedDimension,
            max(1, maximumDimension)
        )
        self.maximumPixelCount = min(
            Self.maximumSupportedPixelCount,
            max(1, maximumPixelCount)
        )
    }

    /// 当前响应式几何配置。
    public static let current = TargetGeometryPolicy()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case bucketStep
        case relativeBucketPermille
        case relativeBucketThreshold
        case growthHysteresisPermille
        case shrinkHysteresisPermille
        case maximumDimension
        case maximumPixelCount
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(UInt16.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Target geometry policy schema is unsupported."
            )
        }
        let bucketStep = try values.decode(Int.self, forKey: .bucketStep)
        let relativeBucketPermille = try values.decode(
            Int.self,
            forKey: .relativeBucketPermille
        )
        let relativeBucketThreshold = try values.decode(
            Int.self,
            forKey: .relativeBucketThreshold
        )
        let growthHysteresisPermille = try values.decode(
            Int.self,
            forKey: .growthHysteresisPermille
        )
        let shrinkHysteresisPermille = try values.decode(
            Int.self,
            forKey: .shrinkHysteresisPermille
        )
        let maximumDimension = try values.decode(Int.self, forKey: .maximumDimension)
        let maximumPixelCount = try values.decode(Int.self, forKey: .maximumPixelCount)
        guard schemaVersion == Self.currentSchemaVersion,
            (1...Self.maximumBucketStep).contains(bucketStep),
            (0...Self.maximumRelativeBucketPermille).contains(relativeBucketPermille),
            (bucketStep...Self.maximumSupportedDimension).contains(relativeBucketThreshold),
            (0...Self.maximumHysteresisPermille).contains(growthHysteresisPermille),
            (0...Self.maximumHysteresisPermille).contains(shrinkHysteresisPermille),
            (1...Self.maximumSupportedDimension).contains(maximumDimension),
            (1...Self.maximumSupportedPixelCount).contains(maximumPixelCount)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription:
                    "Target geometry policy has an unsupported schema or invalid limit."
            )
        }
        self.schemaVersion = schemaVersion
        self.bucketStep = bucketStep
        self.relativeBucketPermille = relativeBucketPermille
        self.relativeBucketThreshold = relativeBucketThreshold
        self.growthHysteresisPermille = growthHysteresisPermille
        self.shrinkHysteresisPermille = shrinkHysteresisPermille
        self.maximumDimension = maximumDimension
        self.maximumPixelCount = maximumPixelCount
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(bucketStep, forKey: .bucketStep)
        try values.encode(relativeBucketPermille, forKey: .relativeBucketPermille)
        try values.encode(relativeBucketThreshold, forKey: .relativeBucketThreshold)
        try values.encode(growthHysteresisPermille, forKey: .growthHysteresisPermille)
        try values.encode(shrinkHysteresisPermille, forKey: .shrinkHysteresisPermille)
        try values.encode(maximumDimension, forKey: .maximumDimension)
        try values.encode(maximumPixelCount, forKey: .maximumPixelCount)
    }

    /// 用于缓存与解码语义的稳定身份字符串。
    public var fingerprint: String {
        [
            "geometry-v\(schemaVersion)",
            "bucket:\(bucketStep)",
            "relative:\(relativeBucketPermille)",
            "relative-threshold:\(relativeBucketThreshold)",
            "grow:\(growthHysteresisPermille)",
            "shrink:\(shrinkHysteresisPermille)",
            "dimension:\(maximumDimension)",
            "pixels:\(maximumPixelCount)",
        ].joined(separator: "|")
    }
}

/// 规范目标像素尺寸与缓存准入决定。

public struct ResolvedImageTarget: Codable, Hashable, Sendable {
    /// 规范目标像素。
    public let pixels: TargetPixels
    /// 解析目标时使用的几何规则。
    public let contentMode: ImageContentMode
    /// 解析期间使用的稳定策略身份。
    public let geometryPolicyFingerprint: String
    /// 该目标是否可以进入渲染内存缓存。
    public let cacheAdmission: RenderCacheAdmission

    /// 创建带显式缓存准入语义的已解析目标。
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

/// 将点尺寸与显示缩放解析为稳定目标像素。

public struct TargetGeometryResolver: Sendable {
    /// 控制分桶、迟滞与硬限制的不可变策略。
    public let policy: TargetGeometryPolicy
    private var current: ResolvedImageTarget?

    /// 创建不带历史几何状态的解析器。
    public init(policy: TargetGeometryPolicy = .current) {
        self.policy = policy
    }

    /// 清除尺寸迟滞状态。
    public mutating func reset() {
        current = nil
    }

    /// 将点尺寸解析为有界目标像素；布局为零时返回 `nil`。
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
            throw TargetGeometryError.invalidTarget
        }
        guard widthPoints > 0, heightPoints > 0 else { return nil }

        let rawWidth = try pixelExtent(points: widthPoints, scale: scale)
        let rawHeight = try pixelExtent(points: heightPoints, scale: scale)
        guard rawWidth <= policy.maximumDimension, rawHeight <= policy.maximumDimension else {
            throw TargetGeometryError.limitExceeded
        }
        let cacheAdmission: RenderCacheAdmission = isStable ? .stable : .transient
        let resolvedPixels: TargetPixels
        if let current,
            current.contentMode == contentMode,
            current.cacheAdmission == cacheAdmission,
            remainsInsideHysteresis(
                rawWidth: rawWidth,
                rawHeight: rawHeight,
                current: current.pixels
            )
        {
            resolvedPixels = current.pixels
        } else if isStable {
            // 稳定布局不再承担“减少中间缓存身份”的职责。使用精确像素可避免
            // 几何桶把最终长期表征系统性放大；transient -> stable 必须重新解析。
            resolvedPixels = try validatedPixels(width: rawWidth, height: rawHeight)
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
            cacheAdmission: cacheAdmission
        )
        current = resolved
        return resolved
    }

    private func pixelExtent(points: Double, scale: Double) throws -> Int {
        let product = points * scale
        guard product.isFinite, product > 0, product <= Double(Int.max) else {
            throw TargetGeometryError.limitExceeded
        }
        return max(1, Int(ceil(product)))
    }

    private func bucket(_ value: Int) -> Int {
        let linear = linearBucket(value)
        guard policy.relativeBucketPermille > 0,
            value > policy.relativeBucketThreshold
        else { return linear }

        var candidate = linearBucket(policy.relativeBucketThreshold)
        while candidate < value {
            let relativeProduct = candidate.multipliedReportingOverflow(
                by: policy.relativeBucketPermille
            )
            guard !relativeProduct.overflow else { return Int.max }
            let relativeIncrement = max(
                1,
                (relativeProduct.partialValue + 999) / 1_000
            )
            let increment = max(policy.bucketStep, relativeIncrement)
            let advanced = candidate.addingReportingOverflow(increment)
            guard !advanced.overflow else { return Int.max }
            candidate = advanced.partialValue
        }
        return min(candidate, policy.maximumDimension)
    }

    private func linearBucket(_ value: Int) -> Int {
        let quotient = value.quotientAndRemainder(dividingBy: policy.bucketStep)
        guard quotient.remainder != 0 else { return value }
        let next = quotient.quotient.addingReportingOverflow(1)
        guard !next.overflow else { return Int.max }
        let result = next.partialValue.multipliedReportingOverflow(by: policy.bucketStep)
        return result.overflow ? Int.max : result.partialValue
    }

    private func validatedPixels(width: Int, height: Int) throws -> TargetPixels {
        guard width <= policy.maximumDimension, height <= policy.maximumDimension else {
            throw TargetGeometryError.limitExceeded
        }
        let product = width.multipliedReportingOverflow(by: height)
        guard !product.overflow, product.partialValue <= policy.maximumPixelCount else {
            throw TargetGeometryError.limitExceeded
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
