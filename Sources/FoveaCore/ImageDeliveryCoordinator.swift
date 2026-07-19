import Foundation
import ImageCraftCore

/// 负责 DecodeKey 共享、变换和 RenderedMemory 发布，不拥有 HTTP 语义。
final class ImageDeliveryCoordinator: Sendable {
  private let cache: PipelineCache
  private let decodeStage: DecodeStage
  private let transformStage: TransformStage
  private let namespaceRegistry: NamespaceRegistry
  private let diagnostics: any DiagnosticsSink

  init(
    cache: PipelineCache,
    decodeStage: DecodeStage,
    transformStage: TransformStage,
    namespaceRegistry: NamespaceRegistry,
    diagnostics: any DiagnosticsSink
  ) {
    self.cache = cache
    self.decodeStage = decodeStage
    self.transformStage = transformStage
    self.namespaceRegistry = namespaceRegistry
    self.diagnostics = diagnostics
  }

  func decode(
    data: Data,
    contentID: ContentID,
    request: ImageRequest,
    generation: NamespaceGeneration,
    keyDigest: String
  ) async throws -> DecodedImage {
    try Task.checkCancellation()
    try await requireActive(generation, for: request.namespace)
    return try await decodeStage.image(
      from: data,
      contentID: contentID,
      request: request,
      generation: generation,
      keyDigest: keyDigest
    )
  }

  func transformAndPublish(
    decoded: DecodedImage,
    contentID: ContentID,
    request: ImageRequest,
    generation: NamespaceGeneration,
    allowsRenderedMemory: Bool
  ) async throws -> DecodedImage {
    let image = try await transformStage.image(from: decoded)
    try Task.checkCancellation()
    try await requireActive(generation, for: request.namespace)
    guard allowsRenderedMemory, request.renderCacheAdmission == .stable else { return image }

    let key = scopedRenderKey(contentID: contentID, request: request, generation: generation)
    await cache.insertRendered(image, for: key)
    guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
      await cache.removeRendered(key)
      throw PipelineFailure.namespaceRevoked
    }
    return image
  }

  func imageFromReusableData(
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

    let decoded = try await decode(
      data: data,
      contentID: contentID,
      request: request,
      generation: generation,
      keyDigest: keyDigest
    )
    return try await transformAndPublish(
      decoded: decoded,
      contentID: contentID,
      request: request,
      generation: generation,
      allowsRenderedMemory: true
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

  private static func pixelCount(width: Int, height: Int) -> Int {
    let (result, overflow) = width.multipliedReportingOverflow(by: height)
    return overflow ? Int.max : result
  }
}
