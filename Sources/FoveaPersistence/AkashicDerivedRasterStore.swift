import AkashicCore
import AkashicDisk
import Foundation
import FoveaStorage

private final class DerivedRasterRecentAccessIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<String> = []

    func insert(_ key: String) {
        lock.lock()
        keys.insert(key)
        lock.unlock()
    }

    func remove(_ key: String) {
        lock.lock()
        keys.remove(key)
        lock.unlock()
    }

    func subtract<S: Sequence>(_ removals: S) where S.Element == String {
        lock.lock()
        for key in removals { keys.remove(key) }
        lock.unlock()
    }

    func consumeAny(_ candidates: [String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard candidates.contains(where: keys.contains) else { return false }
        for key in candidates { keys.remove(key) }
        return true
    }
}

private final class DerivedRasterPartitionCache: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumCount: Int
    private var values: [StorageNamespaceFingerprint: CachePartitionID] = [:]

    init(maximumCount: Int) {
        self.maximumCount = max(1, maximumCount)
    }

    func value(for fingerprint: StorageNamespaceFingerprint) -> CachePartitionID? {
        lock.lock()
        defer { lock.unlock() }
        return values[fingerprint]
    }

    func insertIfSpace(
        _ partition: CachePartitionID,
        for fingerprint: StorageNamespaceFingerprint
    ) -> CachePartitionID {
        lock.lock()
        defer { lock.unlock() }
        if let existing = values[fingerprint] { return existing }
        if values.count < maximumCount { values[fingerprint] = partition }
        return partition
    }
}

package struct DerivedRasterStoreLimits: Equatable, Sendable {
    private static let maximumSupportedBlobBytes = 1024 * 1024 * 1024
    private static let maximumUnderlyingTotalBytes = 1024 * 1024 * 1024 * 1024

    package let softTotalBytes: Int
    package let maximumBlobBytes: Int
    package let maximumWriteBytesPerWindow: Int
    package let writeBudgetWindowNanoseconds: UInt64

    fileprivate var underlyingSoftTotalBytes: Int {
        let headroom = softTotalBytes.addingReportingOverflow(maximumBlobBytes)
        return min(
            Self.maximumUnderlyingTotalBytes,
            headroom.overflow ? Self.maximumUnderlyingTotalBytes : headroom.partialValue
        )
    }

    package init(
        softTotalBytes: Int,
        maximumBlobBytes: Int,
        maximumWriteBytesPerWindow: Int,
        writeBudgetWindowNanoseconds: UInt64
    ) {
        let maximum = min(Self.maximumSupportedBlobBytes, max(1, maximumBlobBytes))
        self.maximumBlobBytes = maximum
        self.softTotalBytes = min(
            Self.maximumSupportedBlobBytes,
            max(maximum, softTotalBytes)
        )
        self.maximumWriteBytesPerWindow = max(1, maximumWriteBytesPerWindow)
        self.writeBudgetWindowNanoseconds = max(1, writeBudgetWindowNanoseconds)
    }
}

/// 由 Akashic 支撑的目标派生光栅不透明存储原型。
///
/// blob 发布先于 alias record，但正常 publication-fence 或 record 发布失败会立即尝试清理
/// 不可达 blob；崩溃残留由重开 GC 收敛。namespace、variant 或单项删除后，垃圾回收只保留
/// 仍可达记录。持久写预算在任何 blob staging 前 durable reserve，重启不能重置当前窗口。
package actor AkashicDerivedRasterStore: DerivedRasterStoring {
    private static let partitionDomain = "dev.fovea.derived-raster.partition.v1"
    private static let maximumCachedPartitions = 64
    private static let maximumMaintenanceReferences = 100_000
    private static let maximumMaintenanceReferencedBytes = 100_000 * 1024 * 1024 * 1024

    private struct BudgetGroup {
        let reference: StoredContentReference
        let byteCount: Int
        var oldestCreatedAt: Date
        var artifactKeys: [String]
    }

    private nonisolated let base: FileBlobStore
    private nonisolated let records: DerivedRasterRecordStore
    private let writeBudget: DerivedRasterWriteBudgetStore
    private let limits: DerivedRasterStoreLimits
    private nonisolated let recentAccess: DerivedRasterRecentAccessIndex
    private nonisolated let partitionCache: DerivedRasterPartitionCache

    private init(
        base: FileBlobStore,
        records: DerivedRasterRecordStore,
        writeBudget: DerivedRasterWriteBudgetStore,
        limits: DerivedRasterStoreLimits
    ) {
        self.base = base
        self.records = records
        self.writeBudget = writeBudget
        self.limits = limits
        recentAccess = DerivedRasterRecentAccessIndex()
        partitionCache = DerivedRasterPartitionCache(
            maximumCount: Self.maximumCachedPartitions
        )
    }

    package static func open(
        root: URL,
        limits: DerivedRasterStoreLimits
    ) async throws -> AkashicDerivedRasterStore {
        let base = try await FileBlobStore.open(
            root: root.appendingPathComponent("blobs", isDirectory: true),
            limits: FileBlobStoreLimits(
                // alias-aware eviction 由 Fovea 持有；给 Akashic 一个 blob 的 commit headroom，避免其低层 trim 在新 alias 越过全部 publication fence 前，
                // 就使仍已发布的 Fovea alias 失效。
                softTotalBytes: limits.underlyingSoftTotalBytes,
                maximumBlobBytes: limits.maximumBlobBytes
            )
        )
        let recordsRoot = root.appendingPathComponent("records", isDirectory: true)
        let records = try await DerivedRasterRecordStore.open(root: recordsRoot)
        let writeBudget = try await DerivedRasterWriteBudgetStore.open(
            root: root.appendingPathComponent("write-budget", isDirectory: true)
        )
        let store = AkashicDerivedRasterStore(
            base: base,
            records: records,
            writeBudget: writeBudget,
            limits: limits
        )
        try await store.reconcileAliasesAndTrimIfNeeded()
        return store
    }

    package nonisolated func load(
        artifactKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: UInt64
    ) async throws -> DerivedRasterStoredArtifact? {
        guard
            let indexed = records.record(
                for: artifactKeyDigest,
                namespaceFingerprint: namespaceFingerprint,
                namespaceGeneration: namespaceGeneration
            )
        else { return nil }
        let record = indexed.record
        let digest = indexed.containerDigest
        let partition = try cachedPartition(namespaceFingerprint)
        // 触盘前先标记 alias，使并发 trim 能观察访问并给予 second chance；读取后再检查 index，
        // 若 blob read 期间并发 mutation 已删除或替换该 alias，则清除此访问位。
        recentAccess.insert(artifactKeyDigest)
        let container: Data
        do {
            container = try await base.read(digest: digest, partition: partition)
        } catch let error as AkashicError where error == .notFound {
            _ = try? await records.remove(
                artifactKeyDigest: artifactKeyDigest,
                namespaceFingerprint: namespaceFingerprint,
                namespaceGeneration: namespaceGeneration
            )
            recentAccess.remove(artifactKeyDigest)
            return nil
        } catch {
            recentAccess.remove(artifactKeyDigest)
            throw error
        }
        guard container.count == record.containerByteCount else {
            recentAccess.remove(artifactKeyDigest)
            throw AkashicError.integrityMismatch
        }
        let stillCurrent = records.record(
            for: artifactKeyDigest,
            namespaceFingerprint: namespaceFingerprint,
            namespaceGeneration: namespaceGeneration
        )
        if stillCurrent?.record != record || stillCurrent?.containerDigest != digest {
            recentAccess.remove(artifactKeyDigest)
        }
        return DerivedRasterStoredArtifact(
            record: record,
            container: container,
            recordValidated: true,
            containerContentDigestVerified: true
        )
    }

    package func commit(container: Data, record: DerivedRasterRecord) async throws {
        try await commit(
            container: container,
            record: record,
            publicationPermission: UnconditionalDerivedRasterPublicationPermission()
        )
    }

    package func commit(
        container: Data,
        record: DerivedRasterRecord,
        publicationPermission: any DerivedRasterPublicationPermission
    ) async throws {
        guard await publicationPermission.permitsPublication() else {
            throw AkashicError.transactionConflict
        }
        guard record.isValidPersistentRecord(storedUnder: record.artifactKeyDigest) else {
            throw AkashicError.invalidManifest
        }
        let digest = try BlobDigest(canonicalString: record.containerContentID)
        guard digest.matches(container), container.count == record.containerByteCount else {
            throw AkashicError.integrityMismatch
        }
        let partition = try Self.partition(record.namespaceFingerprint)
        let manifestByteCount = try await records.projectedManifestByteCount(putting: record)
        let writeCharge = try Self.writeCharge(
            containerByteCount: container.count,
            aliasManifestByteCount: manifestByteCount
        )
        guard
            try await writeBudget.reserve(
                byteCount: writeCharge,
                at: Date(),
                maximumBytes: limits.maximumWriteBytesPerWindow,
                windowNanoseconds: limits.writeBudgetWindowNanoseconds
            )
        else {
            throw DerivedRasterStoreError.writeBudgetExceeded(
                logicalWriteChargeBytes: writeCharge,
                maximumWriteBytesPerWindow: limits.maximumWriteBytesPerWindow
            )
        }
        let stage = try await base.stage(
            data: container,
            digest: digest,
            partition: partition
        )
        guard await publicationPermission.permitsPublication() else {
            await base.discard(stage)
            throw AkashicError.transactionConflict
        }
        do {
            _ = try await base.publish(stage)
        } catch {
            await base.discard(stage)
            throw error
        }
        guard await publicationPermission.permitsPublication() else {
            try? await removeBlobIfUnreferenced(record)
            throw AkashicError.transactionConflict
        }
        do {
            try await records.put(record)
        } catch {
            try? await removeBlobIfUnreferenced(record)
            throw error
        }
        guard await publicationPermission.permitsPublication() else {
            _ = try? await records.remove(
                artifactKeyDigest: record.artifactKeyDigest,
                namespaceFingerprint: record.namespaceFingerprint,
                namespaceGeneration: record.namespaceGeneration
            )
            try? await removeBlobIfUnreferenced(record)
            throw AkashicError.transactionConflict
        }
        try await trimIfNeeded()
    }

    package func remove(
        artifactKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: UInt64
    ) async throws {
        guard
            let removed = try await records.remove(
                artifactKeyDigest: artifactKeyDigest,
                namespaceFingerprint: namespaceFingerprint,
                namespaceGeneration: namespaceGeneration
            )
        else { return }
        recentAccess.remove(removed.artifactKeyDigest)
        try await removeBlobIfUnreferenced(removed)
    }

    package func removeAll(
        namespaceFingerprint: StorageNamespaceFingerprint
    ) async throws {
        let removed = try await records.removeAll(namespaceFingerprint: namespaceFingerprint)
        recentAccess.subtract(removed.map(\.artifactKeyDigest))
        for record in removed {
            try await removeBlobIfUnreferenced(record)
        }
    }

    package func removeAll(
        variantKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: UInt64
    ) async throws {
        let removed = try await records.removeAll(
            variantKeyDigest: variantKeyDigest,
            namespaceFingerprint: namespaceFingerprint,
            namespaceGeneration: namespaceGeneration
        )
        recentAccess.subtract(removed.map(\.artifactKeyDigest))
        for record in removed {
            try await removeBlobIfUnreferenced(record)
        }
    }

    package func garbageCollect() async throws -> GarbageCollectionResult {
        let references = await records.contentReferences()
        let live = try Set(
            references.map { reference in
                try LiveBlobReference(
                    partition: Self.partition(reference.namespaceFingerprint),
                    digest: BlobDigest(canonicalString: reference.contentID)
                )
            }
        )
        let limits = try BlobMaintenanceLimits(
            maximumReferenceCount: Self.maximumMaintenanceReferences,
            maximumReferencedBytes: Self.maximumMaintenanceReferencedBytes
        )
        let result = try await base.garbageCollect(retaining: live, limits: limits)
        return try GarbageCollectionResult(
            removedBlobCount: result.removedBlobCount,
            removedByteCount: result.removedByteCount
        )
    }

    package func physicalIDForTesting(_ record: DerivedRasterRecord) async -> PhysicalBlobID? {
        guard let digest = try? BlobDigest(canonicalString: record.containerContentID),
            let partition = try? Self.partition(record.namespaceFingerprint)
        else { return nil }
        return await base.physicalID(digest: digest, partition: partition)
    }

    package func recordsForTesting() async -> [DerivedRasterRecord] {
        await records.allRecords()
    }

    private func reconcileAliasesAndTrimIfNeeded() async throws {
        let snapshot = await records.allRecords()
        var checkedReferences: Set<StoredContentReference> = []
        var missingReferences: Set<StoredContentReference> = []
        for record in snapshot {
            let reference = Self.reference(for: record)
            guard checkedReferences.insert(reference).inserted else { continue }
            guard let digest = try? BlobDigest(canonicalString: reference.contentID),
                let partition = try? Self.partition(reference.namespaceFingerprint)
            else {
                missingReferences.insert(reference)
                continue
            }
            if await base.physicalID(digest: digest, partition: partition) == nil {
                missingReferences.insert(reference)
            }
        }
        if !missingReferences.isEmpty {
            let removed = try await records.removeAll(references: missingReferences)
            recentAccess.subtract(removed.map(\.artifactKeyDigest))
        }
        _ = try await garbageCollect()
        try await trimIfNeeded()
    }

    private func trimIfNeeded() async throws {
        let groups = Self.budgetGroups(from: await records.allRecords())
        let total = try Self.totalBytes(groups.values)
        guard total > limits.softTotalBytes else { return }
        let victims = try selectVictims(
            from: Self.orderedBudgetGroups(groups.values),
            totalBytes: total
        )
        try await removeBudgetGroups(victims)
    }

    private static func budgetGroups(
        from records: [DerivedRasterRecord]
    ) -> [StoredContentReference: BudgetGroup] {
        var groups: [StoredContentReference: BudgetGroup] = [:]
        for record in records {
            let reference = Self.reference(for: record)
            if var group = groups[reference] {
                group.oldestCreatedAt = min(group.oldestCreatedAt, record.createdAt)
                group.artifactKeys.append(record.artifactKeyDigest)
                groups[reference] = group
            } else {
                groups[reference] = BudgetGroup(
                    reference: reference,
                    byteCount: record.containerByteCount,
                    oldestCreatedAt: record.createdAt,
                    artifactKeys: [record.artifactKeyDigest]
                )
            }
        }
        return groups
    }

    private static func totalBytes(
        _ groups: Dictionary<StoredContentReference, BudgetGroup>.Values
    ) throws -> Int {
        var total = 0
        for group in groups {
            let addition = total.addingReportingOverflow(group.byteCount)
            guard !addition.overflow else { throw AkashicError.storageUnavailable }
            total = addition.partialValue
        }
        return total
    }

    private static func orderedBudgetGroups(
        _ groups: Dictionary<StoredContentReference, BudgetGroup>.Values
    ) -> [BudgetGroup] {
        groups.sorted(by: budgetGroupPrecedes)
    }

    private static func budgetGroupPrecedes(_ lhs: BudgetGroup, _ rhs: BudgetGroup) -> Bool {
        if lhs.oldestCreatedAt != rhs.oldestCreatedAt {
            return lhs.oldestCreatedAt < rhs.oldestCreatedAt
        }
        if lhs.reference.namespaceFingerprint.value != rhs.reference.namespaceFingerprint.value {
            return lhs.reference.namespaceFingerprint.value
                < rhs.reference.namespaceFingerprint.value
        }
        return lhs.reference.contentID < rhs.reference.contentID
    }

    private func selectVictims(
        from ordered: [BudgetGroup],
        totalBytes: Int
    ) throws -> [BudgetGroup] {
        var deferredRecentlyUsed: [BudgetGroup] = []
        var victims: [BudgetGroup] = []
        var remaining = totalBytes
        for group in ordered where remaining > limits.softTotalBytes {
            if recentAccess.consumeAny(group.artifactKeys) {
                deferredRecentlyUsed.append(group)
            } else {
                victims.append(group)
                remaining -= group.byteCount
            }
        }
        for group in deferredRecentlyUsed where remaining > limits.softTotalBytes {
            victims.append(group)
            remaining -= group.byteCount
        }
        guard !victims.isEmpty, remaining <= limits.softTotalBytes else {
            throw AkashicError.storageUnavailable
        }
        return victims
    }

    private func removeBudgetGroups(_ victims: [BudgetGroup]) async throws {
        let victimReferences = Set(victims.map(\.reference))
        let removed = try await records.removeAll(references: victimReferences)
        recentAccess.subtract(removed.map(\.artifactKeyDigest))
        for group in victims {
            try await base.remove(
                digest: BlobDigest(canonicalString: group.reference.contentID),
                partition: Self.partition(group.reference.namespaceFingerprint)
            )
        }
    }

    private static func reference(for record: DerivedRasterRecord) -> StoredContentReference {
        StoredContentReference(
            validatedNamespaceFingerprint: record.namespaceFingerprint,
            validatedContentID: record.containerContentID
        )
    }

    private func removeBlobIfUnreferenced(_ record: DerivedRasterRecord) async throws {
        let stillReferenced = await records.containsReference(
            to: record.containerContentID,
            namespaceFingerprint: record.namespaceFingerprint
        )
        guard !stillReferenced else { return }
        try await base.remove(
            digest: BlobDigest(canonicalString: record.containerContentID),
            partition: Self.partition(record.namespaceFingerprint)
        )
    }

    private static func writeCharge(
        containerByteCount: Int,
        aliasManifestByteCount: Int
    ) throws -> Int {
        guard containerByteCount > 0, aliasManifestByteCount > 0 else {
            throw AkashicError.storageUnavailable
        }
        let charge = containerByteCount.addingReportingOverflow(aliasManifestByteCount)
        guard !charge.overflow else { throw AkashicError.storageUnavailable }
        return charge.partialValue
    }

    private nonisolated func cachedPartition(
        _ fingerprint: StorageNamespaceFingerprint
    ) throws -> CachePartitionID {
        if let cached = partitionCache.value(for: fingerprint) { return cached }
        let partition = try Self.partition(fingerprint)
        return partitionCache.insertIfSpace(partition, for: fingerprint)
    }

    private static func partition(
        _ fingerprint: StorageNamespaceFingerprint
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
}

private struct UnconditionalDerivedRasterPublicationPermission:
    DerivedRasterPublicationPermission
{
    func permitsPublication() async -> Bool {
        true
    }
}
