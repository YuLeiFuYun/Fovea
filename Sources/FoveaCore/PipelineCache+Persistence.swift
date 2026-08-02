import AkashicCore
import AkashicMemory
import Foundation
import FoveaHTTP
import FoveaStorage
import ImageCraftCore

/// 描述原始编码数据在进入可见持久状态前的准备结果。
///
/// 本文件只负责 encoded blob 与 representation record 的两阶段发布、回滚和垃圾回收；
/// 网络响应判定、图像验证与渲染内存发布仍由上层协调器负责，禁止在此绕过 namespace 代际检查。
enum OriginalCommitPreparation: Sendable {
    case staged(OriginalEncodedStage)
    case deferred(Data)
}

extension PipelineCache {
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

}
