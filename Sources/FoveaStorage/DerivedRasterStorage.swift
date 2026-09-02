import AkashicCore
import Foundation

package enum DerivedRasterRecordError: Error, Equatable, Sendable {
    case invalidRecord
}

package enum DerivedRasterStoreError: Error, Equatable, Sendable {
    case writeBudgetExceeded(logicalWriteChargeBytes: Int, maximumWriteBytesPerWindow: Int)

    package var diagnosticReason: String {
        "derived-raster-global-write-budget"
    }

    package var logicalWriteChargeBytes: Int? {
        guard case .writeBudgetExceeded(let logicalWriteChargeBytes, _) = self else { return nil }
        return logicalWriteChargeBytes
    }
}

/// 从一个精确派生工件身份到不透明容器字节的持久 alias。
///
/// 该记录不是 HTTP 复用授权；FoveaCore 在加载前仍须应用当前表征与
/// 还必须通过 namespace-generation fence。
package struct DerivedRasterRecord: Codable, Hashable, Sendable {
    package static let currentSchemaVersion: UInt16 = 7

    package let schemaVersion: UInt16
    package let artifactKeyDigest: String
    package let baseKeyDigest: String
    package let variantKeyDigest: String
    package let namespaceFingerprint: StorageNamespaceFingerprint
    package let namespaceGeneration: UInt64
    package let containerContentID: String
    package let containerByteCount: Int
    package let formatIdentifier: String
    package let formatSemanticVersion: UInt16
    package let pixelLayoutFingerprint: String
    package let pixelDigestHex: String
    package let pixelWidth: Int
    package let pixelHeight: Int
    package let createdAt: Date

    package init(
        artifactKeyDigest: String,
        baseKeyDigest: String,
        variantKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: UInt64,
        containerContentID: String,
        containerByteCount: Int,
        formatIdentifier: String,
        formatSemanticVersion: UInt16,
        pixelLayoutFingerprint: String,
        pixelDigestHex: String,
        pixelWidth: Int,
        pixelHeight: Int,
        createdAt: Date
    ) throws {
        self.schemaVersion = Self.currentSchemaVersion
        self.artifactKeyDigest = artifactKeyDigest
        self.baseKeyDigest = baseKeyDigest
        self.variantKeyDigest = variantKeyDigest
        self.namespaceFingerprint = namespaceFingerprint
        self.namespaceGeneration = namespaceGeneration
        self.containerContentID = containerContentID
        self.containerByteCount = containerByteCount
        self.formatIdentifier = formatIdentifier
        self.formatSemanticVersion = formatSemanticVersion
        self.pixelLayoutFingerprint = pixelLayoutFingerprint
        self.pixelDigestHex = pixelDigestHex
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.createdAt = createdAt
        guard isValidPersistentRecord() else { throw DerivedRasterRecordError.invalidRecord }
    }

    package func isValidPersistentRecord(storedUnder key: String? = nil) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && key.map({ $0 == artifactKeyDigest }) ?? true
            && hasValidIdentityDigests
            && hasValidContainerIdentity
            && hasValidFormatMetadata
            && hasValidPixelGeometry
            && createdAt.timeIntervalSinceReferenceDate.isFinite
    }

    private var hasValidIdentityDigests: Bool {
        StoredContentIdentifier.isLowercaseSHA256(artifactKeyDigest)
            && StoredContentIdentifier.isLowercaseSHA256(baseKeyDigest)
            && StoredContentIdentifier.isLowercaseSHA256(variantKeyDigest)
            && StoredContentIdentifier.isLowercaseSHA256(pixelDigestHex)
    }

    private var hasValidContainerIdentity: Bool {
        containerByteCount > 0
            && containerByteCount <= 1_024 * 1_024 * 1_024
            && StoredContentIdentifier.byteCount(
                in: containerContentID,
                expectedByteCount: containerByteCount
            ) != nil
    }

    private var hasValidFormatMetadata: Bool {
        formatSemanticVersion > 0
            && Self.isValidComponent(formatIdentifier, maximumBytes: 96)
            && Self.isValidComponent(pixelLayoutFingerprint, maximumBytes: 128)
    }

    private var hasValidPixelGeometry: Bool {
        (1...65_536).contains(pixelWidth)
            && (1...65_536).contains(pixelHeight)
    }

    private static func isValidComponent(_ value: String, maximumBytes: Int) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty && bytes.count <= maximumBytes
            && bytes.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case artifactKeyDigest
        case baseKeyDigest
        case variantKeyDigest
        case namespaceFingerprint
        case namespaceGeneration
        case containerContentID
        case containerByteCount
        case formatIdentifier
        case formatSemanticVersion
        case pixelLayoutFingerprint
        case pixelDigestHex
        case pixelWidth
        case pixelHeight
        case createdAt
    }

    package init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try values.decode(UInt16.self, forKey: .schemaVersion)
        self.artifactKeyDigest = try values.decode(String.self, forKey: .artifactKeyDigest)
        self.baseKeyDigest = try values.decode(String.self, forKey: .baseKeyDigest)
        self.variantKeyDigest = try values.decode(String.self, forKey: .variantKeyDigest)
        self.namespaceFingerprint = try values.decode(
            StorageNamespaceFingerprint.self,
            forKey: .namespaceFingerprint
        )
        self.namespaceGeneration = try values.decode(
            UInt64.self,
            forKey: .namespaceGeneration
        )
        self.containerContentID = try values.decode(String.self, forKey: .containerContentID)
        self.containerByteCount = try values.decode(Int.self, forKey: .containerByteCount)
        self.formatIdentifier = try values.decode(String.self, forKey: .formatIdentifier)
        self.formatSemanticVersion = try values.decode(
            UInt16.self,
            forKey: .formatSemanticVersion
        )
        self.pixelLayoutFingerprint = try values.decode(
            String.self,
            forKey: .pixelLayoutFingerprint
        )
        self.pixelDigestHex = try values.decode(String.self, forKey: .pixelDigestHex)
        self.pixelWidth = try values.decode(Int.self, forKey: .pixelWidth)
        self.pixelHeight = try values.decode(Int.self, forKey: .pixelHeight)
        self.createdAt = try values.decode(Date.self, forKey: .createdAt)
        guard isValidPersistentRecord() else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Invalid derived-raster record"
            )
        }
    }
}

package struct DerivedRasterStoredArtifact: Sendable {
    package let record: DerivedRasterRecord
    package let container: Data
    package let recordValidated: Bool
    package let containerContentDigestVerified: Bool

    package init(
        record: DerivedRasterRecord,
        container: Data,
        recordValidated: Bool = false,
        containerContentDigestVerified: Bool = false
    ) {
        self.record = record
        self.container = container
        self.recordValidated = recordValidated
        self.containerContentDigestVerified = containerContentDigestVerified
    }
}

/// 由持久化适配器检查的可撤销发布 fence。
package protocol DerivedRasterPublicationPermission: Sendable {
    func permitsPublication() async -> Bool
}

/// 面向目标派生光栅容器的包内不透明存储 seam。
package protocol DerivedRasterStoring: Sendable {
    func load(
        artifactKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: UInt64
    ) async throws -> DerivedRasterStoredArtifact?

    func commit(
        container: Data,
        record: DerivedRasterRecord,
        publicationPermission: any DerivedRasterPublicationPermission
    ) async throws

    func remove(
        artifactKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: UInt64
    ) async throws

    func removeAll(namespaceFingerprint: StorageNamespaceFingerprint) async throws

    func removeAll(
        variantKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: UInt64
    ) async throws
}
