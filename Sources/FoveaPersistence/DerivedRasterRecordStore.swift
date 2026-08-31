import AkashicCore
import Darwin
import Foundation
import FoveaStorage

/// 不可变 derived-raster record 的热路径 read index。
///
/// 持久化 mutation 仍由 `DerivedRasterRecordStore` 串行化；mutation 期间 index 失败关闭，避免 durable manifest 变化时暴露旧 record。
package struct IndexedDerivedRasterRecord: Sendable {
    package let record: DerivedRasterRecord
    package let containerDigest: BlobDigest
}

private final class DerivedRasterRecordLookupIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var recordsByArtifact: [String: IndexedDerivedRasterRecord] = [:]
    private var mutationInProgress = false

    func record(
        for artifactKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: UInt64
    ) -> IndexedDerivedRasterRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard !mutationInProgress,
            let indexed = recordsByArtifact[artifactKeyDigest],
            indexed.record.namespaceFingerprint == namespaceFingerprint,
            indexed.record.namespaceGeneration == namespaceGeneration
        else { return nil }
        return indexed
    }

    func replaceAll(_ records: [String: DerivedRasterRecord]) {
        lock.lock()
        let previous = recordsByArtifact
        lock.unlock()

        var indexed: [String: IndexedDerivedRasterRecord] = [:]
        indexed.reserveCapacity(records.count)
        for (key, record) in records {
            if let existing = previous[key], existing.record == record {
                indexed[key] = existing
                continue
            }
            guard let digest = try? BlobDigest(canonicalString: record.containerContentID),
                digest.byteCount == record.containerByteCount
            else {
                assertionFailure("validated derived-raster record lost canonical blob identity")
                lock.lock()
                recordsByArtifact = [:]
                mutationInProgress = false
                lock.unlock()
                return
            }
            indexed[key] = IndexedDerivedRasterRecord(
                record: record,
                containerDigest: digest
            )
        }
        lock.lock()
        recordsByArtifact = indexed
        mutationInProgress = false
        lock.unlock()
    }

    func beginMutation() {
        lock.lock()
        mutationInProgress = true
        lock.unlock()
    }

    func endMutationWithoutChange() {
        lock.lock()
        mutationInProgress = false
        lock.unlock()
    }
}

/// 派生光栅 alias manifest 的单写者持久化边界。
///
/// 该 actor 在专属串行执行器上完成有界读取、schema 验证、引用计数重建与原子整表替换。
/// blob 生命周期不由此处决定：它只发布或移除 alias，并向上层暴露仍可达的 ContentID 集合。
/// 旧 schema 在重开时直接删除，不迁移也不保留；任何解码失败、future schema、超限 manifest
/// 或非法当前记录都会失败关闭。如果记录数量或更新频率使整表替换成为资源瓶颈，应拆出分段
/// manifest，而不能放宽原子发布与引用一致性。
package actor DerivedRasterRecordStore {
    package static let currentSchemaVersion = DerivedRasterRecord.currentSchemaVersion
    private static let maximumManifestBytes = 64 * 1_024 * 1_024
    private static let maximumManifestEntryCount = 100_000

    private nonisolated let ioExecutor = FoveaBlockingIOExecutor(
        label: "dev.fovea.persistence.derived-raster-records"
    )
    private nonisolated let lookupIndex = DerivedRasterRecordLookupIndex()

    package nonisolated var unownedExecutor: UnownedSerialExecutor {
        ioExecutor.asUnownedSerialExecutor()
    }

    private struct Manifest: Codable {
        let schemaVersion: UInt16
        let records: [String: DerivedRasterRecord]
    }

    private struct ManifestHeader: Decodable {
        let schemaVersion: UInt16
    }

    private let fileURL: URL
    private var recordsByArtifact: [String: DerivedRasterRecord]
    private var referenceCounts: [StoredContentReference: Int]

    private init(root: URL) {
        self.fileURL = root.appendingPathComponent("derived-raster-records.json")
        self.recordsByArtifact = [:]
        self.referenceCounts = [:]
    }

    package static func open(root: URL) async throws -> DerivedRasterRecordStore {
        let store = DerivedRasterRecordStore(root: root)
        try await store.bootstrap(root: root)
        return store
    }

    private func bootstrap(root: URL) throws {
        try FoveaManagedFileSecurity.prepareDirectory(root)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try FoveaBoundedFileReader.read(
                from: fileURL,
                maximumBytes: Self.maximumManifestBytes
            )
        } catch {
            if Self.fileByteCountWithoutFollowingLinks(fileURL) > Self.maximumManifestBytes {
                throw AkashicError.storageUnavailable
            }
            throw AkashicError.invalidManifest
        }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(ManifestHeader.self, from: data) else {
            throw AkashicError.invalidManifest
        }
        if header.schemaVersion < Self.currentSchemaVersion {
            // derived raster 是 package 内部临时优化状态；旧 schema 直接删除而不迁移/保留，随后由 Akashic reconciliation 回收失去引用的 blob。
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                throw AkashicError.storageUnavailable
            }
            recordsByArtifact = [:]
            lookupIndex.replaceAll([:])
            rebuildReferences()
            return
        }
        guard header.schemaVersion == Self.currentSchemaVersion,
            let manifest = try? decoder.decode(Manifest.self, from: data),
            manifest.records.count <= Self.maximumManifestEntryCount,
            manifest.records.allSatisfy({ key, value in
                value.isValidPersistentRecord(storedUnder: key)
            })
        else { throw AkashicError.invalidManifest }
        recordsByArtifact = manifest.records
        lookupIndex.replaceAll(manifest.records)
        rebuildReferences()
    }

    package nonisolated func record(
        for artifactKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: UInt64
    ) -> IndexedDerivedRasterRecord? {
        lookupIndex.record(
            for: artifactKeyDigest,
            namespaceFingerprint: namespaceFingerprint,
            namespaceGeneration: namespaceGeneration
        )
    }

    package func projectedManifestByteCount(putting record: DerivedRasterRecord) throws -> Int {
        guard record.isValidPersistentRecord(storedUnder: record.artifactKeyDigest) else {
            throw AkashicError.invalidManifest
        }
        var next = recordsByArtifact
        next[record.artifactKeyDigest] = record
        return try encodedManifest(next).count
    }

    package func put(_ record: DerivedRasterRecord) throws {
        guard record.isValidPersistentRecord(storedUnder: record.artifactKeyDigest) else {
            throw AkashicError.invalidManifest
        }
        let previous = recordsByArtifact[record.artifactKeyDigest]
        var next = recordsByArtifact
        next[record.artifactKeyDigest] = record
        lookupIndex.beginMutation()
        do {
            try persist(next)
        } catch {
            lookupIndex.endMutationWithoutChange()
            throw error
        }
        recordsByArtifact = next
        updateReference(replacing: previous, with: record)
        lookupIndex.replaceAll(next)
    }

    package func remove(
        artifactKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: UInt64
    ) throws -> DerivedRasterRecord? {
        guard let record = recordsByArtifact[artifactKeyDigest],
            record.namespaceFingerprint == namespaceFingerprint,
            record.namespaceGeneration == namespaceGeneration
        else { return nil }
        var next = recordsByArtifact
        next.removeValue(forKey: artifactKeyDigest)
        lookupIndex.beginMutation()
        do {
            try persist(next)
        } catch {
            lookupIndex.endMutationWithoutChange()
            throw error
        }
        recordsByArtifact = next
        updateReference(replacing: record, with: nil)
        lookupIndex.replaceAll(next)
        return record
    }

    package func removeAll(
        namespaceFingerprint: StorageNamespaceFingerprint
    ) throws -> [DerivedRasterRecord] {
        let removed = recordsByArtifact.values.filter {
            $0.namespaceFingerprint == namespaceFingerprint
        }
        guard !removed.isEmpty else { return [] }
        let next = recordsByArtifact.filter {
            $0.value.namespaceFingerprint != namespaceFingerprint
        }
        lookupIndex.beginMutation()
        do {
            try persist(next)
        } catch {
            lookupIndex.endMutationWithoutChange()
            throw error
        }
        recordsByArtifact = next
        rebuildReferences()
        lookupIndex.replaceAll(next)
        return removed
    }

    package func removeAll(
        variantKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: UInt64
    ) throws -> [DerivedRasterRecord] {
        let removed = recordsByArtifact.values.filter {
            $0.variantKeyDigest == variantKeyDigest
                && $0.namespaceFingerprint == namespaceFingerprint
                && $0.namespaceGeneration == namespaceGeneration
        }
        guard !removed.isEmpty else { return [] }
        let removedKeys = Set(removed.map(\.artifactKeyDigest))
        let next = recordsByArtifact.filter { !removedKeys.contains($0.key) }
        lookupIndex.beginMutation()
        do {
            try persist(next)
        } catch {
            lookupIndex.endMutationWithoutChange()
            throw error
        }
        recordsByArtifact = next
        rebuildReferences()
        lookupIndex.replaceAll(next)
        return removed
    }

    package func containsReference(
        to contentID: String,
        namespaceFingerprint: StorageNamespaceFingerprint
    ) -> Bool {
        let reference = StoredContentReference(
            validatedNamespaceFingerprint: namespaceFingerprint,
            validatedContentID: contentID
        )
        return (referenceCounts[reference] ?? 0) > 0
    }

    package func contentReferences() -> Set<StoredContentReference> {
        Set(referenceCounts.keys)
    }

    package func removeAll(
        references: Set<StoredContentReference>
    ) throws -> [DerivedRasterRecord] {
        guard !references.isEmpty else { return [] }
        let removed = recordsByArtifact.values.filter { references.contains(reference(for: $0)) }
        guard !removed.isEmpty else { return [] }
        let removedKeys = Set(removed.map(\.artifactKeyDigest))
        let next = recordsByArtifact.filter { !removedKeys.contains($0.key) }
        lookupIndex.beginMutation()
        do {
            try persist(next)
        } catch {
            lookupIndex.endMutationWithoutChange()
            throw error
        }
        recordsByArtifact = next
        rebuildReferences()
        lookupIndex.replaceAll(next)
        return removed
    }

    package func allRecords() -> [DerivedRasterRecord] {
        Array(recordsByArtifact.values)
    }

    package func allRecordsForTesting() -> [DerivedRasterRecord] {
        allRecords()
    }

    private func persist(_ records: [String: DerivedRasterRecord]) throws {
        let data = try encodedManifest(records)
        try FoveaDurableFileWriter.writeReplacing(data, to: fileURL)
    }

    private func encodedManifest(_ records: [String: DerivedRasterRecord]) throws -> Data {
        guard records.count <= Self.maximumManifestEntryCount else {
            throw AkashicError.storageUnavailable
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            Manifest(schemaVersion: Self.currentSchemaVersion, records: records)
        )
        guard data.count <= Self.maximumManifestBytes else {
            throw AkashicError.storageUnavailable
        }
        return data
    }

    private func rebuildReferences() {
        referenceCounts.removeAll(keepingCapacity: true)
        for record in recordsByArtifact.values {
            referenceCounts[reference(for: record), default: 0] += 1
        }
    }

    private func updateReference(
        replacing oldRecord: DerivedRasterRecord?,
        with newRecord: DerivedRasterRecord?
    ) {
        if let oldRecord {
            let oldReference = reference(for: oldRecord)
            let count = referenceCounts[oldReference] ?? 0
            if count <= 1 {
                referenceCounts.removeValue(forKey: oldReference)
            } else {
                referenceCounts[oldReference] = count - 1
            }
        }
        if let newRecord {
            referenceCounts[reference(for: newRecord), default: 0] += 1
        }
    }

    private func reference(for record: DerivedRasterRecord) -> StoredContentReference {
        StoredContentReference(
            validatedNamespaceFingerprint: record.namespaceFingerprint,
            validatedContentID: record.containerContentID
        )
    }

    private static func fileByteCountWithoutFollowingLinks(_ url: URL) -> Int64 {
        var status = stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else { return -1 }
        return status.st_size
    }
}
