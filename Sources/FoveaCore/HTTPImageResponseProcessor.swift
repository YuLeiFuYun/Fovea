import Foundation
import FoveaHTTP
import ImageCraftCore

/// 负责 200/304 响应的表示语义、OriginalEncoded 提交与 record 刷新。
/// 解码和 RenderedMemory 发布由 `ImageDeliveryCoordinator` 完成。
final class HTTPImageResponseProcessor: Sendable {
  private let cache: PipelineCache
  private let fetchStage: FetchStage
  private let delivery: ImageDeliveryCoordinator
  private let namespaceRegistry: NamespaceRegistry
  private let diagnostics: any DiagnosticsSink

  init(
    cache: PipelineCache,
    fetchStage: FetchStage,
    delivery: ImageDeliveryCoordinator,
    namespaceRegistry: NamespaceRegistry,
    diagnostics: any DiagnosticsSink
  ) {
    self.cache = cache
    self.fetchStage = fetchStage
    self.delivery = delivery
    self.namespaceRegistry = namespaceRegistry
    self.diagnostics = diagnostics
  }

  func process304(
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
      let contentID = ContentID(data: cachedData)
      let decoded = try await delivery.decode(
        data: cachedData,
        contentID: contentID,
        request: request,
        generation: generation,
        keyDigest: existing.variantKeyDigest
      )
      return try await delivery.transformAndPublish(
        decoded: decoded,
        contentID: contentID,
        request: request,
        generation: generation,
        allowsRenderedMemory: false
      )
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

    return try await delivery.imageFromReusableData(
      data: cachedData,
      request: request,
      generation: generation,
      keyDigest: refreshed.variantKeyDigest
    )
  }

  func process200(
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
    let decoded = try await delivery.decode(
      data: response.transport.body,
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

    return try await delivery.transformAndPublish(
      decoded: decoded,
      contentID: contentID,
      request: request,
      generation: generation,
      allowsRenderedMemory: allowReusableState && disposition != .noStore
    )
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

  private func requireActive(
    _ generation: NamespaceGeneration,
    for namespace: SecurityNamespaceID
  ) async throws {
    guard await namespaceRegistry.isActive(generation, for: namespace) else {
      throw PipelineFailure.namespaceRevoked
    }
  }
}
