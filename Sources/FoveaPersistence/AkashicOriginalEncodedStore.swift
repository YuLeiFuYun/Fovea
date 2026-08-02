import AkashicCore
import AkashicDisk
import Foundation
import FoveaStorage

/// 将 Fovea 的原编码内容协议适配到 Akashic 的 typed partition/blob 契约。
///
/// Fovea 继续拥有 ContentID、namespace、撤销和跨存储发布语义；Akashic 只管理
/// 已由宿主选择的 partition 中、由摘要和精确长度标识的通用 blob。
package actor AkashicOriginalEncodedStore:
    OriginalEncodedMaintaining, OriginalEncodedTransactionalStoring
{
    /// 当前底层通用 blob 清单模式。
    package static let currentSchemaVersion = FileBlobStore.currentSchemaVersion

    private static let partitionDomain = "dev.fovea.original-encoded.partition.v1"
    private static let maximumMaintenanceReferences = 100_000
    private static let maximumMaintenanceReferencedBytes = 100_000 * 1024 * 1024 * 1024

    private let base: FileBlobStore
    private var lifetimeAnchor: (any Sendable)?
    private var stages: [UUID: BlobStage] = [:]

    private init(base: FileBlobStore) {
        self.base = base
    }

    /// 打开由 Akashic FileBlobStore 实现的原编码载荷存储。
    package static func open(
        root: URL,
        limits: OriginalEncodedStoreLimits = OriginalEncodedStoreLimits()
    ) async throws -> AkashicOriginalEncodedStore {
        let base = try await FileBlobStore.open(
            root: root,
            limits: FileBlobStoreLimits(
                softTotalBytes: limits.softTotalBytes,
                maximumBlobBytes: limits.maximumBlobBytes
            )
        )
        return AkashicOriginalEncodedStore(base: base)
    }

    /// 打开单 blob 上限与总软上限共享同一字节预算的存储。
    package static func open(
        root: URL,
        softLimitBytes: Int
    ) async throws -> AkashicOriginalEncodedStore {
        try await open(
            root: root,
            limits: OriginalEncodedStoreLimits(
                softTotalBytes: softLimitBytes,
                maximumBlobBytes: softLimitBytes
            )
        )
    }

    /// 将 Fovea 组合根的生命周期锚绑定到适配器。
    package func retainLifetimeAnchor(_ anchor: any Sendable) {
        lifetimeAnchor = anchor
    }

    package func read(contentID: String, namespace: String) async throws -> Data {
        try await base.read(
            digest: try Self.digest(contentID),
            partition: try Self.partition(namespace: namespace)
        )
    }

    @discardableResult
    package func commit(
        data: Data,
        contentID: String,
        namespace: String
    ) async throws -> StoredBlob {
        let publication = try await base.commit(
            data: data,
            digest: try Self.digest(contentID),
            partition: try Self.partition(namespace: namespace)
        )
        return try Self.storedBlob(publication)
    }

    package func physicalID(
        contentID: String,
        namespace: String
    ) async -> PhysicalBlobID? {
        guard let digest = try? Self.digest(contentID),
            let partition = try? Self.partition(namespace: namespace)
        else { return nil }
        return await base.physicalID(digest: digest, partition: partition)
    }

    package func remove(contentID: String, namespace: String) async throws {
        try await base.remove(
            digest: try Self.digest(contentID),
            partition: try Self.partition(namespace: namespace)
        )
    }

    package func removeAll(namespace: String) async throws {
        try await base.removeAll(partition: try Self.partition(namespace: namespace))
    }

    package func stage(
        data: Data,
        contentID: String,
        namespace: String
    ) async throws -> OriginalEncodedStage {
        let blobStage = try await base.stage(
            data: data,
            digest: try Self.digest(contentID),
            partition: try Self.partition(namespace: namespace)
        )
        let stage = OriginalEncodedStage(identifier: UUID())
        stages[stage.identifier] = blobStage
        return stage
    }

    package func publish(_ stage: OriginalEncodedStage) async throws -> StoredBlob {
        guard let blobStage = stages[stage.identifier] else {
            throw AkashicError.transactionConflict
        }
        let publication = try await base.publish(blobStage)
        stages.removeValue(forKey: stage.identifier)
        return try Self.storedBlob(publication)
    }

    package func discard(_ stage: OriginalEncodedStage) async {
        guard let blobStage = stages.removeValue(forKey: stage.identifier) else { return }
        await base.discard(blobStage)
    }

    package func garbageCollect(
        retaining references: Set<StoredContentReference>
    ) async throws -> GarbageCollectionResult {
        let liveReferences = try Set(
            references.map { reference in
                LiveBlobReference(
                    partition: try Self.partition(fingerprint: reference.namespaceFingerprint),
                    digest: try Self.digest(reference.contentID)
                )
            })
        let limits = try BlobMaintenanceLimits(
            maximumReferenceCount: Self.maximumMaintenanceReferences,
            maximumReferencedBytes: Self.maximumMaintenanceReferencedBytes
        )
        let result = try await base.garbageCollect(
            retaining: liveReferences,
            limits: limits
        )
        return try GarbageCollectionResult(
            removedBlobCount: result.removedBlobCount,
            removedByteCount: result.removedByteCount
        )
    }

    private static func digest(_ contentID: String) throws -> BlobDigest {
        do {
            return try BlobDigest(canonicalString: contentID)
        } catch {
            throw AkashicError.invalidIdentity
        }
    }

    private static func partition(namespace: String) throws -> CachePartitionID {
        try partition(fingerprint: StorageNamespaceFingerprint(namespace: namespace))
    }

    private static func partition(
        fingerprint: StorageNamespaceFingerprint
    ) throws -> CachePartitionID {
        do {
            return try CachePartitionID.derive(
                domain: partitionDomain,
                material: Data(fingerprint.value.utf8)
            )
        } catch {
            throw AkashicError.storageUnavailable
        }
    }

    private static func storedBlob(_ publication: BlobPublication) throws -> StoredBlob {
        try StoredBlob(
            physicalID: publication.physicalID,
            byteCount: publication.byteCount,
            wasCreated: publication.disposition == .created
        )
    }
}
