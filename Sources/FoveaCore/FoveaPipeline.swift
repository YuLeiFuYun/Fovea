import AkashicCore
import Foundation
import FoveaHTTP
import ImageCraftCore

public final class FoveaPipeline: ImageLoading, EncodedDataLoading, Sendable {
  public let id: PipelineID
  public let configuration: PipelineConfiguration

  private let cache: PipelineCache
  private let transportReusePolicy: TransportReusePolicy
  private let fetchStage: FetchStage
  private let decodeStage: DecodeStage
  private let transformStage: TransformStage
  private let namespaceRegistry: NamespaceRegistry
  private let diagnostics: any DiagnosticsSink
  private let clock: any WallClock

  public convenience init(
    configuration: PipelineConfiguration = PipelineConfiguration(),
    transport: any HTTPTransporting,
    encodedStore: any OriginalEncodedStoring,
    recordStore: any RepresentationRecordStoring,
    diagnostics: any DiagnosticsSink = NullDiagnosticsSink(),
    decoder: any ImageDecoding,
    transformer: any ImageTransforming = IdentityImageTransformer()
  ) {
    self.init(
      id: PipelineID(),
      configuration: configuration,
      transport: transport,
      encodedStore: encodedStore,
      recordStore: recordStore,
      namespaceRegistry: NamespaceRegistry(),
      diagnostics: diagnostics,
      decoder: decoder,
      transformer: transformer,
      clock: SystemWallClock(),
      retrySleeper: SystemRetrySleeper(),
      retryJitter: SystemRetryJitter()
    )
  }

  package init(
    id: PipelineID = PipelineID(),
    configuration: PipelineConfiguration = PipelineConfiguration(),
    transport: any HTTPTransporting,
    encodedStore: any OriginalEncodedStoring,
    recordStore: any RepresentationRecordStoring,
    namespaceRegistry: NamespaceRegistry,
    diagnostics: any DiagnosticsSink = NullDiagnosticsSink(),
    decoder: any ImageDecoding,
    transformer: any ImageTransforming = IdentityImageTransformer(),
    clock: any WallClock = SystemWallClock(),
    retrySleeper: any RetrySleeping = SystemRetrySleeper(),
    retryJitter: any RetryJittering = SystemRetryJitter()
  ) {
    self.id = id
    self.configuration = configuration
    self.transportReusePolicy = transport.reusePolicy
    let diagnostics = pipelineDiagnosticsSink(diagnostics)
    self.namespaceRegistry = namespaceRegistry
    self.diagnostics = diagnostics
    self.clock = clock
    let mutationQueueLimit = Self.saturatedSum([
      configuration.maximumConcurrentFetches,
      configuration.maximumQueuedFetches,
      configuration.maximumConcurrentDecodes,
      configuration.maximumQueuedDecodes,
      1,
    ])
    self.cache = PipelineCache(
      encodedStore: encodedStore,
      recordStore: recordStore,
      memoryCostLimit: configuration.memoryCostLimit,
      mutationQueueLimit: mutationQueueLimit,
      namespaceRegistry: namespaceRegistry,
      diagnostics: diagnostics
    )
    self.fetchStage = FetchStage(
      configuration: configuration,
      transport: transport,
      diagnostics: diagnostics,
      clock: clock,
      namespaceRegistry: namespaceRegistry,
      retrySleeper: retrySleeper,
      retryJitter: retryJitter
    )
    self.decodeStage = DecodeStage(
      decoder: decoder,
      limits: configuration.decodeLimits,
      diagnostics: diagnostics,
      maximumConcurrentDecodes: configuration.maximumConcurrentDecodes,
      maximumQueuedDecodes: configuration.maximumQueuedDecodes
    )
    self.transformStage = TransformStage(transformer: transformer)
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
      return try await load(request: request)
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

  public func encodedData(for request: ImageRequest) async throws -> Data {
    if request.containsCredentialHeaders,
      request.authorizationContext == .public || request.credentialGeneration == nil
    {
      let failure = PipelineFailure.missingAuthorizationContext
      await record(failure)
      throw failure
    }

    do {
      return try await loadEncodedData(request: request)
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

  /// 回收未被表征记录引用的持久化数据块。
  /// 自定义存储必须同时实现对应的维护协议，否则以结构化能力错误失败。
  public func garbageCollectCaches() async throws -> GarbageCollectionResult {
    do {
      return try await cache.garbageCollect()
    } catch let failure as PipelineFailure {
      throw failure
    } catch is CancellationError {
      throw PipelineFailure.cancelled(stage: .persistence)
    } catch {
      throw PipelineFailure(
        category: .cacheWrite,
        stage: .persistence,
        disposition: .cacheDegraded,
        reasonCode: "cache-garbage-collection-failed"
      )
    }
  }

  public func revoke(namespace: SecurityNamespaceID) async throws {
    _ = await namespaceRegistry.revoke(namespace)
    await fetchStage.cancelAll(namespace: namespace)
    await decodeStage.cancelAll(namespace: namespace)
    let cleanupFailed = await cache.cleanup(namespace: namespace)
    await diagnostics.record(
      DiagnosticEvent(
        kind: .namespaceRevoked,
        reason: cleanupFailed ? "persistent-cleanup-failed" : nil
      )
    )
    if cleanupFailed { throw PipelineFailure.namespaceCleanupFailed }
  }

  private func loadEncodedData(request: ImageRequest) async throws -> Data {
    let generation = await namespaceRegistry.generation(for: request.namespace)
    if transportReusePolicy.allowsCrossRequestReuse {
      let candidates = await cache.records(
        for: request.fetchBaseKey.digestHex,
        namespace: request.namespace,
        generation: generation
      )
      if let record = HTTPCachePolicy.selectRecord(
        from: candidates,
        requestHeaders: request.headers,
        additionalSensitiveNames: request.credentialHeaderNames,
        sensitiveFingerprints: request.headerVariantFingerprints
      ), record.isFresh(at: await clock.now()), record.disposition != .noStore {
        do {
          let data = try await cache.read(record, namespace: request.namespace)
          await diagnostics.record(
            DiagnosticEvent(
              kind: .originalEncodedHit,
              keyDigest: record.variantKeyDigest,
              byteCount: data.count
            )
          )
          return data
        } catch {
          await diagnostics.record(
            DiagnosticEvent(
              kind: .cacheReadFailed,
              keyDigest: record.variantKeyDigest,
              reason: "encoded-data-read"
            )
          )
          await cache.removeRecord(
            record.variantKeyDigest,
            namespace: request.namespace,
            generation: generation
          )
        }
      }
    }

    guard request.cachePolicy != .onlyIfCached else {
      throw PipelineFailure.onlyIfCachedMiss
    }
    let response = try await fetchStage.response(
      for: request,
      conditionalRecord: nil,
      generation: generation
    )
    try Task.checkCancellation()
    try await requireActive(generation, for: request.namespace)
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
          keyDigest: request.fetchBaseKey.digestHex,
          reason: "missing-content-type"
        )
      )
    }
    do {
      _ = try ContentID(
        digestHex: response.transport.digestHex,
        byteCount: response.transport.body.count
      )
    } catch {
      throw PipelineFailure.invalidContentDigest
    }
    return response.transport.body
  }

  private func load(request: ImageRequest) async throws -> DecodedImage {
    let generation = await namespaceRegistry.generation(for: request.namespace)
    if !transportReusePolicy.allowsCrossRequestReuse {
      guard request.cachePolicy != .onlyIfCached else {
        throw PipelineFailure.onlyIfCachedMiss
      }
      let response = try await fetchStage.response(
        for: request,
        conditionalRecord: nil,
        generation: generation
      )
      return try await process200(
        response,
        request: request,
        generation: generation,
        allowReusableState: false
      )
    }
    let baseKey = request.fetchBaseKey
    let now = await clock.now()
    let candidates = await cache.records(
      for: baseKey.digestHex,
      namespace: request.namespace,
      generation: generation
    )
    var existing = HTTPCachePolicy.selectRecord(
      from: candidates,
      requestHeaders: request.headers,
      additionalSensitiveNames: request.credentialHeaderNames,
      sensitiveFingerprints: request.headerVariantFingerprints
    )

    if let record = existing, record.isFresh(at: now), record.disposition != .noStore {
      let cachedData: Data?
      do {
        cachedData = try await cache.read(record, namespace: request.namespace)
      } catch {
        await diagnostics.record(
          DiagnosticEvent(
            kind: .cacheReadFailed,
            keyDigest: record.variantKeyDigest,
            reason: "original-encoded-read"
          )
        )
        await cache.removeRecord(
          record.variantKeyDigest,
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
            keyDigest: record.variantKeyDigest,
            byteCount: cachedData.count
          )
        )
        return try await decodeAndCache(
          data: cachedData,
          request: request,
          generation: generation,
          keyDigest: record.variantKeyDigest
        )
      }
    }

    guard request.cachePolicy != .onlyIfCached else {
      throw PipelineFailure.onlyIfCachedMiss
    }

    do {
      let response = try await fetchStage.response(
        for: request,
        conditionalRecord: existing,
        generation: generation
      )
      guard response.head.statusCode == 304 else {
        return try await process200(
          response,
          request: request,
          generation: generation
        )
      }

      return try await process304(
        response,
        existing: existing,
        request: request,
        generation: generation
      )
    } catch let failure as PipelineFailure {
      if let existing,
        let stale = try await staleFallback(
          record: existing,
          request: request,
          generation: generation,
          after: failure
        )
      {
        return stale
      }
      throw failure
    }
  }

  private func staleFallback(
    record: RepresentationRecord,
    request: ImageRequest,
    generation: NamespaceGeneration,
    after failure: PipelineFailure
  ) async throws -> DecodedImage? {
    let now = await clock.now()
    guard request.stalePolicy != .disallow,
      configuration.staleFallbackPolicy.permits(
        record: record,
        at: now,
        after: failure
      )
    else { return nil }

    try Task.checkCancellation()
    try await requireActive(generation, for: request.namespace)
    let data: Data
    do {
      data = try await cache.read(record, namespace: request.namespace)
    } catch {
      await diagnostics.record(
        DiagnosticEvent(
          kind: .cacheReadFailed,
          keyDigest: record.variantKeyDigest,
          reason: "stale-fallback-read"
        )
      )
      await cache.removeRecord(
        record.variantKeyDigest,
        namespace: request.namespace,
        generation: generation
      )
      return nil
    }

    await diagnostics.record(
      DiagnosticEvent(
        kind: .staleFallbackUsed,
        keyDigest: record.variantKeyDigest,
        statusCode: failure.statusCode,
        byteCount: data.count,
        reason: failure.reasonCode
      )
    )
    return try await decodeAndCache(
      data: data,
      request: request,
      generation: generation,
      keyDigest: record.variantKeyDigest
    )
  }

  private func process304(
    _ response: TimedTransportResponse,
    existing: RepresentationRecord?,
    request: ImageRequest,
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
          keyDigest: existing.variantKeyDigest,
          reason: "validated-body-read"
        )
      )
      await cache.removeRecord(
        existing.variantKeyDigest,
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
        generation: generation
      )
    }

    await diagnostics.record(
      DiagnosticEvent(
        kind: .originalEncodedHit,
        keyDigest: existing.variantKeyDigest,
        byteCount: cachedData.count
      )
    )
    try await requireActive(generation, for: request.namespace)

    let cacheControlPresent =
      HTTPCachePolicy.header("Cache-Control", in: response.head.headers) != nil
    let varyHeaderPresent = HTTPCachePolicy.header("Vary", in: response.head.headers) != nil
    let responseOverridesDisposition = cacheControlPresent || varyHeaderPresent
    let varySelection: HTTPVarySelection?
    if varyHeaderPresent {
      switch HTTPCachePolicy.varyFieldNames(in: response.head.headers) {
      case .wildcard:
        varySelection = nil
      case .fields(let fields):
        varySelection = request.varySelection(fieldNames: fields)
      }
    } else {
      varySelection = existing.vary
    }
    let refreshedDisposition =
      responseOverridesDisposition
      ? HTTPCachePolicy.disposition(
        headers: response.head.headers,
        isPrivateNamespace: request.authorizationContext != .public,
        varySelectionAvailable: varySelection != nil
      )
      : existing.disposition

    if refreshedDisposition == .noStore {
      await cache.discardReusableState(
        record: existing,
        namespace: request.namespace,
        generation: generation
      )
      let decoded = try await decodeStage.image(
        from: cachedData,
        contentID: ContentID(data: cachedData),
        request: request,
        generation: generation,
        keyDigest: existing.variantKeyDigest
      )
      let image = try await transformStage.image(from: decoded)
      try Task.checkCancellation()
      try await requireActive(generation, for: request.namespace)
      return image
    }

    let selectedVary = varySelection ?? existing.vary
    let refreshedVariant = request.fetchVariantKey(for: selectedVary)
    let refreshed = RepresentationRecord(
      securityNamespace: request.namespace.value,
      namespaceGeneration: generation.value,
      baseKeyDigest: request.fetchBaseKey.digestHex,
      variantKeyDigest: refreshedVariant.digestHex,
      vary: selectedVary,
      statusCode: existing.statusCode,
      requestTime: response.requestTime,
      responseTime: response.responseTime,
      responseDate: HTTPCachePolicy.responseDate(in: response.head.headers)
        ?? existing.responseDate,
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
      replacing: existing,
      with: refreshed,
      namespace: request.namespace,
      generation: generation
    )

    return try await decodeAndCache(
      data: cachedData,
      request: request,
      generation: generation,
      keyDigest: refreshed.variantKeyDigest
    )
  }

  private func process200(
    _ response: TimedTransportResponse,
    request: ImageRequest,
    generation: NamespaceGeneration,
    allowReusableState: Bool = true
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
          keyDigest: request.fetchBaseKey.digestHex,
          reason: "missing-content-type"
        )
      )
    }

    let varySelection: HTTPVarySelection?
    switch HTTPCachePolicy.varyFieldNames(in: response.head.headers) {
    case .wildcard:
      varySelection = nil
    case .fields(let fields):
      varySelection = request.varySelection(fieldNames: fields)
    }
    let variant = request.fetchVariantKey(
      for: varySelection ?? HTTPVarySelection(fieldNames: [], values: [:])
    )
    let contentID: ContentID
    do {
      contentID = try ContentID(
        digestHex: response.transport.digestHex,
        byteCount: response.transport.body.count
      )
    } catch {
      throw PipelineFailure.invalidContentDigest
    }
    let decoded = try await decodeStage.image(
      from: response.transport.body,
      contentID: contentID,
      request: request,
      generation: generation,
      keyDigest: variant.digestHex
    )
    try Task.checkCancellation()
    let disposition = HTTPCachePolicy.disposition(
      headers: response.head.headers,
      isPrivateNamespace: request.authorizationContext != .public,
      varySelectionAvailable: varySelection != nil
    )

    try await requireActive(generation, for: request.namespace)

    if allowReusableState, disposition != .noStore {
      let record = RepresentationRecord(
        securityNamespace: request.namespace.value,
        namespaceGeneration: generation.value,
        baseKeyDigest: request.fetchBaseKey.digestHex,
        variantKeyDigest: variant.digestHex,
        vary: varySelection ?? HTTPVarySelection(fieldNames: [], values: [:]),
        statusCode: 200,
        requestTime: response.requestTime,
        responseTime: response.responseTime,
        responseDate: HTTPCachePolicy.responseDate(in: response.head.headers),
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
      try await cache.commitOriginal(
        data: response.transport.body,
        contentID: contentID,
        record: record,
        namespace: request.namespace,
        generation: generation
      )
    }

    let image = try await transformStage.image(from: decoded)
    try Task.checkCancellation()
    try await requireActive(generation, for: request.namespace)
    if allowReusableState, disposition != .noStore,
      request.renderCacheAdmission == .stable
    {
      let renderKey = scopedRenderKey(
        contentID: contentID,
        request: request,
        generation: generation
      )
      await cache.insertRendered(image, for: renderKey)
      guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
        await cache.removeRendered(renderKey)
        throw PipelineFailure.namespaceRevoked
      }
    }
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

    let decoded = try await decodeStage.image(
      from: data,
      contentID: contentID,
      request: request,
      generation: generation,
      keyDigest: keyDigest
    )
    let image = try await transformStage.image(from: decoded)
    try Task.checkCancellation()
    try await requireActive(generation, for: request.namespace)
    if request.renderCacheAdmission == .stable {
      await cache.insertRendered(image, for: key)
      guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
        await cache.removeRendered(key)
        throw PipelineFailure.namespaceRevoked
      }
    }
    try Task.checkCancellation()
    return image
  }

  private func refreshRecord(
    replacing oldRecord: RepresentationRecord,
    with newRecord: RepresentationRecord,
    namespace: SecurityNamespaceID,
    generation: NamespaceGeneration
  ) async throws {
    do {
      try await cache.refresh(
        replacing: oldRecord,
        with: newRecord,
        namespace: namespace,
        generation: generation
      )
    } catch let failure as PipelineFailure where failure.category == .namespaceRevoked {
      throw failure
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      await diagnostics.record(
        DiagnosticEvent(
          kind: .cacheWriteFailed,
          keyDigest: newRecord.variantKeyDigest,
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
      contentMode: request.contentMode,
      geometryPolicyFingerprint: request.geometryPolicyFingerprint,
      colorPolicy: request.colorPolicy,
      decoderVersion: 1
    )
    return ScopedRenderKey(
      namespace: request.namespace,
      generation: generation,
      renderKey: RenderKey(
        decodeKey: decode,
        transformerFingerprint: transformStage.fingerprint,
        renderVersion: 1
      )
    )
  }

  private static func saturatedSum(_ values: [Int]) -> Int {
    values.reduce(0) { partial, value in
      let (sum, overflow) = partial.addingReportingOverflow(value)
      return overflow ? Int.max : sum
    }
  }

  private static func pixelCount(width: Int, height: Int) -> Int {
    let (result, overflow) = width.multipliedReportingOverflow(by: height)
    return overflow ? Int.max : result
  }
}
