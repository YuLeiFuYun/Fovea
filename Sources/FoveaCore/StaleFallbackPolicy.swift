import Foundation
import FoveaHTTP

/// 定义可重试失败是否以及可以在多长时间内回退到陈旧内容。

public struct StaleFallbackPolicy: Codable, Hashable, Sendable {
    private static let maximumStalenessLimit: UInt64 = 365 * 24 * 60 * 60

    public let isEnabled: Bool
    public let maximumStalenessSeconds: UInt64

    public init(
        isEnabled: Bool,
        maximumStalenessSeconds: UInt64 = 0
    ) {
        self.isEnabled = isEnabled
        self.maximumStalenessSeconds = min(
            Self.maximumStalenessLimit,
            maximumStalenessSeconds
        )
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case maximumStalenessSeconds
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        let maximumStalenessSeconds = try values.decode(
            UInt64.self,
            forKey: .maximumStalenessSeconds
        )
        guard maximumStalenessSeconds <= Self.maximumStalenessLimit else {
            throw DecodingError.dataCorruptedError(
                forKey: .maximumStalenessSeconds,
                in: values,
                debugDescription: "Stale fallback exceeds the supported bounded window."
            )
        }
        self.isEnabled = isEnabled
        self.maximumStalenessSeconds = maximumStalenessSeconds
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(maximumStalenessSeconds, forKey: .maximumStalenessSeconds)
    }

    public static let disabled = StaleFallbackPolicy(isEnabled: false)

    public static func networkResilient(
        maximumStalenessSeconds: UInt64
    ) -> StaleFallbackPolicy {
        StaleFallbackPolicy(
            isEnabled: true,
            maximumStalenessSeconds: maximumStalenessSeconds
        )
    }

    package func permits(
        record: RepresentationRecord,
        at date: Date,
        after failure: PipelineFailure
    ) -> Bool {
        guard isEnabled,
            record.disposition != .noStore,
            !record.requiresRevalidation,
            let expiresAt = record.expiresAt,
            date >= expiresAt,
            failure.disposition == .retryable
        else { return false }

        let permittedFailure: Bool
        switch failure.category {
        case .transport:
            permittedFailure = true
        case .http:
            if let statusCode = failure.statusCode {
                permittedFailure =
                    statusCode == 408 || statusCode == 425 || statusCode == 429
                    || (500...599).contains(statusCode)
            } else {
                permittedFailure = false
            }
        default:
            permittedFailure = false
        }
        guard permittedFailure else { return false }

        let staleness = date.timeIntervalSince(expiresAt)
        guard staleness.isFinite, staleness >= 0 else { return false }
        return staleness <= Double(maximumStalenessSeconds)
    }
}
