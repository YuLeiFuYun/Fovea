import Foundation
import FoveaHTTP

/// 负责原编码字节入口；不会触发容器探测、像素解码或未验证内容持久化。
final class EncodedDataCoordinator: Sendable {
  private let transportReusePolicy: TransportReusePolicy
  private let cache: PipelineCache
  private let fetchStage: FetchStage
  private let namespaceRegistry: NamespaceRegistry
  private let diagnostics: any DiagnosticsSink
  private let clock: any WallClock

  init(
    transportReusePolicy: TransportReusePolicy,
    cache: PipelineCache,
    fetchStage: FetchStage,
    namespaceRegistry: NamespaceRegistry,
    diagnostics: any DiagnosticsSink,
    clock: any WallClock
  ) {
    self.transportReusePolicy = transportReusePolicy
    self.cache = cache
    self.fetchStage = fetchStage
    self.namespaceRegistry = namespaceRegistry
    self.diagnostics = diagnostics
    self.clock = clock
  }

  func load(request: ImageRequest) async throws -> Data {
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

  private func requireActive(
    _ generation: NamespaceGeneration,
    for namespace: SecurityNamespaceID
  ) async throws {
    guard await namespaceRegistry.isActive(generation, for: namespace) else {
      throw PipelineFailure.namespaceRevoked
    }
  }
}
