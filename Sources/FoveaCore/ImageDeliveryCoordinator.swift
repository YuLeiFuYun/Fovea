import Foundation
import FoveaHTTP
import ImageCraftCore

private struct TransformExecutionKey: Hashable, Sendable {
    let render: ScopedRenderKey
    let publishesRenderedMemory: Bool
}

struct PreparedRenderedImage: Sendable {
    let image: DecodedImage
    let renderKey: ScopedRenderKey
    let publishesRenderedMemory: Bool
    let wasMemoryHit: Bool
}

/// 负责 DecodeKey 共享、变换和 RenderedMemory 发布，不拥有 HTTP 语义。
final class ImageDeliveryCoordinator: Sendable {
    private let cache: PipelineCache
    private let decodeStage: DecodeStage
    private let transformStage: TransformStage
    private let namespaceRegistry: NamespaceRegistry
    private let diagnostics: any DiagnosticsSink
    private let transformRegistry = SharedTaskRegistry<TransformExecutionKey, DecodedImage>()

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

    func validateEncodedData(
        _ data: Data,
        request: ImageRequest,
        keyDigest: String
    ) async throws {
        try await decodeStage.validateEncodedData(
            data,
            request: request,
            keyDigest: keyDigest
        )
    }

    func cancelAll(namespace: SecurityNamespaceID) async {
        _ = await transformRegistry.cancelAll { $0.render.namespace == namespace }
    }

    func prepareRenderedImage(
        decoded: DecodedImage,
        contentID: ContentID,
        request: ImageRequest,
        generation: NamespaceGeneration,
        allowsRenderedMemory: Bool,
        keyDigest: String
    ) async throws -> PreparedRenderedImage {
        try Task.checkCancellation()
        try await requireActive(generation, for: request.namespace)

        let renderKey = scopedRenderKey(
            contentID: contentID,
            request: request,
            generation: generation
        )
        let publishesRenderedMemory =
            allowsRenderedMemory && request.renderCacheAdmission == .stable
        if publishesRenderedMemory,
            let cached = try await renderedMemoryHit(
                for: renderKey,
                request: request,
                generation: generation,
                keyDigest: keyDigest
            )
        {
            return PreparedRenderedImage(
                image: cached,
                renderKey: renderKey,
                publishesRenderedMemory: true,
                wasMemoryHit: true
            )
        }

        let image = try await sharedTransform(
            decoded: decoded,
            renderKey: renderKey,
            request: request,
            generation: generation,
            publishesRenderedMemory: false
        )
        try await requireActive(generation, for: request.namespace)
        try Task.checkCancellation()
        return PreparedRenderedImage(
            image: image,
            renderKey: renderKey,
            publishesRenderedMemory: publishesRenderedMemory,
            wasMemoryHit: false
        )
    }

    func publishPreparedRenderedImage(
        _ prepared: PreparedRenderedImage,
        request: ImageRequest,
        generation: NamespaceGeneration,
        representation: RepresentationRecord?
    ) async throws -> DecodedImage {
        try Task.checkCancellation()
        try await requireActive(generation, for: request.namespace)
        if prepared.publishesRenderedMemory, !prepared.wasMemoryHit {
            await cache.insertRendered(prepared.image, for: prepared.renderKey)
            guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
                await cache.removeRendered(prepared.renderKey)
                throw PipelineFailure.namespaceRevoked
            }
        }
        if prepared.publishesRenderedMemory, let representation {
            do {
                try await cache.insertRenderedAlias(
                    for: request,
                    generation: generation,
                    renderKey: prepared.renderKey,
                    representation: representation
                )
            } catch {
                await cache.removeRendered(prepared.renderKey)
                throw error
            }
        }
        await diagnostics.record(
            DiagnosticEvent(
                kind: .renderedPublished,
                keyDigest: prepared.renderKey.renderKey.decodeKey.contentID.digestHex,
                outputPixelCount: Self.pixelCount(
                    width: prepared.image.pixelWidth,
                    height: prepared.image.pixelHeight
                ),
                targetWidth: request.target.width,
                targetHeight: request.target.height
            )
        )
        return prepared.image
    }

    func transformAndPublish(
        decoded: DecodedImage,
        contentID: ContentID,
        request: ImageRequest,
        generation: NamespaceGeneration,
        allowsRenderedMemory: Bool,
        representation: RepresentationRecord?,
        keyDigest: String
    ) async throws -> DecodedImage {
        let prepared = try await prepareRenderedImage(
            decoded: decoded,
            contentID: contentID,
            request: request,
            generation: generation,
            allowsRenderedMemory: allowsRenderedMemory,
            keyDigest: keyDigest
        )
        return try await publishPreparedRenderedImage(
            prepared,
            request: request,
            generation: generation,
            representation: representation
        )
    }

    /// 在读取原编码文件前尝试直接复用已渲染内存项。
    /// RepresentationRecord 已持有经过验证的 ContentID，因此无需先读取磁盘来重算摘要。
    func renderedImageIfPresent(
        contentID: ContentID,
        request: ImageRequest,
        generation: NamespaceGeneration,
        keyDigest: String
    ) async throws -> DecodedImage? {
        let renderKey = scopedRenderKey(
            contentID: contentID,
            request: request,
            generation: generation
        )
        return try await renderedMemoryHit(
            for: renderKey,
            request: request,
            generation: generation,
            keyDigest: keyDigest
        )
    }

    func imageFromReusableData(
        data: Data,
        request: ImageRequest,
        generation: NamespaceGeneration,
        representation: RepresentationRecord?,
        keyDigest: String
    ) async throws -> DecodedImage {
        try Task.checkCancellation()
        try await requireActive(generation, for: request.namespace)
        let contentID = ContentID(data: data)
        let renderKey = scopedRenderKey(
            contentID: contentID,
            request: request,
            generation: generation
        )
        if let cached = try await renderedMemoryHit(
            for: renderKey,
            request: request,
            generation: generation,
            keyDigest: keyDigest
        ) {
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
            allowsRenderedMemory: true,
            representation: representation,
            keyDigest: keyDigest
        )
    }

    private func sharedTransform(
        decoded: DecodedImage,
        renderKey: ScopedRenderKey,
        request: ImageRequest,
        generation: NamespaceGeneration,
        publishesRenderedMemory: Bool
    ) async throws -> DecodedImage {
        let executionKey = TransformExecutionKey(
            render: renderKey,
            publishesRenderedMemory: publishesRenderedMemory
        )
        let subscription = await transformRegistry.subscribe(
            key: executionKey,
            priority: request.priority
        ) { [cache, namespaceRegistry, transformStage] in
            let image = try await transformStage.image(from: decoded)
            try Task.checkCancellation()
            guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
                throw PipelineFailure.namespaceRevoked
            }
            guard publishesRenderedMemory else { return image }

            await cache.insertRendered(image, for: renderKey)
            guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
                await cache.removeRendered(renderKey)
                throw PipelineFailure.namespaceRevoked
            }
            return image
        }
        return try await subscriptionValue(subscription)
    }

    private func subscriptionValue(
        _ subscription: SharedTaskSubscription<TransformExecutionKey, DecodedImage>
    ) async throws -> DecodedImage {
        try await withTaskCancellationHandler {
            do {
                let value = try await subscription.value()
                try Task.checkCancellation()
                await subscription.cancel()
                return value
            } catch {
                await subscription.cancel()
                if error is CancellationError {
                    throw PipelineFailure.cancelled(stage: .transform)
                }
                throw error
            }
        } onCancel: {
            Task { await subscription.cancel() }
        }
    }

    private func renderedMemoryHit(
        for key: ScopedRenderKey,
        request: ImageRequest,
        generation: NamespaceGeneration,
        keyDigest: String
    ) async throws -> DecodedImage? {
        guard let cached = await cache.renderedImage(for: key) else { return nil }
        guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
            await cache.removeRendered(key)
            throw PipelineFailure.namespaceRevoked
        }
        try Task.checkCancellation()
        await diagnostics.record(
            DiagnosticEvent(
                kind: .renderedMemoryHit,
                keyDigest: keyDigest,
                outputPixelCount: Self.pixelCount(
                    width: cached.pixelWidth,
                    height: cached.pixelHeight
                ),
                targetWidth: request.target.width,
                targetHeight: request.target.height
            )
        )
        return cached
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
            codecContractVersion: decodeStage.codecDescriptor.contractVersion,
            codecFingerprint: decodeStage.codecDescriptor.cacheFingerprint
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
