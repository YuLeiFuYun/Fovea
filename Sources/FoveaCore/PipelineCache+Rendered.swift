import AkashicCore
import AkashicMemory
import Foundation
import FoveaHTTP
import FoveaStorage
import ImageCraftCore

/// 将请求级命中别名限制在 namespace 与 generation 内，避免渲染结果跨安全边界复用。
///
/// 本文件只协调 RenderedMemory 与请求别名；原始编码持久化、HTTP 新鲜度生成和像素解码
/// 不属于该边界。别名命中必须重新验证表征身份与新鲜度，不能把内存存在性当作授权。
struct ScopedRenderedRequestAliasKey: Hashable, Sendable {
    let namespace: SecurityNamespaceID
    let generation: NamespaceGeneration
    let requestIdentity: String
}

struct RenderedRequestAlias: Sendable {
    let renderKey: ScopedRenderKey
    let representation: RepresentationRecord
}

extension PipelineCache {
    func renderedImage(for key: ScopedRenderKey) async -> DecodedImage? {
        memory.image(for: key.renderedImageCacheKey)
    }

    func renderedImage(
        for request: ImageRequest,
        generation: NamespaceGeneration,
        currentDate: @Sendable () async -> Date
    ) async -> DecodedImage? {
        let aliasKey = ScopedRenderedRequestAliasKey(
            namespace: request.namespace,
            generation: generation,
            requestIdentity: request.renderAliasIdentity
        )
        guard let alias = renderedAliases.value(for: aliasKey) else { return nil }
        let representation = alias.representation
        let selected = HTTPCachePolicy.selectRecord(
            from: [representation],
            requestHeaders: request.headers,
            additionalSensitiveNames: request.credentialHeaderNames,
            sensitiveFingerprints: request.headerVariantFingerprints
        )
        guard representation.isValidPersistentRecord(),
            representation.securityNamespaceFingerprint
                == StorageNamespaceFingerprint(namespace: request.namespace.value),
            representation.namespaceGeneration == generation.value,
            representation.baseKeyDigest == request.fetchBaseKey.digestHex,
            representation.disposition != .noStore,
            selected?.variantKeyDigest == representation.variantKeyDigest,
            let image = memory.image(for: alias.renderKey.renderedImageCacheKey)
        else {
            renderedAliases.remove(aliasKey)
            return nil
        }
        let date = await currentDate()
        guard representation.isFresh(at: date) else {
            renderedAliases.remove(aliasKey)
            return nil
        }
        return image
    }

    func insertRendered(_ image: DecodedImage, for key: ScopedRenderKey) async {
        memory.insert(
            image,
            for: key.renderedImageCacheKey,
            cost: image.estimatedByteCost
        )
    }

    func insertRenderedAlias(
        for request: ImageRequest,
        generation: NamespaceGeneration,
        renderKey: ScopedRenderKey,
        representation: RepresentationRecord
    ) async throws {
        guard representation.disposition != .noStore,
            representation.isValidPersistentRecord(),
            representation.securityNamespaceFingerprint
                == StorageNamespaceFingerprint(namespace: request.namespace.value),
            representation.namespaceGeneration == generation.value,
            representation.baseKeyDigest == request.fetchBaseKey.digestHex
        else { return }

        try await requireActive(generation, for: request.namespace)
        let aliasKey = ScopedRenderedRequestAliasKey(
            namespace: request.namespace,
            generation: generation,
            requestIdentity: request.renderAliasIdentity
        )
        renderedAliases.insert(
            RenderedRequestAlias(renderKey: renderKey, representation: representation),
            for: aliasKey,
            cost: 1
        )
        guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
            renderedAliases.remove(aliasKey)
            throw PipelineFailure.namespaceRevoked
        }
    }

    func removeRendered(_ key: ScopedRenderKey) async {
        memory.remove(key.renderedImageCacheKey)
    }

    func purgeRendered() async -> RenderedImageCacheRemovalSummary {
        renderedAliases.removeAll()
        let rendered = memory.removeAllAndReport()
        let handoffs = await transportVerifiedHandoffs.removeAllAndReport()
        return RenderedImageCacheRemovalSummary(
            itemCount: rendered.itemCount + handoffs.itemCount,
            costBytes: rendered.costBytes + handoffs.costBytes
        )
    }

}

extension ScopedRenderKey {
    fileprivate var renderedImageCacheKey: RenderedImageCacheKey {
        RenderedImageCacheKey(
            namespace: namespace,
            generation: generation,
            renderKey: renderKey
        )
    }
}
