import AkashicCore
import AkashicMemory
import Foundation
import FoveaHTTP
import FoveaStorage
import ImageCraftCore

/// 协调渲染内存、原始编码数据块与 HTTP 表征记录的事务边界。
/// 任何跨存储写入都必须在取消或撤销时恢复到可解释状态，禁止半提交可见。
final class PipelineCache: Sendable {
    static let maximumGarbageCollectionReferenceCount = 100_000
    let encodedStore: any OriginalEncodedStoring
    let recordStore: any RepresentationRecordStoring
    let memory: any RenderedImageCaching
    let renderedAliases:
        MemoryCache<
            ScopedRenderedRequestAliasKey,
            RenderedRequestAlias
        >
    let transportVerifiedHandoffs: TransportVerifiedHandoffDiskStore
    let transportVerifiedEncodedHandoffCostLimit: Int
    let mutationPermits: AsyncPermitPool
    let namespaceRegistry: NamespaceRegistry
    let diagnostics: any DiagnosticsSink

    init(
        encodedStore: any OriginalEncodedStoring,
        recordStore: any RepresentationRecordStoring,
        memoryCostLimit: Int,
        renderedImageCache: (any RenderedImageCaching)? = nil,
        transportVerifiedEncodedHandoffCostLimit: Int,
        mutationQueueLimit: Int,
        namespaceRegistry: NamespaceRegistry,
        diagnostics: any DiagnosticsSink
    ) {
        self.encodedStore = encodedStore
        self.recordStore = recordStore
        self.memory = renderedImageCache ?? DefaultRenderedImageCache(costLimit: memoryCostLimit)
        let aliasLimit = max(64, min(100_000, memoryCostLimit / 4_096))
        self.renderedAliases = MemoryCache(costLimit: aliasLimit)
        self.transportVerifiedEncodedHandoffCostLimit = max(
            1, transportVerifiedEncodedHandoffCostLimit)
        self.transportVerifiedHandoffs = TransportVerifiedHandoffDiskStore(
            costLimit: self.transportVerifiedEncodedHandoffCostLimit
        )
        self.mutationPermits = AsyncPermitPool(
            limit: 1,
            queueLimit: max(1, mutationQueueLimit)
        )
        self.namespaceRegistry = namespaceRegistry
        self.diagnostics = diagnostics
    }

    func records(
        for baseKeyDigest: String,
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration
    ) async -> [RepresentationRecord] {
        let candidates = await recordStore.records(
            for: baseKeyDigest,
            namespace: namespace.value,
            namespaceGeneration: generation.value
        )
        guard candidates.count <= HTTPMetadataLimits.maximumRepresentationCandidateCount else {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .cacheReadFailed,
                    reason: "representation-candidate-limit-exceeded"
                )
            )
            return []
        }

        let namespaceFingerprint = StorageNamespaceFingerprint(namespace: namespace.value)
        var validatedByVariant: [String: RepresentationRecord] = [:]
        var ambiguousVariants: Set<String> = []
        for record in candidates {
            guard record.isValidPersistentRecord(),
                record.baseKeyDigest == baseKeyDigest,
                record.securityNamespaceFingerprint == namespaceFingerprint,
                record.namespaceGeneration == generation.value
            else {
                await diagnostics.record(
                    DiagnosticEvent(
                        kind: .cacheReadFailed,
                        reason: "invalid-representation-store-result"
                    )
                )
                continue
            }
            guard !ambiguousVariants.contains(record.variantKeyDigest) else { continue }
            if let existing = validatedByVariant[record.variantKeyDigest] {
                guard existing == record else {
                    validatedByVariant.removeValue(forKey: record.variantKeyDigest)
                    ambiguousVariants.insert(record.variantKeyDigest)
                    await diagnostics.record(
                        DiagnosticEvent(
                            kind: .cacheReadFailed,
                            reason: "ambiguous-representation-store-result"
                        )
                    )
                    continue
                }
            } else {
                validatedByVariant[record.variantKeyDigest] = record
            }
        }
        return validatedByVariant.values.sorted { lhs, rhs in
            lhs.variantKeyDigest < rhs.variantKeyDigest
        }
    }

    func read(_ record: RepresentationRecord, namespace: SecurityNamespaceID) async throws -> Data {
        try await encodedStore.read(contentID: record.contentID, namespace: namespace.value)
    }

    func removeRecord(
        _ variantDigest: String,
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration
    ) async {
        do {
            try await recordStore.remove(
                variantDigest,
                namespace: namespace.value,
                namespaceGeneration: generation.value
            )
        } catch {
            await recordCacheCleanupFailure(
                keyDigest: variantDigest,
                reason: "record-removal-failed"
            )
        }
    }

    func refresh(
        replacing oldRecord: RepresentationRecord,
        with newRecord: RepresentationRecord,
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration
    ) async throws {
        try Task.checkCancellation()
        try await recordStore.put(newRecord)
        do {
            try Task.checkCancellation()
            try await requireActive(generation, for: namespace)
            if oldRecord.variantKeyDigest != newRecord.variantKeyDigest {
                try await recordStore.remove(
                    oldRecord.variantKeyDigest,
                    namespace: namespace.value,
                    namespaceGeneration: generation.value
                )
            }
        } catch {
            let originalError = error
            let namespaceIsActive = await namespaceRegistry.isActive(generation, for: namespace)
            await rollbackRefresh(
                replacing: oldRecord,
                with: newRecord,
                namespace: namespace,
                generation: generation,
                restoreOverwrittenRecord: namespaceIsActive
            )
            throw originalError
        }
    }

    private func rollbackRefresh(
        replacing oldRecord: RepresentationRecord,
        with newRecord: RepresentationRecord,
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration,
        restoreOverwrittenRecord: Bool
    ) async {
        do {
            if restoreOverwrittenRecord,
                oldRecord.variantKeyDigest == newRecord.variantKeyDigest
            {
                try await recordStore.put(oldRecord)
            } else {
                try await recordStore.remove(
                    newRecord.variantKeyDigest,
                    namespace: namespace.value,
                    namespaceGeneration: generation.value
                )
            }
        } catch {
            await recordCacheCleanupFailure(
                keyDigest: newRecord.variantKeyDigest,
                reason: restoreOverwrittenRecord
                    ? "record-refresh-restore-failed"
                    : "record-refresh-rollback-failed"
            )
        }
    }

    func cleanup(namespace: SecurityNamespaceID) async -> Bool {
        memory.removeAll { $0.namespace == namespace }
        await transportVerifiedHandoffs.removeAll(namespace: namespace)
        renderedAliases.removeAll { $0.namespace == namespace }

        var failed = false
        do {
            try await recordStore.removeAll(namespace: namespace.value)
        } catch {
            failed = true
        }
        do {
            try await encodedStore.removeAll(namespace: namespace.value)
        } catch {
            failed = true
        }
        return failed
    }

    func recordCacheCleanupFailure(
        keyDigest: String,
        reason: String
    ) async {
        await diagnostics.record(
            DiagnosticEvent(
                kind: .cacheWriteFailed,
                keyDigest: keyDigest,
                reason: reason
            )
        )
    }

    func requireActive(
        _ generation: NamespaceGeneration,
        for namespace: SecurityNamespaceID
    ) async throws {
        guard await namespaceRegistry.isActive(generation, for: namespace) else {
            throw PipelineFailure.namespaceRevoked
        }
    }
}
