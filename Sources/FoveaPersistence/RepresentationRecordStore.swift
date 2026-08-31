import AkashicCore
import Darwin
import Foundation
import FoveaHTTP
import FoveaStorage

/// Read-only exact-variant index used by the hot authorization path.
/// Persistent mutations remain serialized by `RepresentationRecordStore`; while one is in
/// progress this index returns a miss so callers fall back to the actor-isolated full Vary path.
private final class RepresentationRecordExactLookupIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var recordsByBaseKey: [String: [RepresentationRecord]] = [:]
    private var mutationInProgress = false

    func recordsSnapshot(
        for baseKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: UInt64
    ) -> [RepresentationRecord]? {
        lock.lock()
        defer { lock.unlock() }
        guard !mutationInProgress else { return nil }
        return (recordsByBaseKey[baseKeyDigest] ?? []).filter { record in
            record.securityNamespaceFingerprint == namespaceFingerprint
                && record.namespaceGeneration == namespaceGeneration
        }
    }

    func uniqueRecord(
        for variantDigest: String,
        baseKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: UInt64
    ) -> RepresentationRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard !mutationInProgress else { return nil }
        var matched: RepresentationRecord?
        for record in recordsByBaseKey[baseKeyDigest] ?? []
        where record.securityNamespaceFingerprint == namespaceFingerprint
            && record.namespaceGeneration == namespaceGeneration
        {
            guard matched == nil else { return nil }
            matched = record
        }
        guard matched?.variantKeyDigest == variantDigest else { return nil }
        return matched
    }

    func replaceAll(_ records: [String: RepresentationRecord]) {
        var grouped: [String: [RepresentationRecord]] = [:]
        for record in records.values {
            grouped[record.baseKeyDigest, default: []].append(record)
        }
        for baseKey in grouped.keys {
            grouped[baseKey]?.sort { $0.variantKeyDigest < $1.variantKeyDigest }
        }
        lock.lock()
        recordsByBaseKey = grouped
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

/// 由清单索引的规范表征记录持久化存储。

package actor RepresentationRecordStore:
    RepresentationRecordMaintaining,
    RepresentationRecordSnapshotLookingUp,
    RepresentationRecordExactLookingUp
{
    private static let maximumManifestBytes = 64 * 1024 * 1024
    private static let maximumManifestEntryCount = 100_000
    private nonisolated let ioExecutor = FoveaBlockingIOExecutor(
        label: "dev.fovea.http.representation-records"
    )
    private nonisolated let exactLookupIndex = RepresentationRecordExactLookupIndex()

    package nonisolated var unownedExecutor: UnownedSerialExecutor {
        ioExecutor.asUnownedSerialExecutor()
    }

    private struct Manifest: Codable {
        let schemaVersion: UInt16
        var records: [String: RepresentationRecord]
    }

    private let fileURL: URL
    private var lifetimeAnchor: (any Sendable)?
    private var recordsByVariant: [String: RepresentationRecord]
    private var variantsByBaseKey: [String: Set<String>]
    private var referenceCounts: [StoredContentReference: Int]

    private init(root: URL) {
        self.fileURL = root.appendingPathComponent("representation-records.json")
        self.recordsByVariant = [:]
        self.variantsByBaseKey = [:]
        self.referenceCounts = [:]
    }

    /// 在 actor 存活期间保留 package 内部生命周期所有者。
    package func retainLifetimeAnchor(_ anchor: any Sendable) {
        lifetimeAnchor = anchor
    }

    package static func open(root: URL) async throws -> RepresentationRecordStore {
        let store = RepresentationRecordStore(root: root)
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
        if let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            guard manifest.schemaVersion == RepresentationRecord.currentSchemaVersion,
                manifest.records.count <= Self.maximumManifestEntryCount,
                manifest.records.allSatisfy({ key, record in
                    record.isValidPersistentRecord(storedUnder: key)
                })
            else {
                throw AkashicError.invalidManifest
            }
            recordsByVariant = manifest.records
            rebuildIndexes()
            exactLookupIndex.replaceAll(manifest.records)
            return
        }

        throw AkashicError.invalidManifest
    }

    package func records(
        for baseKeyDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) -> [RepresentationRecord] {
        let fingerprint = StorageNamespaceFingerprint(namespace: namespace)
        return (variantsByBaseKey[baseKeyDigest] ?? []).sorted().compactMap { variantDigest in
            guard let record = recordsByVariant[variantDigest],
                record.securityNamespaceFingerprint == fingerprint,
                record.namespaceGeneration == namespaceGeneration
            else { return nil }
            return record
        }
    }

    package nonisolated func recordsSnapshot(
        for baseKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: UInt64
    ) -> [RepresentationRecord]? {
        exactLookupIndex.recordsSnapshot(
            for: baseKeyDigest,
            namespaceFingerprint: namespaceFingerprint,
            namespaceGeneration: namespaceGeneration
        )
    }

    /// 单候选快路径仍绑定 base、namespace 与 generation；存在第二个候选时必须回退完整 Vary 选择。
    package nonisolated func uniqueRecord(
        for variantDigest: String,
        baseKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: UInt64
    ) -> RepresentationRecord? {
        exactLookupIndex.uniqueRecord(
            for: variantDigest,
            baseKeyDigest: baseKeyDigest,
            namespaceFingerprint: namespaceFingerprint,
            namespaceGeneration: namespaceGeneration
        )
    }

    /// 仅供包内测试和诊断使用。
    package func record(for variantDigest: String) -> RepresentationRecord? {
        recordsByVariant[variantDigest]
    }

    package func put(_ record: RepresentationRecord) throws {
        guard record.isValidPersistentRecord(storedUnder: record.variantKeyDigest) else {
            throw AkashicError.invalidManifest
        }
        let previous = recordsByVariant[record.variantKeyDigest]
        var next = recordsByVariant
        next[record.variantKeyDigest] = record
        exactLookupIndex.beginMutation()
        do {
            try persist(next)
        } catch {
            exactLookupIndex.endMutationWithoutChange()
            throw error
        }
        recordsByVariant = next
        updateIndexes(replacing: previous, with: record)
        exactLookupIndex.replaceAll(next)
    }

    package func containsReference(
        to contentID: String,
        namespace: String,
        excludingVariantDigest: String? = nil
    ) -> Bool {
        let reference = StoredContentReference(
            validatedNamespaceFingerprint: StorageNamespaceFingerprint(namespace: namespace),
            validatedContentID: contentID
        )
        let count = referenceCounts[reference] ?? 0
        guard let excludingVariantDigest,
            let excluded = recordsByVariant[excludingVariantDigest],
            contentReference(for: excluded) == reference
        else {
            return count > 0
        }
        return count > 1
    }

    package func remove(
        _ variantDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) throws {
        let fingerprint = StorageNamespaceFingerprint(namespace: namespace)
        guard let record = recordsByVariant[variantDigest],
            record.securityNamespaceFingerprint == fingerprint,
            record.namespaceGeneration == namespaceGeneration
        else { return }
        var next = recordsByVariant
        next.removeValue(forKey: variantDigest)
        exactLookupIndex.beginMutation()
        do {
            try persist(next)
        } catch {
            exactLookupIndex.endMutationWithoutChange()
            throw error
        }
        recordsByVariant = next
        updateIndexes(replacing: record, with: nil)
        exactLookupIndex.replaceAll(next)
    }

    package func contentReferences() async -> Set<StoredContentReference> {
        Set(referenceCounts.keys)
    }

    package func removeAll(namespace: String) throws {
        let fingerprint = StorageNamespaceFingerprint(namespace: namespace)
        let next = recordsByVariant.filter { $0.value.securityNamespaceFingerprint != fingerprint }
        guard next.count != recordsByVariant.count else { return }
        exactLookupIndex.beginMutation()
        do {
            try persist(next)
        } catch {
            exactLookupIndex.endMutationWithoutChange()
            throw error
        }
        recordsByVariant = next
        rebuildIndexes()
        exactLookupIndex.replaceAll(next)
    }

    private func persist(_ records: [String: RepresentationRecord]) throws {
        guard records.count <= Self.maximumManifestEntryCount else {
            throw AkashicError.storageUnavailable
        }
        let manifest = Manifest(
            schemaVersion: RepresentationRecord.currentSchemaVersion,
            records: records
        )
        let data = try JSONEncoder().encode(manifest)
        guard data.count <= Self.maximumManifestBytes else {
            throw AkashicError.storageUnavailable
        }
        try FoveaDurableFileWriter.writeReplacing(data, to: fileURL)
    }

    private static func fileByteCountWithoutFollowingLinks(_ url: URL) -> Int64 {
        var status = stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else { return -1 }
        return status.st_size
    }

    private func rebuildIndexes() {
        variantsByBaseKey.removeAll(keepingCapacity: true)
        referenceCounts.removeAll(keepingCapacity: true)
        for record in recordsByVariant.values {
            updateIndexes(replacing: nil, with: record)
        }
    }

    private func updateIndexes(
        replacing oldRecord: RepresentationRecord?,
        with newRecord: RepresentationRecord?
    ) {
        if let oldRecord {
            if var variants = variantsByBaseKey[oldRecord.baseKeyDigest] {
                variants.remove(oldRecord.variantKeyDigest)
                if variants.isEmpty {
                    variantsByBaseKey.removeValue(forKey: oldRecord.baseKeyDigest)
                } else {
                    variantsByBaseKey[oldRecord.baseKeyDigest] = variants
                }
            }
            decrementReference(contentReference(for: oldRecord))
        }
        if let newRecord {
            variantsByBaseKey[newRecord.baseKeyDigest, default: []].insert(
                newRecord.variantKeyDigest
            )
            let reference = contentReference(for: newRecord)
            referenceCounts[reference, default: 0] += 1
        }
    }

    private func decrementReference(_ reference: StoredContentReference) {
        guard let count = referenceCounts[reference] else { return }
        if count <= 1 {
            referenceCounts.removeValue(forKey: reference)
        } else {
            referenceCounts[reference] = count - 1
        }
    }

    private func contentReference(
        for record: RepresentationRecord
    ) -> StoredContentReference {
        StoredContentReference(
            validatedNamespaceFingerprint: record.securityNamespaceFingerprint,
            validatedContentID: record.contentID
        )
    }
}
