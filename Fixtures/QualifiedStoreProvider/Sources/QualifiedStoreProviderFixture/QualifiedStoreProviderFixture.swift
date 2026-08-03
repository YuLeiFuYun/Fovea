import AkashicCore
import Foundation
import FoveaAdvancedSystem
import FoveaHTTP
import FoveaStorage

/// 仅用于证明 conformance kit 可以从独立 SwiftPM consumer 使用公开高级 API。
public struct QualifiedStoreProviderFixture: FoveaPersistentStoreBundleProviding {
    public let descriptor: FoveaPersistentStoreProviderDescriptor

    public init() throws {
        self.descriptor = try FoveaPersistentStoreProviderDescriptor(
            identifier: "dev.fovea.fixture.qualified-store-provider",
            implementationVersion: 1,
            compatibilityFingerprint: "fovea-provider-fixture-v1"
        )
    }

    public func open(
        root: URL,
        encodedSoftTotalBytes: Int,
        maximumEncodedBlobBytes: Int,
        maximumTrackedNamespaces: Int
    ) async throws -> FoveaQualifiedPersistentStoreBundle {
        guard
            root.isFileURL,
            encodedSoftTotalBytes > 0,
            maximumEncodedBlobBytes > 0,
            maximumEncodedBlobBytes <= encodedSoftTotalBytes,
            maximumTrackedNamespaces > 0
        else {
            throw AkashicError.limitExceeded
        }
        let state = try await FixtureStateRegistry.shared.state(
            for: root.standardizedFileURL.path,
            compatibilityFingerprint: descriptor.compatibilityFingerprint
        )
        let encoded = FixtureEncodedStore(state: state)
        let records = FixtureRecordStore(state: state)
        let namespaceGenerations = FoveaNamespaceGenerationPersistence(
            load: { maximumCount in
                try await state.loadNamespaceGenerations(maximumCount: maximumCount)
            },
            persist: { generation, namespace in
                try await state.persistNamespaceGeneration(
                    generation,
                    namespace: namespace
                )
            }
        )
        return try FoveaQualifiedPersistentStoreBundle(
            descriptor: descriptor,
            generation: state.generation,
            encoded: encoded,
            records: records,
            namespaceGenerations: namespaceGenerations,
            lifetimeAnchor: state
        )
    }
}

private actor FixtureStateRegistry {
    static let shared = FixtureStateRegistry()

    private var states: [String: FixtureState] = [:]

    func state(
        for root: String,
        compatibilityFingerprint: String
    ) throws -> FixtureState {
        if let existing = states[root] {
            return existing
        }
        let created = FixtureState(
            generation: try StoreGenerationDescriptor(
                identifier: StoreGenerationID(),
                compatibilityFingerprint: compatibilityFingerprint
            )
        )
        states[root] = created
        return created
    }
}

private struct BlobKey: Hashable, Sendable {
    let namespace: StorageNamespaceFingerprint
    let contentID: String
}

private actor FixtureState {
    let generation: StoreGenerationDescriptor

    private var blobs: [BlobKey: (data: Data, physicalID: PhysicalBlobID)] = [:]
    private var records: [String: RepresentationRecord] = [:]
    private var namespaceGenerations: [StorageNamespaceFingerprint: UInt64] = [:]

    init(generation: StoreGenerationDescriptor) {
        self.generation = generation
    }

    func read(contentID: String, namespace: String) throws -> Data {
        let key = BlobKey(
            namespace: StorageNamespaceFingerprint(namespace: namespace),
            contentID: contentID
        )
        guard let stored = blobs[key] else {
            throw AkashicError.notFound
        }
        let digest = try BlobDigest(canonicalString: contentID)
        guard digest.matches(stored.data) else { throw AkashicError.integrityMismatch }
        return stored.data
    }

    func commit(data: Data, contentID: String, namespace: String) throws -> StoredBlob {
        let digest = try BlobDigest(canonicalString: contentID)
        guard digest.matches(data) else { throw AkashicError.integrityMismatch }
        let key = BlobKey(
            namespace: StorageNamespaceFingerprint(namespace: namespace),
            contentID: contentID
        )
        if let existing = blobs[key] {
            return try StoredBlob(
                physicalID: existing.physicalID,
                byteCount: data.count,
                wasCreated: false
            )
        }
        let physicalID = PhysicalBlobID()
        blobs[key] = (data, physicalID)
        return try StoredBlob(
            physicalID: physicalID,
            byteCount: data.count,
            wasCreated: true
        )
    }

    func physicalID(contentID: String, namespace: String) -> PhysicalBlobID? {
        blobs[
            BlobKey(
                namespace: StorageNamespaceFingerprint(namespace: namespace),
                contentID: contentID
            )
        ]?.physicalID
    }

    func removeBlob(contentID: String, namespace: String) {
        blobs.removeValue(
            forKey: BlobKey(
                namespace: StorageNamespaceFingerprint(namespace: namespace),
                contentID: contentID
            )
        )
    }

    func removeAllBlobs(namespace: String) {
        let fingerprint = StorageNamespaceFingerprint(namespace: namespace)
        blobs = blobs.filter { $0.key.namespace != fingerprint }
    }

    func garbageCollect(
        retaining references: Set<StoredContentReference>
    ) throws -> GarbageCollectionResult {
        let retained = Set(
            references.map {
                BlobKey(
                    namespace: $0.namespaceFingerprint,
                    contentID: $0.contentID
                )
            }
        )
        var removedCount = 0
        var removedBytes = 0
        blobs = blobs.filter { key, value in
            if retained.contains(key) { return true }
            removedCount += 1
            removedBytes += value.data.count
            return false
        }
        return try GarbageCollectionResult(
            removedBlobCount: removedCount,
            removedByteCount: removedBytes
        )
    }

    func records(
        for baseKeyDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) -> [RepresentationRecord] {
        let fingerprint = StorageNamespaceFingerprint(namespace: namespace)
        let matches = records.values.filter {
            $0.baseKeyDigest == baseKeyDigest
                && $0.securityNamespaceFingerprint == fingerprint
                && $0.namespaceGeneration == namespaceGeneration
        }
        return matches
    }

    func put(_ record: RepresentationRecord) {
        records[record.variantKeyDigest] = record
    }

    func containsReference(
        to contentID: String,
        namespace: String,
        excludingVariantDigest: String?
    ) -> Bool {
        let fingerprint = StorageNamespaceFingerprint(namespace: namespace)
        return records.values.contains {
            $0.securityNamespaceFingerprint == fingerprint
                && $0.contentID == contentID
                && $0.variantKeyDigest != excludingVariantDigest
        }
    }

    func removeRecord(
        _ variantDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) {
        let fingerprint = StorageNamespaceFingerprint(namespace: namespace)
        guard let existing = records[variantDigest],
            existing.securityNamespaceFingerprint == fingerprint,
            existing.namespaceGeneration == namespaceGeneration
        else { return }
        records.removeValue(forKey: variantDigest)
    }

    func removeAllRecords(namespace: String) {
        let fingerprint = StorageNamespaceFingerprint(namespace: namespace)
        records = records.filter { $0.value.securityNamespaceFingerprint != fingerprint }
    }

    func contentReferences() throws -> Set<StoredContentReference> {
        try Set(
            records.values.map {
                try StoredContentReference(
                    namespaceFingerprint: $0.securityNamespaceFingerprint,
                    contentID: $0.contentID
                )
            }
        )
    }

    func loadNamespaceGenerations(
        maximumCount: Int
    ) throws -> [StorageNamespaceFingerprint: UInt64] {
        guard maximumCount > 0, namespaceGenerations.count <= maximumCount else {
            throw AkashicError.limitExceeded
        }
        return namespaceGenerations
    }

    func persistNamespaceGeneration(
        _ generation: UInt64,
        namespace: StorageNamespaceFingerprint
    ) throws {
        if let existing = namespaceGenerations[namespace], generation < existing {
            throw AkashicError.transactionConflict
        }
        namespaceGenerations[namespace] = generation
    }
}

private actor FixtureEncodedStore: OriginalEncodedMaintaining {
    private let state: FixtureState

    init(state: FixtureState) {
        self.state = state
    }

    func read(contentID: String, namespace: String) async throws -> Data {
        try await state.read(contentID: contentID, namespace: namespace)
    }

    func commit(data: Data, contentID: String, namespace: String) async throws -> StoredBlob {
        try await state.commit(data: data, contentID: contentID, namespace: namespace)
    }

    func physicalID(contentID: String, namespace: String) async -> PhysicalBlobID? {
        await state.physicalID(contentID: contentID, namespace: namespace)
    }

    func remove(contentID: String, namespace: String) async throws {
        await state.removeBlob(contentID: contentID, namespace: namespace)
    }

    func removeAll(namespace: String) async throws {
        await state.removeAllBlobs(namespace: namespace)
    }

    func garbageCollect(
        retaining references: Set<StoredContentReference>
    ) async throws -> GarbageCollectionResult {
        try await state.garbageCollect(retaining: references)
    }
}

private actor FixtureRecordStore: RepresentationRecordMaintaining {
    private let state: FixtureState

    init(state: FixtureState) {
        self.state = state
    }

    func records(
        for baseKeyDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async -> [RepresentationRecord] {
        await state.records(
            for: baseKeyDigest,
            namespace: namespace,
            namespaceGeneration: namespaceGeneration
        )
    }

    func put(_ record: RepresentationRecord) async throws {
        await state.put(record)
    }

    func containsReference(
        to contentID: String,
        namespace: String,
        excludingVariantDigest: String?
    ) async -> Bool {
        await state.containsReference(
            to: contentID,
            namespace: namespace,
            excludingVariantDigest: excludingVariantDigest
        )
    }

    func remove(
        _ variantDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async throws {
        await state.removeRecord(
            variantDigest,
            namespace: namespace,
            namespaceGeneration: namespaceGeneration
        )
    }

    func removeAll(namespace: String) async throws {
        await state.removeAllRecords(namespace: namespace)
    }

    func contentReferences() async -> Set<StoredContentReference> {
        (try? await state.contentReferences()) ?? []
    }
}
