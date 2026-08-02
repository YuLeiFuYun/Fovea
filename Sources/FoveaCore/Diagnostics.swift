import AkashicCore
import Foundation
import FoveaHTTP
import FoveaStorage

/// 结构化管线诊断事件的有限词汇表。

public enum DiagnosticEventKind: String, Codable, Hashable, Sendable {
    case fetchQueued
    case fetchStarted
    case fetchJoined
    case fetchCompleted
    case fetchRetryScheduled
    case fetchCancelled
    case fetchFailed
    case originalEncodedHit
    case originalCommitPrepared
    case originalCommitPublished
    case renderedPublished
    case encodedHandoffStarted
    case encodedHandoffStored
    case encodedHandoffHit
    case encodedHandoffRejected
    case staleFallbackUsed
    case renderedMemoryHit
    case renderedMemoryPurged
    case decodeQueued
    case decodeJoined
    case decodeStarted
    case containerInspectionCompleted
    case imageSourceCreationCompleted
    case imageSourceTypeCompleted
    case imageFrameCountCompleted
    case imagePropertiesReadCompleted
    case probeValidationCompleted
    case probeCompleted
    case decodeWorkingSetReserved
    case decodeAdmissionRejected
    case rasterSourceCreationCompleted
    case rasterSourceTypeCompleted
    case rasterFrameCountCompleted
    case rasterImageCreationCompleted
    case rasterPostProcessingCompleted
    case rasterDecodeCompleted
    case decodeCompleted
    case decodeCancelled
    case decodeFailed
    case cacheReadFailed
    case cacheWriteFailed
    case responseAnomaly
    case namespaceRevoked
    case pipelineSucceeded
    case pipelineFailed
    case diagnosticsDropped
}

/// 图像管线发出的脱敏且基数有界的诊断记录。

public struct DiagnosticEvent: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 17

    private static let maximumByteCount = 1024 * 1024 * 1024
    private static let maximumItemCount = 1_000_000
    private static let maximumPixelCount = 1_000_000_000
    private static let maximumDimension = 65_536
    private static let maximumAttempt = TransportRetryLimits.maximumAttempts
    private static let maximumNetworkCount = TransportNetworkMetricLimits.maximumCount
    private static let maximumDurationNanoseconds = TransportNetworkMetricLimits
        .maximumDurationNanoseconds
    private static let maximumDecodedProtocolCandidates = TransportNetworkMetricLimits
        .maximumDecodedProtocolCandidates
    private static let maximumRetainedProtocolNames = TransportNetworkMetricLimits
        .maximumRetainedProtocolNames
    private static let maximumProtocolNameBytes = TransportNetworkMetricLimits
        .maximumProtocolNameBytes

    public let schemaVersion: UInt16
    public let kind: DiagnosticEventKind
    public let keyDigest: String?
    public let statusCode: Int?
    /// 字节数量；对象、事件或条目计数必须改用 ``itemCount``。
    public let byteCount: Int?
    /// 对象、事件或缓存条目计数；字节数量必须改用 ``byteCount``。
    public let itemCount: Int?
    public let sourcePixelCount: Int?
    public let outputPixelCount: Int?
    public let targetWidth: Int?
    public let targetHeight: Int?
    public let reason: String?
    public let attempt: Int?
    public let retryDelayNanoseconds: UInt64?
    public let durationNanoseconds: UInt64?
    public let transactionCount: Int?
    /// 已脱敏且有界的协议标识，例如 `h2` 或 `http/1.1`。
    public let networkProtocolNames: [String]?
    public let reusedConnectionCount: Int?
    public let proxyConnectionCount: Int?
    public let cellularTransactionCount: Int?
    public let expensiveTransactionCount: Int?
    public let constrainedTransactionCount: Int?
    public let redirectCount: Int?
    public let domainLookupDurationNanoseconds: UInt64?
    public let connectionDurationNanoseconds: UInt64?
    public let secureConnectionDurationNanoseconds: UInt64?
    public let requestDurationNanoseconds: UInt64?
    public let timeToFirstByteNanoseconds: UInt64?
    public let responseDurationNanoseconds: UInt64?
    public let requestedPriority: ImageRequestPriority?
    public let effectivePriority: ImageRequestPriority?
    public let failureCategory: PipelineFailure.Category?
    public let failureStage: PipelineFailure.Stage?
    public let failureDisposition: PipelineFailure.Disposition?

    public init(
        kind: DiagnosticEventKind,
        keyDigest: String? = nil,
        statusCode: Int? = nil,
        byteCount: Int? = nil,
        itemCount: Int? = nil,
        sourcePixelCount: Int? = nil,
        outputPixelCount: Int? = nil,
        targetWidth: Int? = nil,
        targetHeight: Int? = nil,
        reason: String? = nil,
        attempt: Int? = nil,
        retryDelayNanoseconds: UInt64? = nil,
        durationNanoseconds: UInt64? = nil,
        transactionCount: Int? = nil,
        networkProtocolNames: [String]? = nil,
        reusedConnectionCount: Int? = nil,
        proxyConnectionCount: Int? = nil,
        cellularTransactionCount: Int? = nil,
        expensiveTransactionCount: Int? = nil,
        constrainedTransactionCount: Int? = nil,
        redirectCount: Int? = nil,
        domainLookupDurationNanoseconds: UInt64? = nil,
        connectionDurationNanoseconds: UInt64? = nil,
        secureConnectionDurationNanoseconds: UInt64? = nil,
        requestDurationNanoseconds: UInt64? = nil,
        timeToFirstByteNanoseconds: UInt64? = nil,
        responseDurationNanoseconds: UInt64? = nil,
        requestedPriority: ImageRequestPriority? = nil,
        effectivePriority: ImageRequestPriority? = nil,
        failureCategory: PipelineFailure.Category? = nil,
        failureStage: PipelineFailure.Stage? = nil,
        failureDisposition: PipelineFailure.Disposition? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.kind = kind
        self.keyDigest = Self.validatedKeyDigest(keyDigest)
        self.statusCode = statusCode.flatMap { (100...599).contains($0) ? $0 : nil }
        self.byteCount = Self.nonnegative(byteCount, maximum: Self.maximumByteCount)
        self.itemCount = Self.nonnegative(itemCount, maximum: Self.maximumItemCount)
        self.sourcePixelCount = Self.positive(sourcePixelCount, maximum: Self.maximumPixelCount)
        self.outputPixelCount = Self.positive(outputPixelCount, maximum: Self.maximumPixelCount)
        self.targetWidth = Self.positive(targetWidth, maximum: Self.maximumDimension)
        self.targetHeight = Self.positive(targetHeight, maximum: Self.maximumDimension)
        self.reason = Self.sanitizedReasonCode(reason)
        self.attempt = Self.positive(attempt, maximum: Self.maximumAttempt)
        self.retryDelayNanoseconds = Self.boundedDuration(retryDelayNanoseconds)
        self.durationNanoseconds = Self.boundedDuration(durationNanoseconds)
        self.transactionCount = Self.nonnegative(
            transactionCount, maximum: Self.maximumNetworkCount)
        self.networkProtocolNames = Self.sanitizedProtocolNames(networkProtocolNames)
        self.reusedConnectionCount = Self.nonnegative(
            reusedConnectionCount, maximum: Self.maximumNetworkCount)
        self.proxyConnectionCount = Self.nonnegative(
            proxyConnectionCount, maximum: Self.maximumNetworkCount)
        self.cellularTransactionCount = Self.nonnegative(
            cellularTransactionCount, maximum: Self.maximumNetworkCount)
        self.expensiveTransactionCount = Self.nonnegative(
            expensiveTransactionCount, maximum: Self.maximumNetworkCount)
        self.constrainedTransactionCount = Self.nonnegative(
            constrainedTransactionCount, maximum: Self.maximumNetworkCount)
        self.redirectCount = Self.nonnegative(redirectCount, maximum: Self.maximumNetworkCount)
        self.domainLookupDurationNanoseconds = Self.boundedDuration(domainLookupDurationNanoseconds)
        self.connectionDurationNanoseconds = Self.boundedDuration(connectionDurationNanoseconds)
        self.secureConnectionDurationNanoseconds = Self.boundedDuration(
            secureConnectionDurationNanoseconds)
        self.requestDurationNanoseconds = Self.boundedDuration(requestDurationNanoseconds)
        self.timeToFirstByteNanoseconds = Self.boundedDuration(timeToFirstByteNanoseconds)
        self.responseDurationNanoseconds = Self.boundedDuration(responseDurationNanoseconds)
        self.requestedPriority = requestedPriority
        self.effectivePriority = effectivePriority
        self.failureCategory = failureCategory
        self.failureStage = failureStage
        self.failureDisposition = failureDisposition
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
                        debugDescription: "网络协议候选数量超过诊断上限"
                    )
                }
                values.append(try container.decode(String.self))
            }
            self.values = values
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case kind
        case keyDigest
        case statusCode
        case byteCount
        case itemCount
        case sourcePixelCount
        case outputPixelCount
        case targetWidth
        case targetHeight
        case reason
        case attempt
        case retryDelayNanoseconds
        case durationNanoseconds
        case transactionCount
        case networkProtocolNames
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
        case requestedPriority
        case effectivePriority
        case failureCategory
        case failureStage
        case failureDisposition
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(UInt16.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported diagnostic event schema"
            )
        }
        self.init(
            kind: try container.decode(DiagnosticEventKind.self, forKey: .kind),
            keyDigest: try container.decodeIfPresent(String.self, forKey: .keyDigest),
            statusCode: try container.decodeIfPresent(Int.self, forKey: .statusCode),
            byteCount: try container.decodeIfPresent(Int.self, forKey: .byteCount),
            itemCount: try container.decodeIfPresent(Int.self, forKey: .itemCount),
            sourcePixelCount: try container.decodeIfPresent(Int.self, forKey: .sourcePixelCount),
            outputPixelCount: try container.decodeIfPresent(Int.self, forKey: .outputPixelCount),
            targetWidth: try container.decodeIfPresent(Int.self, forKey: .targetWidth),
            targetHeight: try container.decodeIfPresent(Int.self, forKey: .targetHeight),
            reason: try container.decodeIfPresent(String.self, forKey: .reason),
            attempt: try container.decodeIfPresent(Int.self, forKey: .attempt),
            retryDelayNanoseconds: try container.decodeIfPresent(
                UInt64.self,
                forKey: .retryDelayNanoseconds
            ),
            durationNanoseconds: try container.decodeIfPresent(
                UInt64.self,
                forKey: .durationNanoseconds
            ),
            transactionCount: try container.decodeIfPresent(Int.self, forKey: .transactionCount),
            networkProtocolNames: try container.decodeIfPresent(
                BoundedProtocolNames.self,
                forKey: .networkProtocolNames
            )?.values,
            reusedConnectionCount: try container.decodeIfPresent(
                Int.self,
                forKey: .reusedConnectionCount
            ),
            proxyConnectionCount: try container.decodeIfPresent(
                Int.self,
                forKey: .proxyConnectionCount
            ),
            cellularTransactionCount: try container.decodeIfPresent(
                Int.self,
                forKey: .cellularTransactionCount
            ),
            expensiveTransactionCount: try container.decodeIfPresent(
                Int.self,
                forKey: .expensiveTransactionCount
            ),
            constrainedTransactionCount: try container.decodeIfPresent(
                Int.self,
                forKey: .constrainedTransactionCount
            ),
            redirectCount: try container.decodeIfPresent(Int.self, forKey: .redirectCount),
            domainLookupDurationNanoseconds: try container.decodeIfPresent(
                UInt64.self,
                forKey: .domainLookupDurationNanoseconds
            ),
            connectionDurationNanoseconds: try container.decodeIfPresent(
                UInt64.self,
                forKey: .connectionDurationNanoseconds
            ),
            secureConnectionDurationNanoseconds: try container.decodeIfPresent(
                UInt64.self,
                forKey: .secureConnectionDurationNanoseconds
            ),
            requestDurationNanoseconds: try container.decodeIfPresent(
                UInt64.self,
                forKey: .requestDurationNanoseconds
            ),
            timeToFirstByteNanoseconds: try container.decodeIfPresent(
                UInt64.self,
                forKey: .timeToFirstByteNanoseconds
            ),
            responseDurationNanoseconds: try container.decodeIfPresent(
                UInt64.self,
                forKey: .responseDurationNanoseconds
            ),
            requestedPriority: try container.decodeIfPresent(
                ImageRequestPriority.self,
                forKey: .requestedPriority
            ),
            effectivePriority: try container.decodeIfPresent(
                ImageRequestPriority.self,
                forKey: .effectivePriority
            ),
            failureCategory: try container.decodeIfPresent(
                PipelineFailure.Category.self,
                forKey: .failureCategory
            ),
            failureStage: try container.decodeIfPresent(
                PipelineFailure.Stage.self,
                forKey: .failureStage
            ),
            failureDisposition: try container.decodeIfPresent(
                PipelineFailure.Disposition.self,
                forKey: .failureDisposition
            )
        )
    }

    private static func validatedKeyDigest(_ value: String?) -> String? {
        guard let value, StoredContentIdentifier.isLowercaseSHA256(value) else { return nil }
        return value
    }

    private static func nonnegative(_ value: Int?, maximum: Int) -> Int? {
        value.flatMap { $0 >= 0 ? min($0, maximum) : nil }
    }

    private static func positive(_ value: Int?, maximum: Int) -> Int? {
        value.flatMap { $0 > 0 ? min($0, maximum) : nil }
    }

    private static func boundedDuration(_ value: UInt64?) -> UInt64? {
        value.map { min($0, maximumDurationNanoseconds) }
    }

    private static func sanitizedProtocolNames(_ values: [String]?) -> [String]? {
        guard let values else { return nil }
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
        return result.isEmpty ? nil : result
    }

    private static func sanitizedReasonCode(_ reason: String?) -> String? {
        guard let reason else { return nil }
        let bytes = reason.utf8
        guard !bytes.isEmpty, bytes.count <= 96,
            bytes.allSatisfy({ byte in
                (48...57).contains(byte) || (97...122).contains(byte) || byte == 45
            })
        else {
            return "invalid-reason-code"
        }
        return reason
    }

    package func replacingKeyDigest(_ keyDigest: String?) -> DiagnosticEvent {
        DiagnosticEvent(
            kind: kind,
            keyDigest: keyDigest,
            statusCode: statusCode,
            byteCount: byteCount,
            itemCount: itemCount,
            sourcePixelCount: sourcePixelCount,
            outputPixelCount: outputPixelCount,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            reason: reason,
            attempt: attempt,
            retryDelayNanoseconds: retryDelayNanoseconds,
            durationNanoseconds: durationNanoseconds,
            transactionCount: transactionCount,
            networkProtocolNames: networkProtocolNames,
            reusedConnectionCount: reusedConnectionCount,
            proxyConnectionCount: proxyConnectionCount,
            cellularTransactionCount: cellularTransactionCount,
            expensiveTransactionCount: expensiveTransactionCount,
            constrainedTransactionCount: constrainedTransactionCount,
            redirectCount: redirectCount,
            domainLookupDurationNanoseconds: domainLookupDurationNanoseconds,
            connectionDurationNanoseconds: connectionDurationNanoseconds,
            secureConnectionDurationNanoseconds: secureConnectionDurationNanoseconds,
            requestDurationNanoseconds: requestDurationNanoseconds,
            timeToFirstByteNanoseconds: timeToFirstByteNanoseconds,
            responseDurationNanoseconds: responseDurationNanoseconds,
            requestedPriority: requestedPriority,
            effectivePriority: effectivePriority,
            failureCategory: failureCategory,
            failureStage: failureStage,
            failureDisposition: failureDisposition
        )
    }
}
