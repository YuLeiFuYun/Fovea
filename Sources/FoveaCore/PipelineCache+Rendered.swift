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

struct RenderedMemoryBenchmarkLookup: Sendable {
    let image: DecodedImage?
    let aliasAuthorizationNanoseconds: UInt64
    let aliasIndexLookupNanoseconds: UInt64
    let representationAuthorizationNanoseconds: UInt64
    let varySelectionNanoseconds: UInt64
    let fixedIdentityAuthorizationNanoseconds: UInt64
    let renderedImageLookupNanoseconds: UInt64
    let freshnessClockNanoseconds: UInt64
    let freshnessEvaluationNanoseconds: UInt64
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
        // `insertRenderedAlias` 是唯一插入点，发布前已验证不可变持久记录。
        // 命中仍需重新验证当前请求、namespace、generation、Vary 与新鲜度授权。
        guard
            representation.securityNamespaceFingerprint
                == request.storageNamespaceFingerprint,
            representation.namespaceGeneration == generation.value,
            representation.baseKeyDigest == request.fetchBaseDigest,
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

    func renderedImageForBenchmarking(
        for request: ImageRequest,
        generation: NamespaceGeneration,
        currentDate: @Sendable () async -> Date
    ) async -> RenderedMemoryBenchmarkLookup {
        let authorizationStarted = DispatchTime.now().uptimeNanoseconds
        let aliasKey = ScopedRenderedRequestAliasKey(
            namespace: request.namespace,
            generation: generation,
            requestIdentity: request.renderAliasIdentity
        )
        let aliasLookupStarted = DispatchTime.now().uptimeNanoseconds
        guard let alias = renderedAliases.value(for: aliasKey) else {
            let finished = DispatchTime.now().uptimeNanoseconds
            return benchmarkResult(
                image: nil,
                authorization: finished &- authorizationStarted,
                aliasLookup: finished &- aliasLookupStarted
            )
        }
        let aliasLookupFinished = DispatchTime.now().uptimeNanoseconds
        return await benchmarkRenderedAlias(
            alias,
            aliasKey: aliasKey,
            request: request,
            generation: generation,
            currentDate: currentDate,
            authorizationStarted: authorizationStarted,
            aliasLookupStarted: aliasLookupStarted,
            aliasLookupFinished: aliasLookupFinished
        )
    }

    private func benchmarkRenderedAlias(
        _ alias: RenderedRequestAlias,
        aliasKey: ScopedRenderedRequestAliasKey,
        request: ImageRequest,
        generation: NamespaceGeneration,
        currentDate: @Sendable () async -> Date,
        authorizationStarted: UInt64,
        aliasLookupStarted: UInt64,
        aliasLookupFinished: UInt64
    ) async -> RenderedMemoryBenchmarkLookup {
        let representationStarted = aliasLookupFinished
        let representation = alias.representation
        let varyStarted = DispatchTime.now().uptimeNanoseconds
        let selected = HTTPCachePolicy.selectRecord(
            from: [representation],
            requestHeaders: request.headers,
            additionalSensitiveNames: request.credentialHeaderNames,
            sensitiveFingerprints: request.headerVariantFingerprints
        )
        let varyFinished = DispatchTime.now().uptimeNanoseconds
        let fixedIdentityStarted = varyFinished
        // `insertRenderedAlias` 是唯一插入点，发布前已验证不可变持久记录。
        // 命中仍需重新验证当前请求、namespace、generation、Vary 与新鲜度授权。
        guard
            representation.securityNamespaceFingerprint
                == request.storageNamespaceFingerprint,
            representation.namespaceGeneration == generation.value,
            representation.baseKeyDigest == request.fetchBaseDigest,
            representation.disposition != .noStore,
            selected?.variantKeyDigest == representation.variantKeyDigest
        else {
            renderedAliases.remove(aliasKey)
            let finished = DispatchTime.now().uptimeNanoseconds
            return benchmarkResult(
                image: nil,
                authorization: finished &- authorizationStarted,
                aliasLookup: aliasLookupFinished &- aliasLookupStarted,
                representationAuthorization: finished &- representationStarted,
                varySelection: varyFinished &- varyStarted,
                fixedIdentityAuthorization: finished &- fixedIdentityStarted
            )
        }
        let representationFinished = DispatchTime.now().uptimeNanoseconds
        let imageLookupStarted = representationFinished
        guard let image = memory.image(for: alias.renderKey.renderedImageCacheKey) else {
            renderedAliases.remove(aliasKey)
            let finished = DispatchTime.now().uptimeNanoseconds
            return benchmarkResult(
                image: nil,
                authorization: finished &- authorizationStarted,
                aliasLookup: aliasLookupFinished &- aliasLookupStarted,
                representationAuthorization: representationFinished &- representationStarted,
                varySelection: varyFinished &- varyStarted,
                fixedIdentityAuthorization: representationFinished &- fixedIdentityStarted,
                imageLookup: finished &- imageLookupStarted
            )
        }
        let imageLookupFinished = DispatchTime.now().uptimeNanoseconds
        return await benchmarkFreshness(
            image: image,
            representation: representation,
            aliasKey: aliasKey,
            currentDate: currentDate,
            authorizationStarted: authorizationStarted,
            aliasLookupStarted: aliasLookupStarted,
            aliasLookupFinished: aliasLookupFinished,
            representationStarted: representationStarted,
            representationFinished: representationFinished,
            varyStarted: varyStarted,
            varyFinished: varyFinished,
            fixedIdentityStarted: fixedIdentityStarted,
            imageLookupStarted: imageLookupStarted,
            imageLookupFinished: imageLookupFinished
        )
    }

    private func benchmarkFreshness(
        image: DecodedImage,
        representation: RepresentationRecord,
        aliasKey: ScopedRenderedRequestAliasKey,
        currentDate: @Sendable () async -> Date,
        authorizationStarted: UInt64,
        aliasLookupStarted: UInt64,
        aliasLookupFinished: UInt64,
        representationStarted: UInt64,
        representationFinished: UInt64,
        varyStarted: UInt64,
        varyFinished: UInt64,
        fixedIdentityStarted: UInt64,
        imageLookupStarted: UInt64,
        imageLookupFinished: UInt64
    ) async -> RenderedMemoryBenchmarkLookup {
        let clockStarted = imageLookupFinished
        let date = await currentDate()
        let clockFinished = DispatchTime.now().uptimeNanoseconds
        let freshnessStarted = clockFinished
        let isFresh = representation.isFresh(at: date)
        let freshnessFinished = DispatchTime.now().uptimeNanoseconds
        guard isFresh else {
            renderedAliases.remove(aliasKey)
            return benchmarkResult(
                image: nil,
                authorization: imageLookupFinished &- authorizationStarted,
                aliasLookup: aliasLookupFinished &- aliasLookupStarted,
                representationAuthorization: representationFinished &- representationStarted,
                varySelection: varyFinished &- varyStarted,
                fixedIdentityAuthorization: representationFinished &- fixedIdentityStarted,
                imageLookup: imageLookupFinished &- imageLookupStarted,
                freshnessClock: clockFinished &- clockStarted,
                freshnessEvaluation: freshnessFinished &- freshnessStarted
            )
        }
        return benchmarkResult(
            image: image,
            authorization: imageLookupFinished &- authorizationStarted,
            aliasLookup: aliasLookupFinished &- aliasLookupStarted,
            representationAuthorization: representationFinished &- representationStarted,
            varySelection: varyFinished &- varyStarted,
            fixedIdentityAuthorization: representationFinished &- fixedIdentityStarted,
            imageLookup: imageLookupFinished &- imageLookupStarted,
            freshnessClock: clockFinished &- clockStarted,
            freshnessEvaluation: freshnessFinished &- freshnessStarted
        )
    }

    private func benchmarkResult(
        image: DecodedImage?,
        authorization: UInt64,
        aliasLookup: UInt64,
        representationAuthorization: UInt64 = 0,
        varySelection: UInt64 = 0,
        fixedIdentityAuthorization: UInt64 = 0,
        imageLookup: UInt64 = 0,
        freshnessClock: UInt64 = 0,
        freshnessEvaluation: UInt64 = 0
    ) -> RenderedMemoryBenchmarkLookup {
        RenderedMemoryBenchmarkLookup(
            image: image,
            aliasAuthorizationNanoseconds: authorization,
            aliasIndexLookupNanoseconds: aliasLookup,
            representationAuthorizationNanoseconds: representationAuthorization,
            varySelectionNanoseconds: varySelection,
            fixedIdentityAuthorizationNanoseconds: fixedIdentityAuthorization,
            renderedImageLookupNanoseconds: imageLookup,
            freshnessClockNanoseconds: freshnessClock,
            freshnessEvaluationNanoseconds: freshnessEvaluation
        )
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
                == request.storageNamespaceFingerprint,
            representation.namespaceGeneration == generation.value,
            representation.baseKeyDigest == request.fetchBaseDigest
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

    /// memory warning 回收时，只有配置的 cache 明确支持 Fovea tiered refinement 才保留已证明的 rendered hot state。
    /// 该路径保留 alias：probation 条目被驱逐后，alias 会在下次 rendered-memory miss 时自失效并删除；main 条目的 alias 则保留 warm-hit。
    /// 第三方 cache 不具备这一语义时，回退到历史 full purge。
    func reclaimRenderedForWarning() async -> RenderedImageCacheRemovalSummary {
        let rendered: RenderedImageCacheRemovalSummary
        if let tiered = memory as? any TieredRenderedImageReclaiming {
            rendered = tiered.reclaimLowValueAndReport()
        } else {
            renderedAliases.removeAll()
            rendered = memory.removeAllAndReport()
        }
        let handoffs = await transportVerifiedHandoffs.removeAllAndReport()
        return RenderedImageCacheRemovalSummary(
            itemCount: rendered.itemCount + handoffs.itemCount,
            costBytes: rendered.costBytes + handoffs.costBytes
        )
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
