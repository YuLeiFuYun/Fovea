import AkashicCore
import Foundation
import FoveaStorage

/// 与一个 HTTP 表征关联的可缓存性决定。

public enum CacheDisposition: String, Codable, Hashable, Sendable {
    case reusable
    case noStore
    case privateNamespace
}

/// 将变体与编码内容关联的持久化 HTTP 表征元数据。

public struct RepresentationRecord: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 6

    public let recordSchemaVersion: UInt16
    public let securityNamespaceFingerprint: StorageNamespaceFingerprint
    public let namespaceGeneration: UInt64
    public let baseKeyDigest: String
    public let variantKeyDigest: String
    public let vary: HTTPVarySelection
    public let statusCode: Int
    public let requestTime: Date
    public let responseTime: Date
    public let responseDate: Date?
    public let expiresAt: Date?
    public let etag: String?
    public let lastModified: String?
    public let disposition: CacheDisposition
    /// origin 是否要求成功验证后才能复用任何陈旧内容。
    public let requiresRevalidation: Bool
    public let contentID: String
    public let payloadLength: Int
    public let contentType: String?

    public init(
        recordSchemaVersion: UInt16 = RepresentationRecord.currentSchemaVersion,
        securityNamespace: String,
        namespaceGeneration: UInt64,
        baseKeyDigest: String,
        variantKeyDigest: String,
        vary: HTTPVarySelection = .empty,
        statusCode: Int,
        requestTime: Date,
        responseTime: Date,
        responseDate: Date?,
        expiresAt: Date?,
        etag: String?,
        lastModified: String?,
        disposition: CacheDisposition,
        requiresRevalidation: Bool = false,
        contentID: String,
        payloadLength: Int,
        contentType: String?
    ) {
        self.recordSchemaVersion = recordSchemaVersion
        self.securityNamespaceFingerprint = StorageNamespaceFingerprint(
            namespace: securityNamespace)
        self.namespaceGeneration = namespaceGeneration
        self.baseKeyDigest = baseKeyDigest
        self.variantKeyDigest = variantKeyDigest
        self.vary = vary
        self.statusCode = statusCode
        self.requestTime = requestTime
        self.responseTime = responseTime
        self.responseDate = responseDate
        self.expiresAt = expiresAt
        self.etag = etag
        self.lastModified = lastModified
        self.disposition = disposition
        self.requiresRevalidation = requiresRevalidation
        self.contentID = contentID
        self.payloadLength = payloadLength
        self.contentType = contentType
    }

    private enum CodingKeys: String, CodingKey {
        case recordSchemaVersion
        case securityNamespaceFingerprint
        case namespaceGeneration
        case baseKeyDigest
        case variantKeyDigest
        case vary
        case statusCode
        case requestTime
        case responseTime
        case responseDate
        case expiresAt
        case etag
        case lastModified
        case disposition
        case requiresRevalidation
        case contentID
        case payloadLength
        case contentType
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.recordSchemaVersion = try values.decode(UInt16.self, forKey: .recordSchemaVersion)
        self.securityNamespaceFingerprint = try values.decode(
            StorageNamespaceFingerprint.self,
            forKey: .securityNamespaceFingerprint
        )
        self.namespaceGeneration = try values.decode(UInt64.self, forKey: .namespaceGeneration)
        self.baseKeyDigest = try values.decode(String.self, forKey: .baseKeyDigest)
        self.variantKeyDigest = try values.decode(String.self, forKey: .variantKeyDigest)
        self.vary = try values.decode(HTTPVarySelection.self, forKey: .vary)
        self.statusCode = try values.decode(Int.self, forKey: .statusCode)
        self.requestTime = try values.decode(Date.self, forKey: .requestTime)
        self.responseTime = try values.decode(Date.self, forKey: .responseTime)
        self.responseDate = try values.decodeIfPresent(Date.self, forKey: .responseDate)
        self.expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt)
        self.etag = try values.decodeIfPresent(String.self, forKey: .etag)
        self.lastModified = try values.decodeIfPresent(String.self, forKey: .lastModified)
        self.disposition = try values.decode(CacheDisposition.self, forKey: .disposition)
        self.requiresRevalidation = try values.decode(Bool.self, forKey: .requiresRevalidation)
        self.contentID = try values.decode(String.self, forKey: .contentID)
        self.payloadLength = try values.decode(Int.self, forKey: .payloadLength)
        self.contentType = try values.decodeIfPresent(String.self, forKey: .contentType)
        guard isValidPersistentRecord() else {
            throw DecodingError.dataCorruptedError(
                forKey: .recordSchemaVersion,
                in: values,
                debugDescription: "Representation record violates the supported persistent profile"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(recordSchemaVersion, forKey: .recordSchemaVersion)
        try values.encode(securityNamespaceFingerprint, forKey: .securityNamespaceFingerprint)
        try values.encode(namespaceGeneration, forKey: .namespaceGeneration)
        try values.encode(baseKeyDigest, forKey: .baseKeyDigest)
        try values.encode(variantKeyDigest, forKey: .variantKeyDigest)
        try values.encode(vary, forKey: .vary)
        try values.encode(statusCode, forKey: .statusCode)
        try values.encode(requestTime, forKey: .requestTime)
        try values.encode(responseTime, forKey: .responseTime)
        try values.encodeIfPresent(responseDate, forKey: .responseDate)
        try values.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try values.encodeIfPresent(etag, forKey: .etag)
        try values.encodeIfPresent(lastModified, forKey: .lastModified)
        try values.encode(disposition, forKey: .disposition)
        try values.encode(requiresRevalidation, forKey: .requiresRevalidation)
        try values.encode(contentID, forKey: .contentID)
        try values.encode(payloadLength, forKey: .payloadLength)
        try values.encodeIfPresent(contentType, forKey: .contentType)
    }

    package func isValidPersistentRecord(storedUnder key: String? = nil) -> Bool {
        guard recordSchemaVersion == Self.currentSchemaVersion,
            key.map({ $0 == variantKeyDigest }) ?? true,
            StoredContentIdentifier.isLowercaseSHA256(baseKeyDigest),
            StoredContentIdentifier.isLowercaseSHA256(variantKeyDigest),
            StoredContentIdentifier.byteCount(
                in: contentID,
                expectedByteCount: payloadLength
            ) != nil,
            payloadLength >= 0,
            100...599 ~= statusCode,
            requestTime.timeIntervalSinceReferenceDate.isFinite,
            responseTime.timeIntervalSinceReferenceDate.isFinite,
            responseDate?.timeIntervalSinceReferenceDate.isFinite ?? true,
            expiresAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
            Self.isValidOptionalField(etag),
            Self.isValidOptionalField(lastModified),
            Self.isValidOptionalField(contentType),
            let varyBytes = vary.persistentMetadataByteCount,
            varyBytes <= HTTPMetadataLimits.maximumHeaderBytes,
            persistentMetadataByteCount(varyBytes: varyBytes)
                <= HTTPMetadataLimits.maximumPersistentRecordBytes
        else { return false }
        return true
    }

    private static func isValidOptionalField(_ value: String?) -> Bool {
        value.map(HTTPMetadataLimits.isValidFieldValue) ?? true
    }

    private func persistentMetadataByteCount(varyBytes: Int) -> Int {
        let strings = [
            baseKeyDigest,
            variantKeyDigest,
            contentID,
            etag ?? "",
            lastModified ?? "",
            contentType ?? "",
        ]
        return strings.reduce(varyBytes + 128) { partial, value in
            let next = partial.addingReportingOverflow(value.utf8.count)
            return next.overflow ? Int.max : next.partialValue
        }
    }

    public func isFresh(at date: Date) -> Bool {
        guard disposition != .noStore, let expiresAt else { return false }
        return date < expiresAt
    }

    package var recencyDate: Date { responseDate ?? responseTime }
}

/// 查询并发布命名空间级 HTTP 表征记录。

public protocol RepresentationRecordStoring: Sendable {
    func records(
        for baseKeyDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async -> [RepresentationRecord]
    func put(_ record: RepresentationRecord) async throws
    func containsReference(
        to contentID: String,
        namespace: String,
        excludingVariantDigest: String?
    ) async -> Bool
    func remove(
        _ variantDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async throws
    func removeAll(namespace: String) async throws
}

/// 为表征存储补充记录删除与活动内容枚举能力。

public protocol RepresentationRecordMaintaining: AnyObject, RepresentationRecordStoring {
    func contentReferences() async -> Set<StoredContentReference>
}

/// 包内可选的精确 variant 索引能力。
///
/// 外部 store provider 不需要实现；FoveaCore 在能力缺失时回退到基础键候选扫描。
package protocol RepresentationRecordSnapshotLookingUp: RepresentationRecordStoring {
    /// 没有 durable mutation 时，返回 exact base/namespace/generation 下已持久化验证且 variant 唯一的候选。
    /// 返回 nil 表示调用方必须回退到 store actor，并执行完整防御性验证路径。
    func recordsSnapshot(
        for baseKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: UInt64
    ) -> [RepresentationRecord]?
}

package protocol RepresentationRecordExactLookingUp: RepresentationRecordStoring {
    /// 仅当 exact variant 是该 base/namespace/generation 下唯一候选时返回记录。
    /// 多候选必须由调用方回退到完整 HTTP Vary 选择，不能绕过显式 Vary 优先规则。
    func uniqueRecord(
        for variantDigest: String,
        baseKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: UInt64
    ) -> RepresentationRecord?
}
