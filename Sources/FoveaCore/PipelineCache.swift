import AkashicCore
import AkashicMemory
import Foundation
import FoveaHTTP
import ImageCraftCore

final class PipelineCache: Sendable {
  private let encodedStore: any OriginalEncodedStoring
  private let recordStore: any RepresentationRecordStoring
  private let memory: MemoryCache<ScopedRenderKey, DecodedImage>
  private let namespaceRegistry: NamespaceRegistry
  private let diagnostics: any DiagnosticsSink

  init(
    encodedStore: any OriginalEncodedStoring,
    recordStore: any RepresentationRecordStoring,
    memoryCostLimit: Int,
    namespaceRegistry: NamespaceRegistry,
    diagnostics: any DiagnosticsSink
  ) {
    self.encodedStore = encodedStore
    self.recordStore = recordStore
    self.memory = MemoryCache(costLimit: memoryCostLimit)
    self.namespaceRegistry = namespaceRegistry
    self.diagnostics = diagnostics
  }

  func record(
    for variantDigest: String,
    namespace: SecurityNamespaceID,
    generation: NamespaceGeneration
  ) async -> RepresentationRecord? {
    await recordStore.record(
      for: variantDigest,
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
    try? await recordStore.remove(
      variantDigest,
      namespace: namespace.value,
      namespaceGeneration: generation.value
    )
  }

  func refresh(
    _ record: RepresentationRecord,
    namespace: SecurityNamespaceID,
    generation: NamespaceGeneration
  ) async throws {
    try Task.checkCancellation()
    try await recordStore.put(record)
    do {
      try Task.checkCancellation()
      try await requireActive(generation, for: namespace)
    } catch {
      try? await recordStore.remove(
        record.variantKeyDigest,
        namespace: namespace.value,
        namespaceGeneration: generation.value
      )
      throw error
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
    variantDigest: String,
    namespace: SecurityNamespaceID,
    generation: NamespaceGeneration
  ) async {
    await memory.removeAll {
      $0.namespace == namespace && $0.generation == generation
    }
    try? await encodedStore.remove(contentID: record.contentID, namespace: namespace.value)
    try? await recordStore.remove(
      variantDigest,
      namespace: namespace.value,
      namespaceGeneration: generation.value
    )
  }

  func commit(
    data: Data,
    contentID: ContentID,
    record: RepresentationRecord,
    image: DecodedImage,
    renderKey: ScopedRenderKey,
    namespace: SecurityNamespaceID,
    generation: NamespaceGeneration
  ) async throws {
    var blobCommitted = false
    var recordCommitted = false
    var renderedCommitted = false

    do {
      try Task.checkCancellation()
      _ = try await encodedStore.commit(
        data: data,
        contentID: contentID.description,
        namespace: namespace.value
      )
      blobCommitted = true
      try Task.checkCancellation()
      try await requireActive(generation, for: namespace)

      try await recordStore.put(record)
      recordCommitted = true
      try Task.checkCancellation()
      try await requireActive(generation, for: namespace)

      await memory.insert(image, for: renderKey, cost: image.estimatedByteCost)
      renderedCommitted = true
      try Task.checkCancellation()
      try await requireActive(generation, for: namespace)
    } catch let failure as PipelineFailure where failure.category == .namespaceRevoked {
      await rollback(
        blobCommitted: blobCommitted,
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
        blobCommitted: blobCommitted,
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
        blobCommitted: blobCommitted,
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
    blobCommitted: Bool,
    recordCommitted: Bool,
    renderedCommitted: Bool,
    contentID: ContentID,
    variantDigest: String,
    renderKey: ScopedRenderKey,
    namespace: SecurityNamespaceID
  ) async {
    if renderedCommitted { await memory.remove(renderKey) }
    if recordCommitted {
      try? await recordStore.remove(
        variantDigest,
        namespace: namespace.value,
        namespaceGeneration: renderKey.generation.value
      )
    }
    if blobCommitted {
      try? await encodedStore.remove(
        contentID: contentID.description,
        namespace: namespace.value
      )
    }
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
