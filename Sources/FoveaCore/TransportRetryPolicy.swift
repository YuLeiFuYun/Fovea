import Foundation

/// 传输重试状态机与诊断投影共享的绝对尝试次数表示域。
package enum TransportRetryLimits {
    package static let maximumAttempts = 8
}

/// 约束重试次数、延迟、抖动与额外响应字节。

public struct TransportRetryPolicy: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 2
    private static let maximumAttemptLimit = TransportRetryLimits.maximumAttempts
    private static let maximumBaseDelayLimit: UInt64 = 60_000_000_000
    private static let maximumDelayLimit: UInt64 = 300_000_000_000
    private static let maximumTotalDelayLimit: UInt64 = 900_000_000_000
    private static let maximumAdditionalResponseByteLimit = 1024 * 1024 * 1024

    public let schemaVersion: UInt16
    public let maximumAttempts: Int
    public let baseDelayNanoseconds: UInt64
    public let maximumDelayNanoseconds: UInt64
    public let maximumTotalDelayNanoseconds: UInt64
    public let maximumAdditionalResponseBytes: Int

    public init(
        maximumAttempts: Int = 2,
        baseDelayNanoseconds: UInt64 = 200_000_000,
        maximumDelayNanoseconds: UInt64 = 2_000_000_000,
        maximumTotalDelayNanoseconds: UInt64 = 5_000_000_000,
        maximumAdditionalResponseBytes: Int = 1 * 1024 * 1024
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.maximumAttempts = min(Self.maximumAttemptLimit, max(1, maximumAttempts))
        self.baseDelayNanoseconds = min(Self.maximumBaseDelayLimit, baseDelayNanoseconds)
        self.maximumDelayNanoseconds = min(
            Self.maximumDelayLimit,
            max(self.baseDelayNanoseconds, maximumDelayNanoseconds)
        )
        self.maximumTotalDelayNanoseconds = min(
            Self.maximumTotalDelayLimit,
            maximumTotalDelayNanoseconds
        )
        self.maximumAdditionalResponseBytes = min(
            Self.maximumAdditionalResponseByteLimit,
            max(0, maximumAdditionalResponseBytes)
        )
    }

    public static let current = TransportRetryPolicy()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case maximumAttempts
        case baseDelayNanoseconds
        case maximumDelayNanoseconds
        case maximumTotalDelayNanoseconds
        case maximumAdditionalResponseBytes
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(UInt16.self, forKey: .schemaVersion)
        let maximumAttempts = try values.decode(Int.self, forKey: .maximumAttempts)
        let baseDelayNanoseconds = try values.decode(UInt64.self, forKey: .baseDelayNanoseconds)
        let maximumDelayNanoseconds = try values.decode(
            UInt64.self,
            forKey: .maximumDelayNanoseconds
        )
        let maximumTotalDelayNanoseconds = try values.decode(
            UInt64.self,
            forKey: .maximumTotalDelayNanoseconds
        )
        let maximumAdditionalResponseBytes = try values.decode(
            Int.self,
            forKey: .maximumAdditionalResponseBytes
        )
        guard schemaVersion == Self.currentSchemaVersion,
            (1...Self.maximumAttemptLimit).contains(maximumAttempts),
            baseDelayNanoseconds <= Self.maximumBaseDelayLimit,
            maximumDelayNanoseconds >= baseDelayNanoseconds,
            maximumDelayNanoseconds <= Self.maximumDelayLimit,
            maximumTotalDelayNanoseconds <= Self.maximumTotalDelayLimit,
            (0...Self.maximumAdditionalResponseByteLimit).contains(maximumAdditionalResponseBytes)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .maximumAttempts,
                in: values,
                debugDescription:
                    "Retry policy contains an unsupported schema or invalid attempt, delay, or byte limit."
            )
        }
        self.schemaVersion = schemaVersion
        self.maximumAttempts = maximumAttempts
        self.baseDelayNanoseconds = baseDelayNanoseconds
        self.maximumDelayNanoseconds = maximumDelayNanoseconds
        self.maximumTotalDelayNanoseconds = maximumTotalDelayNanoseconds
        self.maximumAdditionalResponseBytes = maximumAdditionalResponseBytes
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(maximumAttempts, forKey: .maximumAttempts)
        try values.encode(baseDelayNanoseconds, forKey: .baseDelayNanoseconds)
        try values.encode(maximumDelayNanoseconds, forKey: .maximumDelayNanoseconds)
        try values.encode(maximumTotalDelayNanoseconds, forKey: .maximumTotalDelayNanoseconds)
        try values.encode(maximumAdditionalResponseBytes, forKey: .maximumAdditionalResponseBytes)
    }

    public var fingerprint: String {
        [
            "retry-v\(schemaVersion)",
            "attempts:\(maximumAttempts)",
            "base:\(baseDelayNanoseconds)",
            "max:\(maximumDelayNanoseconds)",
            "total:\(maximumTotalDelayNanoseconds)",
            "bytes:\(maximumAdditionalResponseBytes)",
            "jitter:full",
        ].joined(separator: "|")
    }

    /// 计算 capped exponential backoff 的 full-jitter 延迟。
    ///
    /// `jitterFractionPermille` 由注入的随机源给出 `0...1000`。服务端
    /// `Retry-After` 是协议下界，抖动不得把实际延迟降到该下界以下。
    package func delayNanoseconds(
        afterFailedAttempt failedAttempt: Int,
        retryAfterNanoseconds: UInt64?,
        jitterFractionPermille: Int
    ) -> UInt64 {
        let exponential = exponentialDelay(failedAttempt: failedAttempt)
        let fraction = min(1_000, max(0, jitterFractionPermille))
        let product = exponential.multipliedReportingOverflow(by: UInt64(fraction))
        let jittered = product.overflow ? exponential : product.partialValue / 1_000
        let serverMinimum = min(maximumDelayNanoseconds, retryAfterNanoseconds ?? 0)
        return max(serverMinimum, min(maximumDelayNanoseconds, jittered))
    }

    private func exponentialDelay(failedAttempt: Int) -> UInt64 {
        guard failedAttempt > 0, baseDelayNanoseconds > 0 else { return 0 }
        let shift = min(62, failedAttempt - 1)
        let multiplier = UInt64(1) << UInt64(shift)
        let product = baseDelayNanoseconds.multipliedReportingOverflow(by: multiplier)
        return product.overflow
            ? maximumDelayNanoseconds : min(maximumDelayNanoseconds, product.partialValue)
    }
}

package protocol RetrySleeping: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

package struct SystemRetrySleeper: RetrySleeping {
    package init() {}

    package func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

package protocol RetryJittering: Sendable {
    /// 返回 full jitter 使用的 `0...1000` 均匀比例。
    func fractionPermille() async -> Int
}

package actor SystemRetryJitter: RetryJittering {
    package init() {}

    package func fractionPermille() -> Int {
        Int.random(in: 0...1_000)
    }
}
