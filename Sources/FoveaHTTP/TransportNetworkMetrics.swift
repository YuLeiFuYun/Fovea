import Foundation

/// 网络事务指标与诊断投影共享的有限表示域。
///
/// 这些值只定义可安全表示和解码的绝对上界，不是 URLSession 的运行配置。
package enum TransportNetworkMetricLimits {
    package static let maximumCount = 4_096
    package static let maximumDurationNanoseconds: UInt64 = 86_400_000_000_000
    package static let maximumDecodedProtocolCandidates = 64
    package static let maximumRetainedProtocolNames = 8
    package static let maximumProtocolNameBytes = 16
}

/// URLSession 任务与事务指标的有界、脱敏摘要。
public struct TransportNetworkMetrics: Codable, Hashable, Sendable {
    private static let maximumCount = TransportNetworkMetricLimits.maximumCount
    private static let maximumDurationNanoseconds = TransportNetworkMetricLimits
        .maximumDurationNanoseconds
    private static let maximumDecodedProtocolCandidates = TransportNetworkMetricLimits
        .maximumDecodedProtocolCandidates
    private static let maximumRetainedProtocolNames = TransportNetworkMetricLimits
        .maximumRetainedProtocolNames
    private static let maximumProtocolNameBytes = TransportNetworkMetricLimits
        .maximumProtocolNameBytes

    /// 完整 URLSession 任务区间，单位为纳秒。
    public let taskDurationNanoseconds: UInt64
    /// URL loading 事务数，包含重定向产生的事务。
    public let transactionCount: Int
    /// 脱敏后的协商协议名，例如 `h2`。
    public let negotiatedProtocolNames: [String]
    /// 复用既有连接的事务数。
    public let reusedConnectionCount: Int
    /// 被报告为使用代理的事务数。
    public let proxyConnectionCount: Int
    /// 使用蜂窝网络路径的事务数。
    public let cellularTransactionCount: Int
    /// 使用昂贵网络路径的事务数。
    public let expensiveTransactionCount: Int
    /// 使用受限网络路径的事务数。
    public let constrainedTransactionCount: Int
    /// 任务报告的重定向次数。
    public let redirectCount: Int?
    /// URLSession 可提供时的 DNS 查询总时长。
    public let domainLookupDurationNanoseconds: UInt64?
    /// URLSession 可提供时的连接建立总时长。
    public let connectionDurationNanoseconds: UInt64?
    /// URLSession 可提供时的 TLS 协商总时长。
    public let secureConnectionDurationNanoseconds: UInt64?
    /// URLSession 可提供时的请求发送总时长。
    public let requestDurationNanoseconds: UInt64?
    /// URLSession 可提供时，从 fetch 开始到首个响应字节的总时长。
    public let timeToFirstByteNanoseconds: UInt64?
    /// URLSession 可提供时的响应下载总时长。
    public let responseDurationNanoseconds: UInt64?

    /// 创建有界指标摘要；异常计数和时长会被钳制到诊断契约上限。
    public init(
        taskDurationNanoseconds: UInt64,
        transactionCount: Int,
        negotiatedProtocolNames: [String],
        reusedConnectionCount: Int,
        proxyConnectionCount: Int,
        cellularTransactionCount: Int,
        expensiveTransactionCount: Int,
        constrainedTransactionCount: Int,
        redirectCount: Int? = nil,
        domainLookupDurationNanoseconds: UInt64? = nil,
        connectionDurationNanoseconds: UInt64? = nil,
        secureConnectionDurationNanoseconds: UInt64? = nil,
        requestDurationNanoseconds: UInt64? = nil,
        timeToFirstByteNanoseconds: UInt64? = nil,
        responseDurationNanoseconds: UInt64? = nil
    ) {
        self.taskDurationNanoseconds = Self.boundedDuration(taskDurationNanoseconds)
        self.transactionCount = Self.boundedCount(transactionCount)
        self.negotiatedProtocolNames = Self.sanitizedProtocolNames(negotiatedProtocolNames)
        self.reusedConnectionCount = Self.boundedCount(reusedConnectionCount)
        self.proxyConnectionCount = Self.boundedCount(proxyConnectionCount)
        self.cellularTransactionCount = Self.boundedCount(cellularTransactionCount)
        self.expensiveTransactionCount = Self.boundedCount(expensiveTransactionCount)
        self.constrainedTransactionCount = Self.boundedCount(constrainedTransactionCount)
        self.redirectCount = redirectCount.map(Self.boundedCount)
        self.domainLookupDurationNanoseconds = Self.boundedDuration(
            domainLookupDurationNanoseconds
        )
        self.connectionDurationNanoseconds = Self.boundedDuration(
            connectionDurationNanoseconds
        )
        self.secureConnectionDurationNanoseconds = Self.boundedDuration(
            secureConnectionDurationNanoseconds
        )
        self.requestDurationNanoseconds = Self.boundedDuration(requestDurationNanoseconds)
        self.timeToFirstByteNanoseconds = Self.boundedDuration(timeToFirstByteNanoseconds)
        self.responseDurationNanoseconds = Self.boundedDuration(responseDurationNanoseconds)
    }

    private enum CodingKeys: String, CodingKey {
        case taskDurationNanoseconds
        case transactionCount
        case negotiatedProtocolNames
        case reusedConnectionCount
        case proxyConnectionCount
        case cellularTransactionCount
        case expensiveTransactionCount
        case constrainedTransactionCount
        case redirectCount
        case domainLookupDurationNanoseconds
        case connectionDurationNanoseconds
        case secureConnectionDurationNanoseconds
        case requestDurationNanoseconds
        case timeToFirstByteNanoseconds
        case responseDurationNanoseconds
    }

    private struct BoundedProtocolNames: Decodable {
        let values: [String]

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var values: [String] = []
            values.reserveCapacity(min(container.count ?? 0, maximumDecodedProtocolCandidates))
            while !container.isAtEnd {
                guard values.count < maximumDecodedProtocolCandidates else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "协商协议候选数量超过诊断上限"
                    )
                }
                values.append(try container.decode(String.self))
            }
            self.values = values
        }
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            taskDurationNanoseconds: try values.decode(
                UInt64.self, forKey: .taskDurationNanoseconds),
            transactionCount: try values.decode(Int.self, forKey: .transactionCount),
            negotiatedProtocolNames: try values.decode(
                BoundedProtocolNames.self,
                forKey: .negotiatedProtocolNames
            ).values,
            reusedConnectionCount: try values.decode(Int.self, forKey: .reusedConnectionCount),
            proxyConnectionCount: try values.decode(Int.self, forKey: .proxyConnectionCount),
            cellularTransactionCount: try values.decode(
                Int.self, forKey: .cellularTransactionCount),
            expensiveTransactionCount: try values.decode(
                Int.self, forKey: .expensiveTransactionCount),
            constrainedTransactionCount: try values.decode(
                Int.self,
                forKey: .constrainedTransactionCount
            ),
            redirectCount: try values.decodeIfPresent(Int.self, forKey: .redirectCount),
            domainLookupDurationNanoseconds: try values.decodeIfPresent(
                UInt64.self,
                forKey: .domainLookupDurationNanoseconds
            ),
            connectionDurationNanoseconds: try values.decodeIfPresent(
                UInt64.self,
                forKey: .connectionDurationNanoseconds
            ),
            secureConnectionDurationNanoseconds: try values.decodeIfPresent(
                UInt64.self,
                forKey: .secureConnectionDurationNanoseconds
            ),
            requestDurationNanoseconds: try values.decodeIfPresent(
                UInt64.self,
                forKey: .requestDurationNanoseconds
            ),
            timeToFirstByteNanoseconds: try values.decodeIfPresent(
                UInt64.self,
                forKey: .timeToFirstByteNanoseconds
            ),
            responseDurationNanoseconds: try values.decodeIfPresent(
                UInt64.self,
                forKey: .responseDurationNanoseconds
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(taskDurationNanoseconds, forKey: .taskDurationNanoseconds)
        try values.encode(transactionCount, forKey: .transactionCount)
        try values.encode(negotiatedProtocolNames, forKey: .negotiatedProtocolNames)
        try values.encode(reusedConnectionCount, forKey: .reusedConnectionCount)
        try values.encode(proxyConnectionCount, forKey: .proxyConnectionCount)
        try values.encode(cellularTransactionCount, forKey: .cellularTransactionCount)
        try values.encode(expensiveTransactionCount, forKey: .expensiveTransactionCount)
        try values.encode(constrainedTransactionCount, forKey: .constrainedTransactionCount)
        try values.encodeIfPresent(redirectCount, forKey: .redirectCount)
        try values.encodeIfPresent(
            domainLookupDurationNanoseconds,
            forKey: .domainLookupDurationNanoseconds
        )
        try values.encodeIfPresent(
            connectionDurationNanoseconds,
            forKey: .connectionDurationNanoseconds
        )
        try values.encodeIfPresent(
            secureConnectionDurationNanoseconds,
            forKey: .secureConnectionDurationNanoseconds
        )
        try values.encodeIfPresent(requestDurationNanoseconds, forKey: .requestDurationNanoseconds)
        try values.encodeIfPresent(timeToFirstByteNanoseconds, forKey: .timeToFirstByteNanoseconds)
        try values.encodeIfPresent(
            responseDurationNanoseconds, forKey: .responseDurationNanoseconds)
    }

    private static func boundedCount(_ value: Int) -> Int {
        min(max(0, value), maximumCount)
    }

    private static func boundedDuration(_ value: UInt64) -> UInt64 {
        min(value, maximumDurationNanoseconds)
    }

    private static func boundedDuration(_ value: UInt64?) -> UInt64? {
        value.map(boundedDuration)
    }

    private static func sanitizedProtocolNames(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values.prefix(maximumDecodedProtocolCandidates) {
            let normalized = value.lowercased()
            let bytes = normalized.utf8
            guard !bytes.isEmpty, bytes.count <= maximumProtocolNameBytes,
                bytes.allSatisfy({ byte in
                    (48...57).contains(byte) || (97...122).contains(byte)
                        || byte == 45 || byte == 46 || byte == 47 || byte == 95
                })
            else { continue }
            if !result.contains(normalized) { result.append(normalized) }
            if result.count == maximumRetainedProtocolNames { break }
        }
        return result
    }
}
