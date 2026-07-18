import AkashicDisk
import AkashicMemory
import Foundation
import FoveaHTTP
import ImageCraftCore
import ImageCraftImageIO

public struct ImageRequest: Sendable {
  public let url: URL
  public let target: TargetPixels
  public let namespace: SecurityNamespaceID
  public let authorizationContext: AuthorizationContextID
  public let credentialGeneration: CredentialGeneration?
  public let headers: [String: String]

  public init(
    url: URL,
    target: TargetPixels,
    namespace: SecurityNamespaceID,
    authorizationContext: AuthorizationContextID = .public,
    credentialGeneration: CredentialGeneration? = nil,
    headers: [String: String] = [:]
  ) {
    self.url = url
    self.target = target
    self.namespace = namespace
    self.authorizationContext = authorizationContext
    self.credentialGeneration = credentialGeneration
    self.headers = headers
  }

  public static func publicImage(url: URL, target: TargetPixels, appID: String) -> Self {
    ImageRequest(url: url, target: target, namespace: .publicNamespace(appID: appID))
  }

  public var fetchVariantKey: FetchVariantKey {
    FetchVariantKey(
      source: LogicalSourceID(url: url),
      namespace: namespace,
      authorizationContext: authorizationContext,
      requestVariants: stableRequestVariants
    )
  }

  public var fetchExecutionKey: FetchExecutionKey {
    FetchExecutionKey(
      variant: fetchVariantKey,
      resolvedLocator: url.absoluteString,
      credentialGeneration: credentialGeneration
    )
  }

  public var containsCredentialHeaders: Bool {
    headers.keys.contains { Self.sensitiveHeaderNames.contains($0.lowercased()) }
  }

  private var stableRequestVariants: [String: String] {
    Dictionary(
      uniqueKeysWithValues: headers.compactMap { name, value in
        let normalized = name.lowercased()
        guard !Self.sensitiveHeaderNames.contains(normalized) else { return nil }
        return (normalized, value)
      })
  }

  private static let sensitiveHeaderNames: Set<String> = [
    "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key",
  ]
}

public struct PipelineConfiguration: Sendable {
  public let decodeLimits: DecodeLimits
  public let maximumTransportBytes: Int
  public let transportMemoryThreshold: Int

  public init(
    decodeLimits: DecodeLimits = .phase0a,
    maximumTransportBytes: Int = 64 * 1024 * 1024,
    transportMemoryThreshold: Int = 512 * 1024
  ) {
    self.decodeLimits = decodeLimits
    self.maximumTransportBytes = maximumTransportBytes
    self.transportMemoryThreshold = transportMemoryThreshold
  }
}

public enum FoveaError: Error, Equatable, Sendable {
  case unsupportedStatus(Int)
  case nonImageResponse
  case namespaceRevoked
  case missingCachedBody
  case missingAuthorizationContext
}

private struct ScopedRenderKey: Hashable, Sendable {
  let namespace: SecurityNamespaceID
  let generation: NamespaceGeneration
  let renderKey: RenderKey
}

public final class FoveaPipeline: Sendable {
  private let configuration: PipelineConfiguration
  private let transport: any HTTPTransporting
  private let encodedStore: any OriginalEncodedStoring
  private let recordStore: any RepresentationRecordStoring
  private let memoryCache: RenderedMemoryCache<ScopedRenderKey>
  private let namespaceRegistry: NamespaceRegistry
  private let taskRegistry: SharedImageTaskRegistry
  private let decoder = ImageIOImageDecoder()

  public init(
    configuration: PipelineConfiguration = PipelineConfiguration(),
    transport: any HTTPTransporting,
    encodedStore: any OriginalEncodedStoring,
    recordStore: any RepresentationRecordStoring,
    memoryCacheCostLimit: Int = 64 * 1024 * 1024,
    namespaceRegistry: NamespaceRegistry = NamespaceRegistry(),
    taskRegistry: SharedImageTaskRegistry = SharedImageTaskRegistry()
  ) {
    self.configuration = configuration
    self.transport = transport
    self.encodedStore = encodedStore
    self.recordStore = recordStore
    self.memoryCache = RenderedMemoryCache(costLimit: memoryCacheCostLimit)
    self.namespaceRegistry = namespaceRegistry
    self.taskRegistry = taskRegistry
  }

  public func image(for request: ImageRequest) async throws -> DecodedImage {
    if request.containsCredentialHeaders,
      request.authorizationContext == .public || request.credentialGeneration == nil
    {
      throw FoveaError.missingAuthorizationContext
    }

    let variant = request.fetchVariantKey
    let execution = request.fetchExecutionKey
    let subscription = await taskRegistry.subscribe(key: execution) { [self] in
      try await loadUnshared(request: request, variant: variant)
    }

    return try await withTaskCancellationHandler {
      do {
        let image = try await subscription.value()
        await subscription.cancel()
        return image
      } catch {
        await subscription.cancel()
        throw error
      }
    } onCancel: {
      Task { await subscription.cancel() }
    }
  }

  public func revoke(namespace: SecurityNamespaceID) async {
    _ = await namespaceRegistry.revoke(namespace)
    // Phase 0a uses a conservative full flush. Namespace-local removal is a later optimization.
    await memoryCache.removeAll()
  }

  private func loadUnshared(request: ImageRequest, variant: FetchVariantKey) async throws
    -> DecodedImage
  {
    let generation = await namespaceRegistry.generation(for: request.namespace)
    let now = Date()
    var existing = await recordStore.record(for: variant.digestHex)

    if let record = existing, record.isFresh(at: now), record.disposition != .noStore {
      do {
        let data = try await encodedStore.read(
          contentID: record.contentID,
          namespace: request.namespace.value
        )
        return try await decodeAndCache(data: data, request: request, generation: generation)
      } catch {
        try? await recordStore.remove(variant.digestHex)
        existing = nil
      }
    }

    let response = try await performRequest(request, conditionalRecord: existing)
    if response.head.statusCode == 304 {
      guard let existing else { throw FoveaError.missingCachedBody }
      do {
        let data = try await encodedStore.read(
          contentID: existing.contentID,
          namespace: request.namespace.value
        )
        let refreshed = RepresentationRecord(
          variantKeyDigest: variant.digestHex,
          statusCode: existing.statusCode,
          requestTime: response.requestTime,
          responseTime: response.responseTime,
          expiresAt: HTTPCachePolicy.expiration(
            responseTime: response.responseTime,
            headers: response.transport.head.headers
          ) ?? existing.expiresAt,
          etag: HTTPCachePolicy.header("ETag", in: response.transport.head.headers)
            ?? existing.etag,
          lastModified: HTTPCachePolicy.header("Last-Modified", in: response.transport.head.headers)
            ?? existing.lastModified,
          disposition: existing.disposition,
          contentID: existing.contentID,
          payloadLength: existing.payloadLength,
          contentType: existing.contentType
        )
        if await namespaceRegistry.isActive(generation, for: request.namespace) {
          try await recordStore.put(refreshed)
        }
        return try await decodeAndCache(data: data, request: request, generation: generation)
      } catch {
        try? await recordStore.remove(variant.digestHex)
        let retry = try await performRequest(request, conditionalRecord: nil)
        return try await process200(
          retry,
          request: request,
          variant: variant,
          generation: generation
        )
      }
    }

    return try await process200(
      response,
      request: request,
      variant: variant,
      generation: generation
    )
  }

  private struct TimedTransportResponse: Sendable {
    let requestTime: Date
    let responseTime: Date
    let transport: TransportResponse
    var head: TransportResponseHead { transport.head }
  }

  private func performRequest(
    _ request: ImageRequest,
    conditionalRecord: RepresentationRecord?
  ) async throws -> TimedTransportResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = "GET"
    for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
    if let conditionalRecord {
      for (name, value) in HTTPCachePolicy.conditionalHeaders(for: conditionalRecord) {
        urlRequest.setValue(value, forHTTPHeaderField: name)
      }
    }
    let requestTime = Date()
    let transport = try await transport.execute(
      TransportRequest(
        request: urlRequest,
        maximumBytes: configuration.maximumTransportBytes,
        memoryThreshold: configuration.transportMemoryThreshold
      )
    )
    return TimedTransportResponse(
      requestTime: requestTime, responseTime: Date(), transport: transport)
  }

  private func process200(
    _ response: TimedTransportResponse,
    request: ImageRequest,
    variant: FetchVariantKey,
    generation: NamespaceGeneration
  ) async throws -> DecodedImage {
    guard response.head.statusCode == 200 else {
      throw FoveaError.unsupportedStatus(response.head.statusCode)
    }
    if let contentType = response.head.value(forHeader: "Content-Type"),
      !contentType.lowercased().hasPrefix("image/")
    {
      throw FoveaError.nonImageResponse
    }

    let image = try decoder.decode(
      data: response.transport.body,
      target: request.target,
      limits: configuration.decodeLimits
    )
    let contentID = ContentID(
      digestHex: response.transport.digestHex,
      byteCount: response.transport.body.count
    )
    let disposition = HTTPCachePolicy.disposition(
      headers: response.head.headers,
      isPrivateNamespace: request.authorizationContext != .public
    )

    guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
      throw FoveaError.namespaceRevoked
    }

    if disposition != .noStore {
      do {
        _ = try await encodedStore.commit(
          data: response.transport.body,
          contentID: contentID.description,
          namespace: request.namespace.value
        )
        guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
          throw FoveaError.namespaceRevoked
        }
        let record = RepresentationRecord(
          variantKeyDigest: variant.digestHex,
          statusCode: 200,
          requestTime: response.requestTime,
          responseTime: response.responseTime,
          expiresAt: HTTPCachePolicy.expiration(
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
        await memoryCache.insert(
          image,
          for: scopedRenderKey(contentID: contentID, request: request, generation: generation)
        )
      } catch FoveaError.namespaceRevoked {
        throw FoveaError.namespaceRevoked
      } catch {
        // Cache degradation is non-terminal: the decoded final remains deliverable.
      }
    }

    return image
  }

  private func decodeAndCache(
    data: Data,
    request: ImageRequest,
    generation: NamespaceGeneration
  ) async throws -> DecodedImage {
    let contentID = ContentID(data: data)
    let key = scopedRenderKey(contentID: contentID, request: request, generation: generation)
    if let cached = await memoryCache.image(for: key) { return cached }
    let image = try decoder.decode(
      data: data, target: request.target, limits: configuration.decodeLimits)
    await memoryCache.insert(image, for: key)
    return image
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
