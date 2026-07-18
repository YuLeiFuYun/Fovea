import AkashicCore
import Foundation
import FoveaHTTP
import ImageCraftCore

public final class FoveaPipeline: Sendable {
  private let cache: PipelineCache
  private let fetchStage: FetchStage
  private let decodeStage: DecodeStage
  private let namespaceRegistry: NamespaceRegistry
  private let diagnostics: any DiagnosticsSink
  private let clock: any WallClock

  public convenience init(
    configuration: PipelineConfiguration = PipelineConfiguration(),
    transport: any HTTPTransporting,
    encodedStore: any OriginalEncodedStoring,
    recordStore: any RepresentationRecordStoring,
    memoryCacheCostLimit: Int = 64 * 1024 * 1024,
    diagnostics: any DiagnosticsSink = NullDiagnosticsSink(),
    decoder: any ImageDecoding
  ) {
    self.init(
      configuration: configuration,
      transport: transport,
      encodedStore: encodedStore,
      recordStore: recordStore,
      memoryCacheCostLimit: memoryCacheCostLimit,
      namespaceRegistry: NamespaceRegistry(),
      diagnostics: diagnostics,
      decoder: decoder,
      clock: SystemWallClock()
    )
  }

  package init(
    configuration: PipelineConfiguration = PipelineConfiguration(),
    transport: any HTTPTransporting,
    encodedStore: any OriginalEncodedStoring,
    recordStore: any RepresentationRecordStoring,
    memoryCacheCostLimit: Int = 64 * 1024 * 1024,
    namespaceRegistry: NamespaceRegistry,
    diagnostics: any DiagnosticsSink = NullDiagnosticsSink(),
    decoder: any ImageDecoding,
    clock: any WallClock = SystemWallClock()
  ) {
    let diagnostics = pipelineDiagnosticsSink(diagnostics)
    self.namespaceRegistry = namespaceRegistry
    self.diagnostics = diagnostics
    self.clock = clock
    self.cache = PipelineCache(
      encodedStore: encodedStore,
      recordStore: recordStore,
      memoryCostLimit: memoryCacheCostLimit,
      namespaceRegistry: namespaceRegistry,
      diagnostics: diagnostics
    )
    self.fetchStage = FetchStage(
      configuration: configuration,
      transport: transport,
      diagnostics: diagnostics,
      clock: clock,
      namespaceRegistry: namespaceRegistry
    )
    self.decodeStage = DecodeStage(
      decoder: decoder,
      limits: configuration.decodeLimits,
      diagnostics: diagnostics,
      maximumConcurrentDecodes: configuration.maximumConcurrentDecodes,
      maximumQueuedDecodes: configuration.maximumQueuedDecodes
    )
  }

  @concurrent
  public func image(for request: ImageRequest) async throws -> DecodedImage {
    if request.containsCredentialHeaders,
      request.authorizationContext == .public || request.credentialGeneration == nil
    {
      let failure = PipelineFailure.missingAuthorizationContext
      await record(failure)
      throw failure
    }

    do {
      return try await load(request: request, variant: request.fetchVariantKey)
    } catch let failure as PipelineFailure {
      await record(failure)
      throw failure
    } catch is CancellationError {
      let failure = PipelineFailure.cancelled(stage: .pipeline)
      await record(failure)
      throw failure
    } catch {
      let failure = PipelineFailure.internalFailure(stage: .pipeline)
      await record(failure)
      throw failure
    }
  }

  public func revoke(namespace: SecurityNamespaceID) async throws {
    _ = await namespaceRegistry.revoke(namespace)
    await fetchStage.cancelAll(namespace: namespace)
    let cleanupFailed = await cache.cleanup(namespace: namespace)
    await diagnostics.record(
      DiagnosticEvent(
        kind: .namespaceRevoked,
        reason: cleanupFailed ? "persistent-cleanup-failed" : nil
      )
    )
    if cleanupFailed { throw PipelineFailure.namespaceCleanupFailed }
  }

  private func load(request: ImageRequest, variant: FetchVariantKey) async throws -> DecodedImage {
    let generation = await namespaceRegistry.generation(for: request.namespace)
    let now = await clock.now()
    var existing = await cache.record(
      for: variant.digestHex,
      namespace: request.namespace,
      generation: generation
    )

    if let record = existing, record.isFresh(at: now), record.disposition != .noStore {
      let cachedData: Data?
      do {
        cachedData = try await cache.read(record, namespace: request.namespace)
      } catch {
        await diagnostics.record(
          DiagnosticEvent(
            kind: .cacheReadFailed,
            keyDigest: variant.digestHex,
            reason: "original-encoded-read"
          )
        )
        await cache.removeRecord(
          variant.digestHex,
          namespace: request.namespace,
          generation: generation
        )
        existing = nil
        cachedData = nil
      }

      if let cachedData {
        await diagnostics.record(
          DiagnosticEvent(
            kind: .originalEncodedHit,
            keyDigest: variant.digestHex,
            byteCount: cachedData.count
          )
        )
        return try await decodeAndCache(
          data: cachedData,
          request: request,
          generation: generation,
          keyDigest: variant.digestHex
        )
      }
    }

    let response = try await fetchStage.response(
      for: request,
      conditionalRecord: existing,
      generation: generation
    )
    guard response.head.statusCode == 304 else {
      return try await process200(
        response,
        request: request,
        variant: variant,
        generation: generation
      )
    }

    return try await process304(
      response,
      existing: existing,
      request: request,
      variant: variant,
      generation: generation
    )
  }

  private func process304(
    _ response: TimedTransportResponse,
    existing: RepresentationRecord?,
    request: ImageRequest,
    variant: FetchVariantKey,
    generation: NamespaceGeneration
  ) async throws -> DecodedImage {
    guard let existing else { throw PipelineFailure.missingCachedBody }
    let cachedData: Data
    do {
      cachedData = try await cache.read(existing, namespace: request.namespace)
    } catch {
      await diagnostics.record(
        DiagnosticEvent(
          kind: .cacheReadFailed,
          keyDigest: variant.digestHex,
          reason: "validated-body-read"
        )
      )
      await cache.removeRecord(
        variant.digestHex,
        namespace: request.namespace,
        generation: generation
      )
      let retry = try await fetchStage.response(
        for: request,
        conditionalRecord: nil,
        generation: generation
      )
      return try await process200(
        retry,
        request: request,
        variant: variant,
        generation: generation
      )
    }

    await diagnostics.record(
      DiagnosticEvent(
        kind: .originalEncodedHit,
        keyDigest: variant.digestHex,
        byteCount: cachedData.count
      )
    )
    try await requireActive(generation, for: request.namespace)

    let responseOverridesDisposition =
      HTTPCachePolicy.header("Cache-Control", in: response.head.headers) != nil
      || HTTPCachePolicy.header("Vary", in: response.head.headers) != nil
    let refreshedDisposition =
      responseOverridesDisposition
      ? HTTPCachePolicy.disposition(
        headers: response.head.headers,
        isPrivateNamespace: request.authorizationContext != .public
      )
      : existing.disposition

    if refreshedDisposition == .noStore {
      await cache.discardReusableState(
        record: existing,
        variantDigest: variant.digestHex,
        namespace: request.namespace,
        generation: generation
      )
      let image = try await decodeStage.image(
        from: cachedData,
        request: request,
        keyDigest: variant.digestHex
      )
      try Task.checkCancellation()
      try await requireActive(generation, for: request.namespace)
      return image
    }

    let refreshed = RepresentationRecord(
      securityNamespace: request.namespace.value,
      namespaceGeneration: generation.value,
      variantKeyDigest: variant.digestHex,
      statusCode: existing.statusCode,
      requestTime: response.requestTime,
      responseTime: response.responseTime,
      expiresAt: HTTPCachePolicy.expiration(
        requestTime: response.requestTime,
        responseTime: response.responseTime,
        headers: response.head.headers
      ) ?? existing.expiresAt,
      etag: HTTPCachePolicy.header("ETag", in: response.head.headers) ?? existing.etag,
      lastModified: HTTPCachePolicy.header("Last-Modified", in: response.head.headers)
        ?? existing.lastModified,
      disposition: refreshedDisposition,
      contentID: existing.contentID,
      payloadLength: existing.payloadLength,
      contentType: existing.contentType
    )
    try await refreshRecord(
      refreshed,
      namespace: request.namespace,
      generation: generation
    )

    return try await decodeAndCache(
      data: cachedData,
      request: request,
      generation: generation,
      keyDigest: variant.digestHex
    )
  }

  private func process200(
    _ response: TimedTransportResponse,
    request: ImageRequest,
    variant: FetchVariantKey,
    generation: NamespaceGeneration
  ) async throws -> DecodedImage {
    try Task.checkCancellation()
    guard response.head.statusCode == 200 else {
      throw PipelineFailure.unsupportedStatus(response.head.statusCode)
    }
    if let contentType = response.head.value(forHeader: "Content-Type") {
      guard contentType.lowercased().hasPrefix("image/") else {
        throw PipelineFailure.nonImageResponse
      }
    } else {
      await diagnostics.record(
        DiagnosticEvent(
          kind: .responseAnomaly,
          keyDigest: variant.digestHex,
          reason: "missing-content-type"
        )
      )
    }

    let image = try await decodeStage.image(
      from: response.transport.body,
      request: request,
      keyDigest: variant.digestHex
    )
    try Task.checkCancellation()
    let contentID: ContentID
    do {
      contentID = try ContentID(
        digestHex: response.transport.digestHex,
        byteCount: response.transport.body.count
      )
    } catch {
      throw PipelineFailure.invalidContentDigest
    }
    let disposition = HTTPCachePolicy.disposition(
      headers: response.head.headers,
      isPrivateNamespace: request.authorizationContext != .public
    )

    try await requireActive(generation, for: request.namespace)

    if disposition != .noStore {
      let record = RepresentationRecord(
        securityNamespace: request.namespace.value,
        namespaceGeneration: generation.value,
        variantKeyDigest: variant.digestHex,
        statusCode: 200,
        requestTime: response.requestTime,
        responseTime: response.responseTime,
        expiresAt: HTTPCachePolicy.expiration(
          requestTime: response.requestTime,
          responseTime: response.responseTime,
          headers: response.head.headers
        ),
        etag: response.head.value(forHeader: "ETag"),
        lastModified: response.head.value(forHeader: "Last-Modified"),
        disposition: disposition,
        contentID: contentID.description,
        payloadLength: response.transport.body.count,
        contentType: response.head.value(forHeader: "Content-Type")
      )
      try await cache.commit(
        data: response.transport.body,
        contentID: contentID,
        record: record,
        image: image,
        renderKey: scopedRenderKey(
          contentID: contentID,
          request: request,
          generation: generation
        ),
        namespace: request.namespace,
        generation: generation
      )
    }

    try Task.checkCancellation()
    try await requireActive(generation, for: request.namespace)
    return image
  }

  private func decodeAndCache(
    data: Data,
    request: ImageRequest,
    generation: NamespaceGeneration,
    keyDigest: String
  ) async throws -> DecodedImage {
    try Task.checkCancellation()
    try await requireActive(generation, for: request.namespace)
    let contentID = ContentID(data: data)
    let key = scopedRenderKey(contentID: contentID, request: request, generation: generation)
    if let cached = await cache.renderedImage(for: key) {
      guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
        await cache.removeRendered(key)
        throw PipelineFailure.namespaceRevoked
      }
      try Task.checkCancellation()
      await diagnostics.record(
        DiagnosticEvent(
          kind: .renderedMemoryHit,
          keyDigest: keyDigest,
          outputPixelCount: Self.pixelCount(width: cached.pixelWidth, height: cached.pixelHeight),
          targetWidth: request.target.width,
          targetHeight: request.target.height
        )
      )
      return cached
    }

    let image = try await decodeStage.image(from: data, request: request, keyDigest: keyDigest)
    try Task.checkCancellation()
    try await requireActive(generation, for: request.namespace)
    await cache.insertRendered(image, for: key)
    guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
      await cache.removeRendered(key)
      throw PipelineFailure.namespaceRevoked
    }
    try Task.checkCancellation()
    return image
  }

  private func refreshRecord(
    _ record: RepresentationRecord,
    namespace: SecurityNamespaceID,
    generation: NamespaceGeneration
  ) async throws {
    do {
      try await cache.refresh(record, namespace: namespace, generation: generation)
    } catch let failure as PipelineFailure where failure.category == .namespaceRevoked {
      throw failure
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      await diagnostics.record(
        DiagnosticEvent(
          kind: .cacheWriteFailed,
          keyDigest: record.variantKeyDigest,
          reason: "record-refresh-write"
        )
      )
    }
  }

  private func record(_ failure: PipelineFailure) async {
    await diagnostics.record(
      DiagnosticEvent(
        kind: .pipelineFailed,
        statusCode: failure.statusCode,
        reason: failure.reasonCode,
        failureCategory: failure.category,
        failureStage: failure.stage,
        failureDisposition: failure.disposition
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

  private func scopedRenderKey(
    contentID: ContentID,
    request: ImageRequest,
    generation: NamespaceGeneration
  ) -> ScopedRenderKey {
    let decode = DecodeKey(
      contentID: contentID,
      targetWidth: request.target.width,
      targetHeight: request.target.height,
      decoderVersion: 1
    )
    return ScopedRenderKey(
      namespace: request.namespace,
      generation: generation,
      renderKey: RenderKey(decodeKey: decode, renderVersion: 1)
    )
  }

  private static func pixelCount(width: Int, height: Int) -> Int {
    let (result, overflow) = width.multipliedReportingOverflow(by: height)
    return overflow ? Int.max : result
  }
}
