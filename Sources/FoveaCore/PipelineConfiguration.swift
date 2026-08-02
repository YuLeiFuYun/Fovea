import AkashicCore
import Foundation
import FoveaStorage
import ImageCraftCore

/// ``FoveaPipeline`` 的运行资源、重试、缓存与并发限制。

public struct PipelineConfiguration: Codable, Hashable, Sendable {
    private static let maximumMemoryCostLimit = 4 * 1024 * 1024 * 1024
    private static let maximumTransportByteLimit = 1024 * 1024 * 1024
    private static let maximumFetchConcurrency = 256
    private static let maximumDecodeConcurrency = 64
    private static let maximumDecodeWorkingSetLimit = 8 * 1024 * 1024 * 1024
    private static let maximumQueueLimit = 1_000_000

    /// 当前序列化配置模式版本。
    public static let currentSchemaVersion: UInt16 = 1

    /// 随此配置编码的模式版本。
    public let schemaVersion: UInt16
    /// 渲染内存缓存的字节成本上限。
    public let memoryCostLimit: Int
    /// 元数据与解码图像的安全硬限制。
    public let decodeLimits: DecodeLimits
    /// 有界传输重试策略。
    public let transportRetryPolicy: TransportRetryPolicy
    /// 管线全局的有界陈旧回退策略。
    public let staleFallbackPolicy: StaleFallbackPolicy
    /// 单个响应允许接收的最大编码字节数。
    public let maximumTransportBytes: Int
    /// 响应暂存切换到磁盘前的字节阈值。
    public let transportMemoryThreshold: Int
    /// 同时准入的最大传输执行数。
    public let maximumConcurrentFetches: Int
    /// 同时准入的最大解码操作数。
    public let maximumConcurrentDecodes: Int
    /// 估算解码工作集总量的最大值。
    public let maximumDecodeWorkingSetBytes: Int
    /// 等待准入的最大获取任务数。
    public let maximumQueuedFetches: Int
    /// 等待准入的最大解码任务数。
    public let maximumQueuedDecodes: Int
    /// 管线最多保留的命名空间撤销状态数。
    public let maximumTrackedNamespaces: Int

    /// 创建配置，并将每项资源限制钳制到安全运行范围。
    public init(
        memoryCostLimit: Int = 64 * 1024 * 1024,
        decodeLimits: DecodeLimits = .coreV1,
        transportRetryPolicy: TransportRetryPolicy = .current,
        staleFallbackPolicy: StaleFallbackPolicy = .disabled,
        maximumTransportBytes: Int = 64 * 1024 * 1024,
        transportMemoryThreshold: Int = 1024 * 1024,
        maximumConcurrentFetches: Int = 6,
        maximumConcurrentDecodes: Int = 2,
        maximumDecodeWorkingSetBytes: Int = 192 * 1024 * 1024,
        maximumQueuedFetches: Int = 512,
        maximumQueuedDecodes: Int = 512,
        maximumTrackedNamespaces: Int = 4_096
    ) {
        self.schemaVersion = PipelineConfiguration.currentSchemaVersion
        self.memoryCostLimit = min(Self.maximumMemoryCostLimit, max(1, memoryCostLimit))
        self.decodeLimits = decodeLimits
        self.transportRetryPolicy = transportRetryPolicy
        self.staleFallbackPolicy = staleFallbackPolicy
        self.maximumTransportBytes = min(
            Self.maximumTransportByteLimit,
            max(1, maximumTransportBytes)
        )
        self.transportMemoryThreshold = min(
            self.maximumTransportBytes,
            max(1, transportMemoryThreshold)
        )
        self.maximumConcurrentFetches = min(
            Self.maximumFetchConcurrency,
            max(1, maximumConcurrentFetches)
        )
        self.maximumConcurrentDecodes = min(
            Self.maximumDecodeConcurrency,
            max(1, maximumConcurrentDecodes)
        )
        self.maximumDecodeWorkingSetBytes = min(
            Self.maximumDecodeWorkingSetLimit,
            max(1, maximumDecodeWorkingSetBytes)
        )
        self.maximumQueuedFetches = min(
            Self.maximumQueueLimit,
            max(0, maximumQueuedFetches)
        )
        self.maximumQueuedDecodes = min(
            Self.maximumQueueLimit,
            max(0, maximumQueuedDecodes)
        )
        self.maximumTrackedNamespaces = min(
            NamespaceStorageLimits.maximumTrackedNamespaces, max(1, maximumTrackedNamespaces))
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case memoryCostLimit
        case decodeLimits
        case transportRetryPolicy
        case staleFallbackPolicy
        case maximumTransportBytes
        case transportMemoryThreshold
        case maximumConcurrentFetches
        case maximumConcurrentDecodes
        case maximumDecodeWorkingSetBytes
        case maximumQueuedFetches
        case maximumQueuedDecodes
        case maximumTrackedNamespaces
    }

    /// 只解码当前模式，并拒绝无效的持久化资源限制。
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(UInt16.self, forKey: .schemaVersion)
        let memoryCostLimit = try values.decode(Int.self, forKey: .memoryCostLimit)
        let decodeLimits = try values.decode(DecodeLimits.self, forKey: .decodeLimits)
        let transportRetryPolicy = try values.decode(
            TransportRetryPolicy.self,
            forKey: .transportRetryPolicy
        )
        let staleFallbackPolicy = try values.decode(
            StaleFallbackPolicy.self,
            forKey: .staleFallbackPolicy
        )
        let maximumTransportBytes = try values.decode(Int.self, forKey: .maximumTransportBytes)
        let transportMemoryThreshold = try values.decode(
            Int.self,
            forKey: .transportMemoryThreshold
        )
        let maximumConcurrentFetches = try values.decode(
            Int.self,
            forKey: .maximumConcurrentFetches
        )
        let maximumConcurrentDecodes = try values.decode(
            Int.self,
            forKey: .maximumConcurrentDecodes
        )
        let maximumDecodeWorkingSetBytes =
            try values.decodeIfPresent(
                Int.self,
                forKey: .maximumDecodeWorkingSetBytes
            ) ?? 192 * 1024 * 1024
        let maximumQueuedFetches = try values.decode(Int.self, forKey: .maximumQueuedFetches)
        let maximumQueuedDecodes = try values.decode(Int.self, forKey: .maximumQueuedDecodes)
        let maximumTrackedNamespaces =
            try values.decodeIfPresent(
                Int.self,
                forKey: .maximumTrackedNamespaces
            ) ?? 4_096

        guard schemaVersion == PipelineConfiguration.currentSchemaVersion,
            (1...Self.maximumMemoryCostLimit).contains(memoryCostLimit),
            (1...Self.maximumTransportByteLimit).contains(maximumTransportBytes),
            transportMemoryThreshold > 0,
            transportMemoryThreshold <= maximumTransportBytes,
            (1...Self.maximumFetchConcurrency).contains(maximumConcurrentFetches),
            (1...Self.maximumDecodeConcurrency).contains(maximumConcurrentDecodes),
            (1...Self.maximumDecodeWorkingSetLimit).contains(maximumDecodeWorkingSetBytes),
            (0...Self.maximumQueueLimit).contains(maximumQueuedFetches),
            (0...Self.maximumQueueLimit).contains(maximumQueuedDecodes),
            (1...NamespaceStorageLimits.maximumTrackedNamespaces).contains(maximumTrackedNamespaces)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription:
                    "Pipeline configuration has an unsupported schema or invalid resource limit."
            )
        }

        self.schemaVersion = schemaVersion
        self.memoryCostLimit = memoryCostLimit
        self.decodeLimits = decodeLimits
        self.transportRetryPolicy = transportRetryPolicy
        self.staleFallbackPolicy = staleFallbackPolicy
        self.maximumTransportBytes = maximumTransportBytes
        self.transportMemoryThreshold = transportMemoryThreshold
        self.maximumConcurrentFetches = maximumConcurrentFetches
        self.maximumConcurrentDecodes = maximumConcurrentDecodes
        self.maximumDecodeWorkingSetBytes = maximumDecodeWorkingSetBytes
        self.maximumQueuedFetches = maximumQueuedFetches
        self.maximumQueuedDecodes = maximumQueuedDecodes
        self.maximumTrackedNamespaces = maximumTrackedNamespaces
    }

    /// 使用当前模式编码全部语义与运行字段。
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(memoryCostLimit, forKey: .memoryCostLimit)
        try values.encode(decodeLimits, forKey: .decodeLimits)
        try values.encode(transportRetryPolicy, forKey: .transportRetryPolicy)
        try values.encode(staleFallbackPolicy, forKey: .staleFallbackPolicy)
        try values.encode(maximumTransportBytes, forKey: .maximumTransportBytes)
        try values.encode(transportMemoryThreshold, forKey: .transportMemoryThreshold)
        try values.encode(maximumConcurrentFetches, forKey: .maximumConcurrentFetches)
        try values.encode(maximumConcurrentDecodes, forKey: .maximumConcurrentDecodes)
        try values.encode(maximumDecodeWorkingSetBytes, forKey: .maximumDecodeWorkingSetBytes)
        try values.encode(maximumQueuedFetches, forKey: .maximumQueuedFetches)
        try values.encode(maximumQueuedDecodes, forKey: .maximumQueuedDecodes)
        try values.encode(maximumTrackedNamespaces, forKey: .maximumTrackedNamespaces)
    }

    /// 参与持久身份、会影响输出语义的指纹。
    public var semanticFingerprint: String {
        fingerprint(domain: "pipeline-semantic-v1", fields: semanticFields)
    }

    /// 同时覆盖语义与运行配置的指纹。
    public var fullFingerprint: String {
        fingerprint(domain: "pipeline-full-v1", fields: semanticFields + operationalFields)
    }

    package var transportPolicyFingerprint: String {
        fingerprint(
            domain: "transport-policy-v1",
            fields: [
                transportRetryPolicy.fingerprint,
                "maximumTransportBytes:\(maximumTransportBytes)",
                "staleFallback.enabled:\(staleFallbackPolicy.isEnabled)",
                "staleFallback.maximumSeconds:\(staleFallbackPolicy.maximumStalenessSeconds)",
            ]
        )
    }

    private var semanticFields: [String] {
        [
            "schemaVersion:\(schemaVersion)",
            "decode.maximumEncodedBytes:\(decodeLimits.maximumEncodedBytes)",
            "decode.maximumDimension:\(decodeLimits.maximumDimension)",
            "decode.maximumPixelCount:\(decodeLimits.maximumPixelCount)",
            "decode.maximumFrameCount:\(decodeLimits.maximumFrameCount)",
            "decode.maximumMetadataBytes:\(decodeLimits.maximumMetadataBytes)",
            "decode.maximumAuxiliaryAttachments:\(decodeLimits.maximumAuxiliaryAttachments)",
            "decode.allowedFormats:\(decodeLimits.allowedFormats.map(\.rawValue).sorted().joined(separator: ","))",
            "maximumTransportBytes:\(maximumTransportBytes)",
        ]
    }

    private var operationalFields: [String] {
        [
            "memoryCostLimit:\(memoryCostLimit)",
            "transportMemoryThreshold:\(transportMemoryThreshold)",
            "maximumConcurrentFetches:\(maximumConcurrentFetches)",
            "maximumConcurrentDecodes:\(maximumConcurrentDecodes)",
            "maximumDecodeWorkingSetBytes:\(maximumDecodeWorkingSetBytes)",
            "maximumQueuedFetches:\(maximumQueuedFetches)",
            "maximumQueuedDecodes:\(maximumQueuedDecodes)",
            "maximumTrackedNamespaces:\(maximumTrackedNamespaces)",
            "retry:\(transportRetryPolicy.fingerprint)",
        ]
    }

    private func fingerprint(domain: String, fields: [String]) -> String {
        var data = Data(domain.utf8)
        data.append(0)
        for field in fields {
            data.append(contentsOf: field.utf8)
            data.append(0)
        }
        return data.sha256Hex
    }
}
