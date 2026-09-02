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
        keyDigest: String,
        preparation: ImageDecodePreparation? = nil
    ) async throws -> DecodedImage {
        try Task.checkCancellation()
        try await requireActive(generation, for: request.namespace)
        return try await decodeStage.image(
            from: data,
            contentID: contentID,
            request: request,
            generation: generation,
            keyDigest: keyDigest,
            preparation: preparation
        )
    }

    func discardProgressivePreparation(_ preparation: ImageDecodePreparation) async {
        await decodeStage.discardProgressivePreparation(preparation)
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

    /// 发布已由版本化派生容器验证的最终 RenderKey 像素，不重复执行 transform。
    func publishDerivedRaster(
        _ loaded: DerivedRasterLoadedImage,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws -> DecodedImage {
        let key = loaded.key
        guard key.namespaceFingerprint == request.storageNamespaceFingerprint,
            key.namespaceGeneration == generation,
            key.renderKey
                == renderKey(
                    contentID: key.renderKey.decodeKey.contentID,
                    request: request
                ),
            DerivedRasterArtifactValidator.outputGeometryIsCompatible(
                width: loaded.image.pixelWidth,
                height: loaded.image.pixelHeight,
                key: key
            )
        else {
            throw PipelineFailure(
                category: .cacheRead,
                stage: .cacheLookup,
                disposition: .cacheDegraded,
                reasonCode: "derived-raster-identity-mismatch"
            )
        }
        try Task.checkCancellation()
        // derived output 只留在有界 compressed-hot tier，不复制进 rendered cache：返回的 CGImage 是 display-lazy，
        // 若在此额外持有会增加 alias/fence 工作，并按完整解码像素驻留错误高估内存。
        try await requireActive(generation, for: request.namespace)
        return loaded.image
    }

    func renderKey(contentID: ContentID, request: ImageRequest) -> RenderKey {
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
        return RenderKey(
            decodeKey: decode,
            transformerFingerprint: transformStage.fingerprint,
            renderVersion: 1
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
        ScopedRenderKey(
            namespace: request.namespace,
            generation: generation,
            renderKey: renderKey(contentID: contentID, request: request)
        )
    }

    private static func pixelCount(width: Int, height: Int) -> Int {
        let (result, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? Int.max : result
    }
}

/// 完成 transient transport-verified handoff 边界：先确认图像字节可信，只有 namespace/cancellation fence 仍成立后才持久化 reusable original。
struct TransportVerifiedHandoffDelivery: Sendable {
    let cache: PipelineCache
    let fetchStage: FetchStage
    let responseProcessor: HTTPImageResponseProcessor
    let delivery: ImageDeliveryCoordinator
    let namespaceRegistry: NamespaceRegistry
    let diagnostics: any DiagnosticsSink

    func deliver(
        _ handoff: TransportVerifiedEncodedHandoffEntry,
        request: ImageRequest,
        generation: NamespaceGeneration,
        onFullQualityPreview: (@Sendable (DecodedImage) async throws -> Void)?
    ) async throws -> DecodedImage {
        await diagnostics.record(
            DiagnosticEvent(
                kind: .originalEncodedHit,
                keyDigest: handoff.variantKeyDigest(for: request),
                byteCount: handoff.byteCount,
                reason: "transport-verified-handoff"
            )
        )
        let data = try await materializedData(handoff, request: request, generation: generation)
        let image = try await decodedImage(
            data,
            handoff: handoff,
            request: request,
            generation: generation
        )
        return try await publish(
            image,
            data: data,
            handoff: handoff,
            request: request,
            generation: generation,
            onFullQualityPreview: onFullQualityPreview
        )
    }

    private func materializedData(
        _ handoff: TransportVerifiedEncodedHandoffEntry,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws -> Data {
        do {
            return try handoff.materializedData()
        } catch {
            await cache.removeTransportVerifiedHandoff(for: request, generation: generation)
            throw PipelineFailure(
                category: .cacheRead,
                stage: .cacheLookup,
                disposition: .cacheDegraded,
                reasonCode: "transport-handoff-body-unavailable"
            )
        }
    }

    private func decodedImage(
        _ data: Data,
        handoff: TransportVerifiedEncodedHandoffEntry,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws -> DecodedImage {
        do {
            return try await delivery.imageFromReusableData(
                data: data,
                request: request,
                generation: generation,
                representation: nil,
                keyDigest: handoff.variantKeyDigest(for: request)
            )
        } catch let failure as PipelineFailure {
            await invalidateIfEncodedBytesProvenInvalid(
                failure,
                request: request,
                generation: generation
            )
            throw failure
        } catch is CancellationError {
            // subscriber 取消只说明该订阅终止，并不能证明 encoded bytes 无效。
            throw CancellationError()
        } catch {
            await cache.removeTransportVerifiedHandoff(for: request, generation: generation)
            throw error
        }
    }

    private func invalidateIfEncodedBytesProvenInvalid(
        _ failure: PipelineFailure,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async {
        guard failure.disposition != .cancelled,
            failure.stage == .probe || failure.stage == .decode
        else { return }
        await cache.removeTransportVerifiedHandoff(for: request, generation: generation)
        await fetchStage.invalidateCompletionHandoff(for: request, conditionalRecord: nil)
    }

    private func publish(
        _ image: DecodedImage,
        data: Data,
        handoff: TransportVerifiedEncodedHandoffEntry,
        request: ImageRequest,
        generation: NamespaceGeneration,
        onFullQualityPreview: (@Sendable (DecodedImage) async throws -> Void)?
    ) async throws -> DecodedImage {
        try Task.checkCancellation()
        try await requireActive(generation, request: request)
        if let onFullQualityPreview {
            try await onFullQualityPreview(image)
            await Task.yield()
        }
        try await responseProcessor.persistTransportVerifiedHandoff(
            handoff,
            data: data,
            request: request,
            generation: generation
        )
        await cache.removeTransportVerifiedHandoff(for: request, generation: generation)
        return image
    }

    private func requireActive(
        _ generation: NamespaceGeneration,
        request: ImageRequest
    ) async throws {
        guard
            await namespaceRegistry.isActive(
                generation,
                for: request.storageNamespaceFingerprint
            )
        else { throw PipelineFailure.namespaceRevoked }
    }
}
