import AkashicCore
import AkashicMemory
import Foundation
import FoveaHTTP
import ImageCraftCore

final class PipelineCache: Sendable {
  private let encodedStore: any OriginalEncodedStoring
  private let recordStore: any RepresentationRecordStoring
  private let memory: MemoryCache<ScopedRenderKey, DecodedImage>
  private let mutationPermits: AsyncPermitPool
  private let namespaceRegistry: NamespaceRegistry
  private let diagnostics: any DiagnosticsSink

  init(
    encodedStore: any OriginalEncodedStoring,
    recordStore: any RepresentationRecordStoring,
    memoryCostLimit: Int,
    mutationQueueLimit: Int,
    namespaceRegistry: NamespaceRegistry,
    diagnostics: any DiagnosticsSink
  ) {
    self.encodedStore = encodedStore
    self.recordStore = recordStore
    self.memory = MemoryCache(costLimit: memoryCostLimit)
    self.mutationPermits = AsyncPermitPool(limit: 1, queueLimit: max(1, mutationQueueLimit))
    self.namespaceRegistry = namespaceRegistry
    self.diagnostics = diagnostics
  }

  func records(
    for baseKeyDigest: String,
    namespace: SecurityNamespaceID,
    generation: NamespaceGeneration
  ) async -> [RepresentationRecord] {
    await recordStore.records(
      for: baseKeyDigest,
      namespace: namespace.value,
      namespaceGeneration: generation.value
    )
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
      do {
        try await recordStore.remove(
          newRecord.variantKeyDigest,
          namespace: namespace.value,
          namespaceGeneration: generation.value
        )
      } catch {
        await recordCacheCleanupFailure(
          keyDigest: newRecord.variantKeyDigest,
          reason: "record-refresh-rollback-failed"
        )
      }
      throw originalError
    }
  }

  func renderedImage(for key: ScopedRenderKey) async -> DecodedImage? {
    await memory.value(for: key)
  }

  func insertRendered(_ image: DecodedImage, for key: ScopedRenderKey) async {
    await memory.insert(image, for: key, cost: image.estimatedByteCost)
  }

  func removeRendered(_ key: ScopedRenderKey) async {
    await memory.remove(key)
  }

  func cleanup(namespace: SecurityNamespaceID) async -> Bool {
    await memory.removeAll { $0.namespace == namespace }

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

  func discardReusableState(
    record: RepresentationRecord,
    namespace: SecurityNamespaceID,
    generation: NamespaceGeneration
  ) async {
    await memory.removeAll {
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

  func commit(
    data: Data,
    contentID: ContentID,
    record: RepresentationRecord,
    image: DecodedImage,
    renderKey: ScopedRenderKey,
    admitRendered: Bool,
    namespace: SecurityNamespaceID,
    generation: NamespaceGeneration
  ) async throws {
    let permit: AsyncPermitPool.Permit
    do {
      permit = try await mutationPermits.acquire()
    } catch is CancellationError {
      throw CancellationError()
    } catch PermitPoolError.queueLimitExceeded {
      await diagnostics.record(
        DiagnosticEvent(
          kind: .cacheWriteFailed,
          keyDigest: record.variantKeyDigest,
          reason: "cache-mutation-queue-limit"
        )
      )
      return
    }

    do {
      try await commitWhileHoldingMutationPermit(
        data: data,
        contentID: contentID,
        record: record,
        image: image,
        renderKey: renderKey,
        admitRendered: admitRendered,
        namespace: namespace,
        generation: generation
      )
      await permit.release()
    } catch {
      await permit.release()
      throw error
    }
  }

  func garbageCollect() async throws -> GarbageCollectionResult {
    guard let recordMaintenance = recordStore as? any RepresentationRecordMaintaining,
      let encodedMaintenance = encodedStore as? any OriginalEncodedMaintaining
    else {
      throw PipelineFailure.cacheMaintenanceUnavailable
    }

    let permit = try await mutationPermits.acquire()
    do {
      let references = await recordMaintenance.contentReferences()
      let result = try await encodedMaintenance.garbageCollect(retaining: references)
      await permit.release()
      return result
    } catch {
      await permit.release()
      throw error
    }
  }

  private func commitWhileHoldingMutationPermit(
    data: Data,
    contentID: ContentID,
    record: RepresentationRecord,
    image: DecodedImage,
    renderKey: ScopedRenderKey,
    admitRendered: Bool,
    namespace: SecurityNamespaceID,
    generation: NamespaceGeneration
  ) async throws {
    var createdBlob = false
    var recordCommitted = false
    var renderedCommitted = false

    do {
      try Task.checkCancellation()
      let stored = try await encodedStore.commit(
        data: data,
        contentID: contentID.description,
        namespace: namespace.value
      )
      createdBlob = stored.wasCreated
      try Task.checkCancellation()
      try await requireActive(generation, for: namespace)

      try await recordStore.put(record)
      recordCommitted = true
      try Task.checkCancellation()
      try await requireActive(generation, for: namespace)

      if admitRendered {
        await memory.insert(image, for: renderKey, cost: image.estimatedByteCost)
        renderedCommitted = true
        try Task.checkCancellation()
        try await requireActive(generation, for: namespace)
      }
    } catch let failure as PipelineFailure where failure.category == .namespaceRevoked {
      await rollback(
        createdBlob: createdBlob,
        recordCommitted: recordCommitted,
        renderedCommitted: renderedCommitted,
        contentID: contentID,
        variantDigest: record.variantKeyDigest,
        renderKey: renderKey,
        namespace: namespace
      )
      throw PipelineFailure.namespaceRevoked
    } catch is CancellationError {
      await rollback(
        createdBlob: createdBlob,
        recordCommitted: recordCommitted,
        renderedCommitted: renderedCommitted,
        contentID: contentID,
        variantDigest: record.variantKeyDigest,
        renderKey: renderKey,
        namespace: namespace
      )
      throw CancellationError()
    } catch {
      await rollback(
        createdBlob: createdBlob,
        recordCommitted: recordCommitted,
        renderedCommitted: renderedCommitted,
        contentID: contentID,
        variantDigest: record.variantKeyDigest,
        renderKey: renderKey,
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
    recordCommitted: Bool,
    renderedCommitted: Bool,
    contentID: ContentID,
    variantDigest: String,
    renderKey: ScopedRenderKey,
    namespace: SecurityNamespaceID
  ) async {
    if renderedCommitted { await memory.remove(renderKey) }
    if recordCommitted {
      do {
        try await recordStore.remove(
          variantDigest,
          namespace: namespace.value,
          namespaceGeneration: renderKey.generation.value
        )
      } catch {
        await recordCacheCleanupFailure(
          keyDigest: variantDigest,
          reason: "commit-rollback-record-removal-failed"
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
