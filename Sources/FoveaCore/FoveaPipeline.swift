import AkashicDisk
import AkashicMemory
import Foundation
import FoveaHTTP
import ImageCraftCore

private struct ScopedRenderKey: Hashable, Sendable {
  let namespace: SecurityNamespaceID
  let generation: NamespaceGeneration
  let renderKey: RenderKey
}

private struct ScopedFetchExecutionKey: Hashable, Sendable {
  let namespace: SecurityNamespaceID
  let execution: FetchExecutionKey
}

public final class FoveaPipeline: Sendable {
  private struct TimedTransportResponse: Sendable {
    let requestTime: Date
    let responseTime: Date
    let transport: TransportResponse
    var head: TransportResponseHead { transport.head }
  }

  private let configuration: PipelineConfiguration
  private let transport: any HTTPTransporting
  private let encodedStore: any OriginalEncodedStoring
  private let recordStore: any RepresentationRecordStoring
  private let memoryCache: RenderedMemoryCache<ScopedRenderKey>
  private let namespaceRegistry: NamespaceRegistry
  private let diagnostics: any DiagnosticsSink
  private let decoder: any ImageDecoding
  private let clock: any WallClock
  private let fetchTaskRegistry = SharedTaskRegistry<
    ScopedFetchExecutionKey, TimedTransportResponse
  >()

  public init(
    configuration: PipelineConfiguration = PipelineConfiguration(),
    transport: any HTTPTransporting,
    encodedStore: any OriginalEncodedStoring,
    recordStore: any RepresentationRecordStoring,
    memoryCacheCostLimit: Int = 64 * 1024 * 1024,
    namespaceRegistry: NamespaceRegistry = NamespaceRegistry(),
    diagnostics: any DiagnosticsSink = NullDiagnosticsSink(),
    decoder: any ImageDecoding,
    clock: any WallClock = SystemWallClock()
  ) {
    self.configuration = configuration
    self.transport = transport
    self.encodedStore = encodedStore
    self.recordStore = recordStore
    self.memoryCache = RenderedMemoryCache(costLimit: memoryCacheCostLimit)
    self.namespaceRegistry = namespaceRegistry
    self.diagnostics = diagnostics
    self.decoder = decoder
    self.clock = clock
  }

  @concurrent
  public func image(for request: ImageRequest) async throws -> DecodedImage {
    if request.containsCredentialHeaders,
      request.authorizationContext == .public || request.credentialGeneration == nil
    {
      throw FoveaError.missingAuthorizationContext
    }

    return try await load(request: request, variant: request.fetchVariantKey)
  }

  public func revoke(namespace: SecurityNamespaceID) async throws {
    _ = await namespaceRegistry.revoke(namespace)
    _ = await fetchTaskRegistry.cancelAll { $0.namespace == namespace }
    await memoryCache.removeAll { $0.namespace == namespace }

    var cleanupFailed = false
    do {
      try await recordStore.removeAll(namespace: namespace.value)
    } catch {
      cleanupFailed = true
    }
    do {
      try await encodedStore.removeAll(namespace: namespace.value)
    } catch {
      cleanupFailed = true
    }
    await diagnostics.record(
      DiagnosticEvent(
        kind: .namespaceRevoked,
        reason: cleanupFailed ? "persistent-cleanup-failed" : nil
      )
    )
    if cleanupFailed { throw FoveaError.namespaceCleanupFailed }
  }

  private func load(request: ImageRequest, variant: FetchVariantKey) async throws -> DecodedImage {
    let generation = await namespaceRegistry.generation(for: request.namespace)
    let now = await clock.now()
    var existing = await recordStore.record(
      for: variant.digestHex,
      namespace: request.namespace.value,
      namespaceGeneration: generation.value
    )

    if let record = existing, record.isFresh(at: now), record.disposition != .noStore {
      let cachedData: Data?
      do {
        cachedData = try await encodedStore.read(
          contentID: record.contentID,
          namespace: request.namespace.value
        )
      } catch {
        try? await recordStore.remove(variant.digestHex)
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

    let response = try await performRequest(
      request,
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

    guard let existing else { throw FoveaError.missingCachedBody }
    let cachedData: Data
    do {
      cachedData = try await encodedStore.read(
        contentID: existing.contentID,
        namespace: request.namespace.value
      )
    } catch {
      try? await recordStore.remove(variant.digestHex)
      let retry = try await performRequest(
        request,
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
      await memoryCache.removeAll {
        $0.namespace == request.namespace && $0.generation == generation
      }
      try? await encodedStore.remove(
        contentID: existing.contentID,
        namespace: request.namespace.value
      )
      try? await recordStore.remove(variant.digestHex)
      let image = try await decode(
        data: cachedData,
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
    do {
      try await recordStore.put(refreshed)
    } catch {
      await diagnostics.record(
        DiagnosticEvent(
          kind: .cacheWriteFailed,
          keyDigest: variant.digestHex,
          reason: "record-refresh-write"
        )
      )
    }

    return try await decodeAndCache(
      data: cachedData,
      request: request,
      generation: generation,
      keyDigest: variant.digestHex
    )
  }

  private func performRequest(
    _ request: ImageRequest,
    conditionalRecord: RepresentationRecord?,
    generation: NamespaceGeneration
  ) async throws -> TimedTransportResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = "GET"
    for (name, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    if let conditionalRecord {
      for (name, value) in HTTPCachePolicy.conditionalHeaders(for: conditionalRecord) {
        urlRequest.setValue(value, forHTTPHeaderField: name)
      }
    }

    let authorizedRequest = urlRequest
    let executionKey = request.fetchExecutionKey(
      revalidationFingerprint: Self.revalidationFingerprint(for: conditionalRecord)
    )
    let scopedExecutionKey = ScopedFetchExecutionKey(
      namespace: request.namespace,
      execution: executionKey
    )
    let subscription = await fetchTaskRegistry.subscribe(key: scopedExecutionKey) { [self] in
      await diagnostics.record(
        DiagnosticEvent(kind: .fetchStarted, keyDigest: executionKey.digestHex)
      )
      let requestTime = await clock.now()
      do {
        let transport = try await transport.execute(
          TransportRequest(
            request: authorizedRequest,
            maximumBytes: configuration.maximumTransportBytes,
            memoryThreshold: configuration.transportMemoryThreshold
          )
        )
        await diagnostics.record(
          DiagnosticEvent(
            kind: .fetchCompleted,
            keyDigest: executionKey.digestHex,
            statusCode: transport.head.statusCode,
            byteCount: transport.metrics.receivedBytes
          )
        )
        return TimedTransportResponse(
          requestTime: requestTime,
          responseTime: await clock.now(),
          transport: transport
        )
      } catch {
        if error is CancellationError {
          await diagnostics.record(
            DiagnosticEvent(kind: .fetchCancelled, keyDigest: executionKey.digestHex)
          )
        }
        throw error
      }
    }
    if subscription.wasJoined {
      await diagnostics.record(
        DiagnosticEvent(kind: .fetchJoined, keyDigest: executionKey.digestHex)
      )
    }

    return try await withTaskCancellationHandler {
      do {
        let response = try await subscription.value()
        try Task.checkCancellation()
        await subscription.cancel()
        return response
      } catch {
        await subscription.cancel()
        if error is CancellationError {
          try await requireActive(generation, for: request.namespace)
        }
        throw error
      }
    } onCancel: {
      Task { await subscription.cancel() }
    }
  }

  private func process200(
    _ response: TimedTransportResponse,
    request: ImageRequest,
    variant: FetchVariantKey,
    generation: NamespaceGeneration
  ) async throws -> DecodedImage {
    try Task.checkCancellation()
    guard response.head.statusCode == 200 else {
      throw FoveaError.unsupportedStatus(response.head.statusCode)
    }
    if let contentType = response.head.value(forHeader: "Content-Type"),
      !contentType.lowercased().hasPrefix("image/")
    {
      throw FoveaError.nonImageResponse
    }

    let image = try await decode(
      data: response.transport.body,
      request: request,
      keyDigest: variant.digestHex
    )
    try Task.checkCancellation()
    let contentID = ContentID(
      digestHex: response.transport.digestHex,
      byteCount: response.transport.body.count
    )
    let disposition = HTTPCachePolicy.disposition(
      headers: response.head.headers,
      isPrivateNamespace: request.authorizationContext != .public
    )

    try await requireActive(generation, for: request.namespace)

    if disposition != .noStore {
      try Task.checkCancellation()
      var blobCommitted = false
      var recordCommitted = false
      do {
        _ = try await encodedStore.commit(
          data: response.transport.body,
          contentID: contentID.description,
          namespace: request.namespace.value
        )
        blobCommitted = true
        try await requireActive(generation, for: request.namespace)

        let record = RepresentationRecord(
          securityNamespace: request.namespace.value,
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
        try await recordStore.put(record)
        recordCommitted = true
        try await requireActive(generation, for: request.namespace)

        let renderKey = scopedRenderKey(
          contentID: contentID,
          request: request,
          generation: generation
        )
        await memoryCache.insert(image, for: renderKey)
        guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
          await memoryCache.remove(renderKey)
          throw FoveaError.namespaceRevoked
        }
      } catch FoveaError.namespaceRevoked {
        if recordCommitted { try? await recordStore.remove(variant.digestHex) }
        if blobCommitted {
          try? await encodedStore.remove(
            contentID: contentID.description,
            namespace: request.namespace.value
          )
        }
        throw FoveaError.namespaceRevoked
      } catch {
        if recordCommitted { try? await recordStore.remove(variant.digestHex) }
        if blobCommitted {
          try? await encodedStore.remove(
            contentID: contentID.description,
            namespace: request.namespace.value
          )
        }
        await diagnostics.record(
          DiagnosticEvent(
            kind: .cacheWriteFailed,
            keyDigest: variant.digestHex,
            reason: "encoded-or-record-write"
          )
        )
      }
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
    if let cached = await memoryCache.image(for: key) {
      guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
        await memoryCache.remove(key)
        throw FoveaError.namespaceRevoked
      }
      try Task.checkCancellation()
      await diagnostics.record(
        DiagnosticEvent(
          kind: .renderedMemoryHit,
          keyDigest: keyDigest,
          outputPixelCount: cached.pixelWidth * cached.pixelHeight,
          targetWidth: request.target.width,
          targetHeight: request.target.height
        )
      )
      return cached
    }
    let image = try await decode(data: data, request: request, keyDigest: keyDigest)
    try Task.checkCancellation()
    try await requireActive(generation, for: request.namespace)
    await memoryCache.insert(image, for: key)
    guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
      await memoryCache.remove(key)
      throw FoveaError.namespaceRevoked
    }
    try Task.checkCancellation()
    return image
  }

  private func requireActive(
    _ generation: NamespaceGeneration,
    for namespace: SecurityNamespaceID
  ) async throws {
    guard await namespaceRegistry.isActive(generation, for: namespace) else {
      throw FoveaError.namespaceRevoked
    }
  }

  private func decode(
    data: Data,
    request: ImageRequest,
    keyDigest: String
  ) async throws -> DecodedImage {
    let probe = try decoder.probe(data: data, limits: configuration.decodeLimits)
    let image = try decoder.decode(
      data: data,
      probe: probe,
      target: request.target,
      limits: configuration.decodeLimits
    )
    await diagnostics.record(
      DiagnosticEvent(
        kind: .decodeCompleted,
        keyDigest: keyDigest,
        sourcePixelCount: probe.pixelWidth * probe.pixelHeight,
        outputPixelCount: image.pixelWidth * image.pixelHeight,
        targetWidth: request.target.width,
        targetHeight: request.target.height
      )
    )
    return image
  }

  private static func revalidationFingerprint(for record: RepresentationRecord?) -> String {
    guard let record else { return "unconditional" }
    let etag = record.etag ?? ""
    let lastModified = record.lastModified ?? ""
    return Data("etag:\(etag)\u{0}last-modified:\(lastModified)".utf8).sha256Hex
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
}
