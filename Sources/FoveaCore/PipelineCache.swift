import AkashicCore
import AkashicMemory
import Foundation
import FoveaHTTP
import FoveaStorage
import ImageCraftCore

private struct ScopedRenderedRequestAliasKey: Hashable, Sendable {
    let namespace: SecurityNamespaceID
    let generation: NamespaceGeneration
    let requestIdentity: String
}

private struct RenderedRequestAlias: Sendable {
    let renderKey: ScopedRenderKey
    let representation: RepresentationRecord
}

struct ScopedTransportVerifiedHandoffKey: Hashable, Sendable {
    let namespace: SecurityNamespaceID
    let generation: NamespaceGeneration
    let executionDigest: String
}

enum TransportVerifiedEncodedHandoffPayload: Sendable {
    case memory(Data)
    case stagedFile(TransportStagedFileLease)

    var byteCount: Int {
        switch self {
        case .memory(let data): data.count
        case .stagedFile(let lease): lease.byteCount
        }
    }

    func materializedData() throws -> Data {
        switch self {
        case .memory(let data): data
        case .stagedFile(let lease): try lease.mappedData()
        }
    }
}

struct TransportVerifiedEncodedHandoffMetadata: Codable, Sendable {
    let vary: HTTPVarySelection
    let requestTime: Date
    let responseTime: Date
    let responseDate: Date?
    let expiresAt: Date?
    let etag: String?
    let lastModified: String?
    let requiresRevalidation: Bool
    let contentID: ContentID
    let contentType: String?

    init?(
        record: RepresentationRecord,
        request: ImageRequest,
        generation: NamespaceGeneration,
        payloadByteCount: Int
    ) {
        guard record.isValidPersistentRecord(),
            record.securityNamespaceFingerprint
                == StorageNamespaceFingerprint(namespace: request.namespace.value),
            record.namespaceGeneration == generation.value,
            record.baseKeyDigest == request.fetchBaseKey.digestHex,
            record.variantKeyDigest == request.fetchVariantKey(for: record.vary).digestHex,
            record.statusCode == 200,
            record.disposition == .reusable,
            record.payloadLength == payloadByteCount,
            let contentID = ContentID(
                persistentDescription: record.contentID,
                expectedByteCount: payloadByteCount
            )
        else { return nil }

        self.vary = record.vary
        self.requestTime = record.requestTime
        self.responseTime = record.responseTime
        self.responseDate = record.responseDate
        self.expiresAt = record.expiresAt
        self.etag = record.etag
        self.lastModified = record.lastModified
        self.requiresRevalidation = record.requiresRevalidation
        self.contentID = contentID
        self.contentType = record.contentType
    }

    func isFresh(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return date < expiresAt
    }

    func variantKeyDigest(for request: ImageRequest) -> String {
        request.fetchVariantKey(for: vary).digestHex
    }

    func representation(
        for request: ImageRequest,
        generation: NamespaceGeneration
    ) -> RepresentationRecord {
        RepresentationRecord(
            securityNamespace: request.namespace.value,
            namespaceGeneration: generation.value,
            baseKeyDigest: request.fetchBaseKey.digestHex,
            variantKeyDigest: variantKeyDigest(for: request),
            vary: vary,
            statusCode: 200,
            requestTime: requestTime,
            responseTime: responseTime,
            responseDate: responseDate,
            expiresAt: expiresAt,
            etag: etag,
            lastModified: lastModified,
            disposition: .reusable,
            requiresRevalidation: requiresRevalidation,
            contentID: contentID.description,
            payloadLength: contentID.byteCount,
            contentType: contentType
        )
    }
}

struct TransportVerifiedEncodedHandoffEntry: Sendable {
    let payload: TransportVerifiedEncodedHandoffPayload
    let metadata: TransportVerifiedEncodedHandoffMetadata

    var byteCount: Int { payload.byteCount }
    func materializedData() throws -> Data { try payload.materializedData() }

    func variantKeyDigest(for request: ImageRequest) -> String {
        metadata.variantKeyDigest(for: request)
    }

    func representation(
        for request: ImageRequest,
        generation: NamespaceGeneration
    ) -> RepresentationRecord {
        metadata.representation(for: request, generation: generation)
    }
}

enum OriginalCommitPreparation: Sendable {
    case staged(OriginalEncodedStage)
    case deferred(Data)
}

/// 协调渲染内存、原始编码数据块与 HTTP 表征记录的事务边界。
/// 任何跨存储写入都必须在取消或撤销时恢复到可解释状态，禁止半提交可见。
final class PipelineCache: Sendable {
    private static let maximumGarbageCollectionReferenceCount = 100_000
    private let encodedStore: any OriginalEncodedStoring
    private let recordStore: any RepresentationRecordStoring
    private let memory: any RenderedImageCaching
    private let renderedAliases: MemoryCache<ScopedRenderedRequestAliasKey, RenderedRequestAlias>
    private let transportVerifiedHandoffs: TransportVerifiedHandoffDiskStore
    private let transportVerifiedEncodedHandoffCostLimit: Int
    private let mutationPermits: AsyncPermitPool
    private let namespaceRegistry: NamespaceRegistry
    private let diagnostics: any DiagnosticsSink

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

    func insertTransportVerifiedHandoff(
        data: Data,
        record: RepresentationRecord,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws {
        try await insertTransportVerifiedHandoff(
            payload: .memory(data),
            record: record,
            request: request,
            generation: generation
        )
    }

    func insertTransportVerifiedHandoff(
        payload: TransportVerifiedEncodedHandoffPayload,
        record: RepresentationRecord,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws {
        let byteCount = payload.byteCount
        guard request.cachePolicy == .automatic,
            request.authorizationContext == .public,
            !request.containsCredentialHeaders,
            let metadata = TransportVerifiedEncodedHandoffMetadata(
                record: record,
                request: request,
                generation: generation,
                payloadByteCount: byteCount
            )
        else { return }
        guard byteCount <= transportVerifiedEncodedHandoffCostLimit else {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .encodedHandoffRejected,
                    keyDigest: request.fetchExecutionKey.digestHex,
                    byteCount: byteCount,
                    reason: "entry-exceeds-handoff-budget"
                )
            )
            return
        }
        try await requireActive(generation, for: request.namespace)
        let key = ScopedTransportVerifiedHandoffKey(
            namespace: request.namespace,
            generation: generation,
            executionDigest: request.fetchExecutionKey.digestHex
        )
        try await transportVerifiedHandoffs.insert(
            payload: payload,
            metadata: metadata,
            for: key
        )
        do {
            try await requireActive(generation, for: request.namespace)
        } catch {
            await transportVerifiedHandoffs.remove(key)
            throw error
        }
        await diagnostics.record(
            DiagnosticEvent(
                kind: .encodedHandoffStored,
                keyDigest: request.fetchExecutionKey.digestHex,
                byteCount: byteCount,
                itemCount: transportVerifiedHandoffs.count
            )
        )
    }

    func transportVerifiedHandoff(
        for request: ImageRequest,
        generation: NamespaceGeneration,
        currentDate: @Sendable () async -> Date
    ) async throws -> TransportVerifiedEncodedHandoffEntry? {
        guard request.cachePolicy == .automatic else { return nil }
        let key = ScopedTransportVerifiedHandoffKey(
            namespace: request.namespace,
            generation: generation,
            executionDigest: request.fetchExecutionKey.digestHex
        )
        let entry: TransportVerifiedEncodedHandoffEntry
        do {
            guard let stored = try await transportVerifiedHandoffs.entry(for: key) else {
                return nil
            }
            entry = stored
        } catch {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .cacheReadFailed,
                    keyDigest: request.fetchExecutionKey.digestHex,
                    reason: "transport-handoff-read"
                )
            )
            return nil
        }
        let date = await currentDate()
        guard entry.metadata.isFresh(at: date),
            entry.metadata.contentID.byteCount == entry.byteCount
        else {
            await transportVerifiedHandoffs.remove(key)
            return nil
        }
        try await requireActive(generation, for: request.namespace)
        await diagnostics.record(
            DiagnosticEvent(
                kind: .encodedHandoffHit,
                keyDigest: request.fetchExecutionKey.digestHex,
                byteCount: entry.byteCount,
                itemCount: transportVerifiedHandoffs.count
            )
        )
        return entry
    }

    func removeTransportVerifiedHandoff(
        for request: ImageRequest,
        generation: NamespaceGeneration
    ) async {
        await transportVerifiedHandoffs.remove(
            ScopedTransportVerifiedHandoffKey(
                namespace: request.namespace,
                generation: generation,
                executionDigest: request.fetchExecutionKey.digestHex
            )
        )
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

    func renderedImage(for key: ScopedRenderKey) async -> DecodedImage? {
        memory.image(for: key.renderedImageCacheKey)
    }

    func renderedImage(
        for request: ImageRequest,
        generation: NamespaceGeneration,
        currentDate: @Sendable () async -> Date
    ) async -> DecodedImage? {
        let aliasKey = ScopedRenderedRequestAliasKey(
            namespace: request.namespace,
            generation: generation,
            requestIdentity: request.renderAliasIdentity
        )
        guard let alias = renderedAliases.value(for: aliasKey) else { return nil }
        let representation = alias.representation
        let selected = HTTPCachePolicy.selectRecord(
            from: [representation],
            requestHeaders: request.headers,
            additionalSensitiveNames: request.credentialHeaderNames,
            sensitiveFingerprints: request.headerVariantFingerprints
        )
        guard representation.isValidPersistentRecord(),
            representation.securityNamespaceFingerprint
                == StorageNamespaceFingerprint(namespace: request.namespace.value),
            representation.namespaceGeneration == generation.value,
            representation.baseKeyDigest == request.fetchBaseKey.digestHex,
            representation.disposition != .noStore,
            selected?.variantKeyDigest == representation.variantKeyDigest,
            let image = memory.image(for: alias.renderKey.renderedImageCacheKey)
        else {
            renderedAliases.remove(aliasKey)
            return nil
        }
        let date = await currentDate()
        guard representation.isFresh(at: date) else {
            renderedAliases.remove(aliasKey)
            return nil
        }
        return image
    }

    func insertRendered(_ image: DecodedImage, for key: ScopedRenderKey) async {
        memory.insert(
            image,
            for: key.renderedImageCacheKey,
            cost: image.estimatedByteCost
        )
    }

    func insertRenderedAlias(
        for request: ImageRequest,
        generation: NamespaceGeneration,
        renderKey: ScopedRenderKey,
        representation: RepresentationRecord
    ) async throws {
        guard representation.disposition != .noStore,
            representation.isValidPersistentRecord(),
            representation.securityNamespaceFingerprint
                == StorageNamespaceFingerprint(namespace: request.namespace.value),
            representation.namespaceGeneration == generation.value,
            representation.baseKeyDigest == request.fetchBaseKey.digestHex
        else { return }

        try await requireActive(generation, for: request.namespace)
        let aliasKey = ScopedRenderedRequestAliasKey(
            namespace: request.namespace,
            generation: generation,
            requestIdentity: request.renderAliasIdentity
        )
        renderedAliases.insert(
            RenderedRequestAlias(renderKey: renderKey, representation: representation),
            for: aliasKey,
            cost: 1
        )
        guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
            renderedAliases.remove(aliasKey)
            throw PipelineFailure.namespaceRevoked
        }
    }

    func removeRendered(_ key: ScopedRenderKey) async {
        memory.remove(key.renderedImageCacheKey)
    }

    func purgeRendered() async -> RenderedImageCacheRemovalSummary {
        renderedAliases.removeAll()
        let rendered = memory.removeAllAndReport()
        let handoffs = await transportVerifiedHandoffs.removeAllAndReport()
        return RenderedImageCacheRemovalSummary(
            itemCount: rendered.itemCount + handoffs.itemCount,
            costBytes: rendered.costBytes + handoffs.costBytes
        )
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

    func transientHandoffSnapshot() -> (
        itemCount: Int,
        costBytes: Int,
        inFlightPreparationCount: Int,
        inFlightPreparationBytes: Int
    ) {
        transportVerifiedHandoffs.snapshot()
    }

    func discardTransientHandoffs() async {
        _ = await transportVerifiedHandoffs.invalidateAndRemoveAll()
    }

    func discardReusableState(
        record: RepresentationRecord,
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration
    ) async {
        memory.removeAll {
            $0.namespace == namespace && $0.generation == generation
        }
        renderedAliases.removeAll {
            $0.namespace == namespace && $0.generation == generation
        }
        do {
            try await recordStore.remove(
                record.variantKeyDigest,
                namespace: namespace.value,
                namespaceGeneration: generation.value
            )
        } catch {
            await recordCacheCleanupFailure(
                keyDigest: record.variantKeyDigest,
                reason: "no-store-record-removal-failed"
            )
        }
        let stillReferenced = await recordStore.containsReference(
            to: record.contentID,
            namespace: namespace.value,
            excludingVariantDigest: nil
        )
        if !stillReferenced {
            do {
                try await encodedStore.remove(
                    contentID: record.contentID,
                    namespace: namespace.value
                )
            } catch {
                await recordCacheCleanupFailure(
                    keyDigest: record.variantKeyDigest,
                    reason: "no-store-blob-removal-failed"
                )
            }
        }
    }

    func prepareOriginalCommit(
        data: Data,
        contentID: ContentID,
        record: RepresentationRecord,
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration
    ) async throws -> OriginalCommitPreparation? {
        try Task.checkCancellation()
        try await requireActive(generation, for: namespace)
        guard let transactional = encodedStore as? any OriginalEncodedTransactionalStoring else {
            return .deferred(data)
        }
        do {
            let stage = try await transactional.stage(
                data: data,
                contentID: contentID.description,
                namespace: namespace.value
            )
            do {
                try Task.checkCancellation()
                try await requireActive(generation, for: namespace)
                return .staged(stage)
            } catch {
                await transactional.discard(stage)
                throw error
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as PipelineFailure where failure.category == .namespaceRevoked {
            throw PipelineFailure.namespaceRevoked
        } catch {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .cacheWriteFailed,
                    keyDigest: record.variantKeyDigest,
                    reason: "encoded-stage-write"
                )
            )
            return nil
        }
    }

    func discardOriginalCommit(_ preparation: OriginalCommitPreparation) async {
        guard case .staged(let stage) = preparation,
            let transactional = encodedStore as? any OriginalEncodedTransactionalStoring
        else { return }
        await transactional.discard(stage)
    }

    func publishOriginalCommit(
        _ preparation: OriginalCommitPreparation,
        contentID: ContentID,
        record: RepresentationRecord,
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration
    ) async throws {
        let permit: AsyncPermitPool.Permit
        do {
            permit = try await mutationPermits.acquire()
        } catch is CancellationError {
            await discardOriginalCommit(preparation)
            throw CancellationError()
        } catch PermitPoolError.queueLimitExceeded {
            await discardOriginalCommit(preparation)
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .cacheWriteFailed,
                    keyDigest: record.variantKeyDigest,
                    reason: "cache-mutation-queue-limit"
                )
            )
            return
        }

        try await permit.withPermit {
            try await publishOriginalWhileHoldingMutationPermit(
                preparation,
                contentID: contentID,
                record: record,
                namespace: namespace,
                generation: generation
            )
        }
    }

    func commitOriginal(
        data: Data,
        contentID: ContentID,
        record: RepresentationRecord,
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration
    ) async throws {
        guard
            let preparation = try await prepareOriginalCommit(
                data: data,
                contentID: contentID,
                record: record,
                namespace: namespace,
                generation: generation
            )
        else { return }
        try await publishOriginalCommit(
            preparation,
            contentID: contentID,
            record: record,
            namespace: namespace,
            generation: generation
        )
    }

    func garbageCollect() async throws -> GarbageCollectionResult {
        guard let recordMaintenance = recordStore as? any RepresentationRecordMaintaining,
            let encodedMaintenance = encodedStore as? any OriginalEncodedMaintaining
        else {
            throw PipelineFailure.cacheMaintenanceUnavailable
        }

        let permit = try await mutationPermits.acquire()
        return try await permit.withPermit {
            let references = await recordMaintenance.contentReferences()
            guard references.count <= Self.maximumGarbageCollectionReferenceCount else {
                throw PipelineFailure.resourceLimit(
                    stage: .persistence,
                    reasonCode: "cache-reference-limit-exceeded"
                )
            }
            return try await encodedMaintenance.garbageCollect(retaining: references)
        }
    }

    private func publishOriginalWhileHoldingMutationPermit(
        _ preparation: OriginalCommitPreparation,
        contentID: ContentID,
        record: RepresentationRecord,
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration
    ) async throws {
        let previousRecord = await records(
            for: record.baseKeyDigest,
            namespace: namespace,
            generation: generation
        ).first { $0.variantKeyDigest == record.variantKeyDigest }
        var createdBlob = false
        var recordMutationAttempted = false

        do {
            try Task.checkCancellation()
            let stored: StoredBlob
            switch preparation {
            case .staged(let stage):
                guard let transactional = encodedStore as? any OriginalEncodedTransactionalStoring
                else {
                    throw AkashicError.storageUnavailable
                }
                stored = try await transactional.publish(stage)
            case .deferred(let data):
                stored = try await encodedStore.commit(
                    data: data,
                    contentID: contentID.description,
                    namespace: namespace.value
                )
            }
            createdBlob = stored.wasCreated
            guard stored.byteCount == record.payloadLength else {
                throw AkashicError.storageUnavailable
            }
            try Task.checkCancellation()
            try await requireActive(generation, for: namespace)

            recordMutationAttempted = true
            try await recordStore.put(record)
            try Task.checkCancellation()
            try await requireActive(generation, for: namespace)
        } catch let failure as PipelineFailure where failure.category == .namespaceRevoked {
            await discardOriginalCommit(preparation)
            await rollback(
                createdBlob: createdBlob,
                recordMutationAttempted: recordMutationAttempted,
                previousRecord: previousRecord,
                contentID: contentID,
                variantDigest: record.variantKeyDigest,
                generation: generation,
                namespace: namespace
            )
            throw PipelineFailure.namespaceRevoked
        } catch is CancellationError {
            await discardOriginalCommit(preparation)
            await rollback(
                createdBlob: createdBlob,
                recordMutationAttempted: recordMutationAttempted,
                previousRecord: previousRecord,
                contentID: contentID,
                variantDigest: record.variantKeyDigest,
                generation: generation,
                namespace: namespace
            )
            throw CancellationError()
        } catch {
            await discardOriginalCommit(preparation)
            await rollback(
                createdBlob: createdBlob,
                recordMutationAttempted: recordMutationAttempted,
                previousRecord: previousRecord,
                contentID: contentID,
                variantDigest: record.variantKeyDigest,
                generation: generation,
                namespace: namespace
            )
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .cacheWriteFailed,
                    keyDigest: record.variantKeyDigest,
                    reason: "encoded-or-record-write"
                )
            )
        }
    }

    private func rollback(
        createdBlob: Bool,
        recordMutationAttempted: Bool,
        previousRecord: RepresentationRecord?,
        contentID: ContentID,
        variantDigest: String,
        generation: NamespaceGeneration,
        namespace: SecurityNamespaceID
    ) async {
        if recordMutationAttempted {
            do {
                if let previousRecord,
                    await namespaceRegistry.isActive(generation, for: namespace)
                {
                    try await recordStore.put(previousRecord)
                } else {
                    try await recordStore.remove(
                        variantDigest,
                        namespace: namespace.value,
                        namespaceGeneration: generation.value
                    )
                }
            } catch {
                await recordCacheCleanupFailure(
                    keyDigest: variantDigest,
                    reason: previousRecord == nil
                        ? "commit-rollback-record-removal-failed"
                        : "commit-rollback-record-restore-failed"
                )
            }
        }
        if createdBlob {
            let stillReferenced = await recordStore.containsReference(
                to: contentID.description,
                namespace: namespace.value,
                excludingVariantDigest: nil
            )
            if !stillReferenced {
                do {
                    try await encodedStore.remove(
                        contentID: contentID.description,
                        namespace: namespace.value
                    )
                } catch {
                    await recordCacheCleanupFailure(
                        keyDigest: variantDigest,
                        reason: "commit-rollback-blob-removal-failed"
                    )
                }
            }
        }
    }

    private func recordCacheCleanupFailure(
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

    private func requireActive(
        _ generation: NamespaceGeneration,
        for namespace: SecurityNamespaceID
    ) async throws {
        guard await namespaceRegistry.isActive(generation, for: namespace) else {
            throw PipelineFailure.namespaceRevoked
        }
    }
}
extension ScopedRenderKey {
    fileprivate var renderedImageCacheKey: RenderedImageCacheKey {
        RenderedImageCacheKey(
            namespace: namespace,
            generation: generation,
            renderKey: renderKey
        )
    }
}
