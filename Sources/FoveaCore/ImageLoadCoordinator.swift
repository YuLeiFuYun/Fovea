import Foundation
import FoveaHTTP
import ImageCraftCore

/// 负责缓存候选选择、回源/再验证与订阅者级 stale 裁决。
final class ImageLoadCoordinator: Sendable {
  private let configuration: PipelineConfiguration
  private let transportReusePolicy: TransportReusePolicy
  private let cache: PipelineCache
  private let fetchStage: FetchStage
  private let responseProcessor: HTTPImageResponseProcessor
  private let delivery: ImageDeliveryCoordinator
  private let namespaceRegistry: NamespaceRegistry
  private let diagnostics: any DiagnosticsSink
  private let clock: any WallClock

  init(
    configuration: PipelineConfiguration,
    transportReusePolicy: TransportReusePolicy,
    cache: PipelineCache,
    fetchStage: FetchStage,
    responseProcessor: HTTPImageResponseProcessor,
    delivery: ImageDeliveryCoordinator,
    namespaceRegistry: NamespaceRegistry,
    diagnostics: any DiagnosticsSink,
    clock: any WallClock
  ) {
    self.configuration = configuration
    self.transportReusePolicy = transportReusePolicy
    self.cache = cache
    self.fetchStage = fetchStage
    self.responseProcessor = responseProcessor
    self.delivery = delivery
    self.namespaceRegistry = namespaceRegistry
    self.diagnostics = diagnostics
    self.clock = clock
  }

  func load(request: ImageRequest) async throws -> DecodedImage {
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
      return try await responseProcessor.process200(
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
        return try await delivery.imageFromReusableData(
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
        return try await responseProcessor.process200(
          response,
          request: request,
          generation: generation
        )
      }

      return try await responseProcessor.process304(
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
    return try await delivery.imageFromReusableData(
      data: data,
      request: request,
      generation: generation,
      keyDigest: record.variantKeyDigest
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
