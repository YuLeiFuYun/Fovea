import AkashicCore
import CryptoKit
import Foundation

/// Fovea legacy 清单使用的 package 内部物理文件名表示。
extension PhysicalBlobID {
    package var foveaStorageFileName: String { rawValue.uuidString.lowercased() }
}

/// 存储安全命名空间的确定性非明文分区键。
///
/// 该值不是保密边界：低熵命名空间标识可能被枚举，
/// 相同命名空间也可跨存储关联。不得将其写入诊断、
/// 证据工件、分析系统或本地持久化实现之外的接口。

public struct StorageNamespaceFingerprint: Hashable, Sendable, Codable {
    /// 经过域分离的命名空间标识的小写 SHA-256 摘要。
    public let value: String

    /// 为逻辑命名空间派生确定性非明文指纹。
    public init(namespace: String) {
        let domainSeparated = Data("fovea-storage-namespace-v1\u{0}\(namespace)".utf8)
        self.value = SHA256.hash(data: domainSeparated)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    package init(validatedValue: String) {
        precondition(StoredContentIdentifier.isLowercaseSHA256(validatedValue))
        self.value = validatedValue
    }

    private enum CodingKeys: String, CodingKey {
        case value
    }

    /// 解码并验证规范小写 SHA-256 指纹。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(String.self, forKey: .value)
        guard StoredContentIdentifier.isLowercaseSHA256(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: .value,
                in: container,
                debugDescription: "Invalid storage namespace fingerprint"
            )
        }
        self.value = value
    }

    /// 编码规范指纹值。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
    }
}

/// 发布编码数据块的结果，包含其物理身份与字节数。

public struct StoredBlob: Hashable, Sendable {
    /// 存储选择的不透明物理定位符。
    public let physicalID: PhysicalBlobID
    /// 已验证的编码载荷大小。
    public let byteCount: Int
    /// 本次提交是创建新物理数据块，还是复用已有数据块。
    public let wasCreated: Bool

    /// 从已验证存储元数据创建发布结果。
    public init(physicalID: PhysicalBlobID, byteCount: Int, wasCreated: Bool) throws {
        guard byteCount >= 0 else { throw AkashicError.storageUnavailable }
        self.physicalID = physicalID
        self.byteCount = byteCount
        self.wasCreated = wasCreated
    }

}

/// 垃圾回收期间用于保留活动内容的命名空间级引用。

public struct StoredContentReference: Hashable, Sendable {
    /// 拥有该引用的非明文命名空间分区。
    public let namespaceFingerprint: StorageNamespaceFingerprint
    /// 该引用保留的规范逻辑内容标识。
    public let contentID: String

    /// 创建命名空间级活动内容引用。
    public init(
        namespaceFingerprint: StorageNamespaceFingerprint,
        contentID: String
    ) throws {
        guard StoredContentIdentifier.byteCount(in: contentID) != nil else {
            throw AkashicError.storageUnavailable
        }
        self.namespaceFingerprint = namespaceFingerprint
        self.contentID = contentID
    }

    package init(
        validatedNamespaceFingerprint: StorageNamespaceFingerprint,
        validatedContentID: String
    ) {
        self.namespaceFingerprint = validatedNamespaceFingerprint
        self.contentID = validatedContentID
    }

}

/// 一次垃圾回收删除的编码数据块与字节摘要。

public struct GarbageCollectionResult: Hashable, Sendable {
    /// 删除的物理数据块文件数。
    public let removedBlobCount: Int
    /// 确认回收的编码字节数。
    public let removedByteCount: Int

    /// 创建垃圾回收摘要。
    public init(removedBlobCount: Int, removedByteCount: Int) throws {
        guard removedBlobCount >= 0, removedByteCount >= 0 else {
            throw AkashicError.storageUnavailable
        }
        self.removedBlobCount = removedBlobCount
        self.removedByteCount = removedByteCount
    }

}

/// 为原始编码内容存储补充删除与垃圾回收操作。

public protocol OriginalEncodedMaintaining: OriginalEncodedStoring {
    /// 保留所有指定命名空间引用，并删除未被引用的数据块。
    func garbageCollect(
        retaining references: Set<StoredContentReference>
    ) async throws -> GarbageCollectionResult
}
