import AkashicCore
import Darwin
import Foundation
import FoveaStorage

package enum NamespaceGenerationStoreError: Error, Equatable, Sendable {
    case invalidManifest
    case capacityExceeded
    case generationRollback
}

/// 原子持久化 namespace 撤销世代；文件只保存不可逆 namespace 指纹。
///
/// 该 actor 只负责 anti-rollback manifest 与有界容量，不负责决定何时撤销、
/// 清理哪些 blob/record 或解释账户身份；这些权限与事务顺序仍由 FoveaCore 组合层拥有。
package actor NamespaceGenerationStore: NamespaceGenerationPersisting {
    package static let currentSchemaVersion: UInt16 = 1

    private nonisolated let ioExecutor = FoveaBlockingIOExecutor(
        label: "dev.fovea.persistence.namespace-generations"
    )

    package nonisolated var unownedExecutor: UnownedSerialExecutor {
        ioExecutor.asUnownedSerialExecutor()
    }

    private static let fileName = "namespace-generations.json"
    private static let maximumSupportedNamespaces = NamespaceStorageLimits.maximumTrackedNamespaces
    private static let fixedMetadataBudget = 4 * 1024
    private static let perNamespaceMetadataBudget = 112

    private struct Manifest: Codable {
        let schemaVersion: UInt16
        let generations: [String: UInt64]
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: UInt16
    }

    private let fileURL: URL
    private let maximumCount: Int
    private var generations: [StorageNamespaceFingerprint: UInt64]

    package static func open(
        root: URL,
        maximumCount: Int
    ) async throws -> NamespaceGenerationStore {
        let boundedMaximum = min(Self.maximumSupportedNamespaces, max(1, maximumCount))
        let store = NamespaceGenerationStore(
            fileURL: root.appendingPathComponent(Self.fileName, isDirectory: false),
            maximumCount: boundedMaximum,
            generations: [:]
        )
        try await store.bootstrap(root: root)
        return store
    }

    private init(
        fileURL: URL,
        maximumCount: Int,
        generations: [StorageNamespaceFingerprint: UInt64]
    ) {
        self.fileURL = fileURL
        self.maximumCount = maximumCount
        self.generations = generations
    }

    private func bootstrap(root: URL) throws {
        try FoveaManagedFileSecurity.prepareDirectory(root)
        generations = try Self.loadManifest(
            from: fileURL,
            maximumCount: maximumCount
        )
    }

    package func load(
        maximumCount requestedMaximum: Int
    ) throws -> [StorageNamespaceFingerprint: UInt64] {
        guard requestedMaximum >= generations.count, requestedMaximum <= maximumCount else {
            throw NamespaceGenerationStoreError.capacityExceeded
        }
        return generations
    }

    package func persist(
        _ generation: UInt64,
        for namespace: StorageNamespaceFingerprint
    ) throws {
        if let existing = generations[namespace] {
            guard generation >= existing else {
                throw NamespaceGenerationStoreError.generationRollback
            }
            if generation == existing { return }
        } else {
            guard generations.count < maximumCount else {
                throw NamespaceGenerationStoreError.capacityExceeded
            }
        }

        var updated = generations
        updated[namespace] = generation
        try Self.publish(updated, to: fileURL)
        generations = updated
    }

    private static func loadManifest(
        from fileURL: URL,
        maximumCount: Int
    ) throws -> [StorageNamespaceFingerprint: UInt64] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data: Data
        do {
            data = try FoveaBoundedFileReader.read(
                from: fileURL,
                maximumBytes: maximumManifestBytes(for: maximumCount)
            )
        } catch {
            if fileByteCountWithoutFollowingLinks(fileURL)
                > Int64(maximumManifestBytes(for: maximumCount))
            {
                throw AkashicError.storageUnavailable
            }
            throw NamespaceGenerationStoreError.invalidManifest
        }
        if let envelope = try? JSONDecoder().decode(SchemaEnvelope.self, from: data),
            envelope.schemaVersion != currentSchemaVersion
        {
            throw NamespaceGenerationStoreError.invalidManifest
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw NamespaceGenerationStoreError.invalidManifest
        }
        guard manifest.schemaVersion == currentSchemaVersion,
            manifest.generations.count <= maximumCount
        else {
            throw NamespaceGenerationStoreError.invalidManifest
        }

        var result: [StorageNamespaceFingerprint: UInt64] = [:]
        result.reserveCapacity(manifest.generations.count)
        for (fingerprint, generation) in manifest.generations {
            guard StoredContentIdentifier.isLowercaseSHA256(fingerprint) else {
                throw NamespaceGenerationStoreError.invalidManifest
            }
            let key = StorageNamespaceFingerprint(validatedValue: fingerprint)
            guard result[key] == nil else {
                throw NamespaceGenerationStoreError.invalidManifest
            }
            result[key] = generation
        }
        return result
    }

    private static func fileByteCountWithoutFollowingLinks(_ url: URL) -> Int64 {
        var status = stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else { return -1 }
        return status.st_size
    }

    private static func publish(
        _ generations: [StorageNamespaceFingerprint: UInt64],
        to fileURL: URL
    ) throws {
        let manifest = Manifest(
            schemaVersion: currentSchemaVersion,
            generations: Dictionary(
                uniqueKeysWithValues: generations.map { ($0.key.value, $0.value) }
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= maximumManifestBytes(for: generations.count) else {
            throw NamespaceGenerationStoreError.invalidManifest
        }
        try FoveaDurableFileWriter.writeReplacing(data, to: fileURL)
    }

    private static func maximumManifestBytes(for count: Int) -> Int {
        let boundedCount = min(max(0, count), maximumSupportedNamespaces)
        let (entryBytes, overflow) = boundedCount.multipliedReportingOverflow(
            by: perNamespaceMetadataBudget
        )
        guard !overflow else { return Int.max }
        let (total, additionOverflow) = fixedMetadataBudget.addingReportingOverflow(entryBytes)
        return additionOverflow ? Int.max : total
    }
}
