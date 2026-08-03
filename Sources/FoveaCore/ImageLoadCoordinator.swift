import Foundation
import FoveaHTTP
import ImageCraftCore

/// 负责缓存候选选择、回源或再验证，以及订阅者级 stale 裁决。
final class ImageLoadCoordinator: Sendable {
    private struct ReusableLookup {
        let conditionalRecord: RepresentationRecord?
        let image: DecodedImage?
    }

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

    func load(
        request: ImageRequest,
        onFullQualityPreview: (@Sendable (DecodedImage) async throws -> Void)? = nil
    ) async throws -> DecodedImage {
        let generation = try await namespaceRegistry.generation(for: request.namespace)
        guard transportReusePolicy.allowsCrossRequestReuse else {
            return try await loadTaskLocal(
                request: request,
                generation: generation,
                onFullQualityPreview: onFullQualityPreview
            )
        }

        // 已验证的渲染内存命中是成本最低的完整结果，应先于临时编码交接检查，
        // 避免热命中无意义地进入磁盘支撑状态。
        if let rendered = try await renderedMemoryHit(
            request: request,
            generation: generation
        ) {
            return rendered
        }

        if let handoff = try await cache.transportVerifiedHandoff(
            for: request,
            generation: generation,
            currentDate: { [clock] in await clock.now() }
        ) {
            return try await deliverTransportVerifiedHandoff(
                handoff,
                request: request,
                generation: generation,
                onFullQualityPreview: onFullQualityPreview
            )
        }

        let lookup = try await lookupReusableState(request: request, generation: generation)
        if let image = lookup.image { return image }
        guard request.cachePolicy != .onlyIfCached else {
            throw PipelineFailure.onlyIfCachedMiss
        }

        return try await fetchReusable(
            request: request,
            generation: generation,
            conditionalRecord: lookup.conditionalRecord,
            onFullQualityPreview: onFullQualityPreview
        )
    }

    func warmOriginal(request: ImageRequest) async throws {
        guard transportReusePolicy.allowsCrossRequestReuse,
            request.cachePolicy == .automatic,
            request.authorizationContext == .public,
            !request.containsCredentialHeaders
        else { return }

        let generation = try await namespaceRegistry.generation(for: request.namespace)
        await diagnostics.record(
            DiagnosticEvent(
                kind: .encodedHandoffStarted,
                keyDigest: request.fetchExecutionKey.digestHex
            )
        )
        if try await cache.transportVerifiedHandoff(
            for: request,
            generation: generation,
            currentDate: { [clock] in await clock.now() }
        ) != nil {
            return
        }
        let candidates = await cache.records(
            for: request.fetchBaseKey.digestHex,
            namespace: request.namespace,
            generation: generation
        )
        if let selected = HTTPCachePolicy.selectRecord(
            from: candidates,
            requestHeaders: request.headers,
            additionalSensitiveNames: request.credentialHeaderNames,
            sensitiveFingerprints: request.headerVariantFingerprints
        ), selected.isFresh(at: await clock.now()), selected.disposition != .noStore {
            return
        }

        let response = try await fetchStage.response(
            for: request,
            conditionalRecord: nil,
            generation: generation,
            memoryThresholdOverride: 0,
            bodyDelivery: .deferredFileIfStaged
        )
        try await responseProcessor.retainTransportVerifiedOriginalOnly(
            response,
            request: request,
            generation: generation
        )
    }

    private func deliverTransportVerifiedHandoff(
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

        let data: Data
        do {
            data = try handoff.materializedData()
        } catch {
            await cache.removeTransportVerifiedHandoff(for: request, generation: generation)
            throw PipelineFailure(
                category: .cacheRead,
                stage: .cacheLookup,
                disposition: .cacheDegraded,
                reasonCode: "transport-handoff-body-unavailable"
            )
        }

        let image: DecodedImage
        do {
            // 这是 transient bytes 首次跨入图像信任域的位置。imageFromReusableData
            // 必须完成容器检查、probe、目标解码与变换，成功前不得持久化。
            image = try await delivery.imageFromReusableData(
                data: data,
                request: request,
                generation: generation,
                representation: nil,
                keyDigest: handoff.variantKeyDigest(for: request)
            )
        } catch let failure as PipelineFailure {
            let provesInvalidEncodedBytes =
                failure.disposition != .cancelled
                && (failure.stage == .probe || failure.stage == .decode)
            if provesInvalidEncodedBytes {
                await cache.removeTransportVerifiedHandoff(for: request, generation: generation)
                await fetchStage.invalidateCompletionHandoff(
                    for: request,
                    conditionalRecord: nil
                )
            }
            throw failure
        } catch is CancellationError {
            // 订阅者取消不证明编码字节无效；保留 handoff 供下一位同身份消费者复用。
            throw CancellationError()
        } catch {
            await cache.removeTransportVerifiedHandoff(for: request, generation: generation)
            throw error
        }

        try Task.checkCancellation()
        try await requireActive(generation, for: request.namespace)
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

    private func loadTaskLocal(
        request: ImageRequest,
        generation: NamespaceGeneration,
        onFullQualityPreview: (@Sendable (DecodedImage) async throws -> Void)?
    ) async throws -> DecodedImage {
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
            allowReusableState: false,
            onFullQualityPreview: onFullQualityPreview
        )
    }

    private func renderedMemoryHit(
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws -> DecodedImage? {
        guard request.renderCacheAdmission == .stable,
            let rendered = await cache.renderedImage(
                for: request,
                generation: generation,
                currentDate: { [clock] in await clock.now() }
            )
        else { return nil }

        try await requireActive(generation, for: request.namespace)
        try Task.checkCancellation()
        if detailedDiagnosticsAreEnabled(diagnostics) {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .renderedMemoryHit,
                    keyDigest: request.fetchExecutionKey.digestHex,
                    outputPixelCount: Self.pixelCount(rendered),
                    targetWidth: request.target.width,
                    targetHeight: request.target.height
                )
            )
        }
        return rendered
    }

    private func lookupReusableState(
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws -> ReusableLookup {
        let candidates = await cache.records(
            for: request.fetchBaseKey.digestHex,
            namespace: request.namespace,
            generation: generation
        )
        let selected = HTTPCachePolicy.selectRecord(
            from: candidates,
            requestHeaders: request.headers,
            additionalSensitiveNames: request.credentialHeaderNames,
            sensitiveFingerprints: request.headerVariantFingerprints
        )
        guard let selected else {
            return ReusableLookup(conditionalRecord: nil, image: nil)
        }

        let now = await clock.now()
        guard selected.isFresh(at: now), selected.disposition != .noStore else {
            return ReusableLookup(conditionalRecord: selected, image: nil)
        }

        // 先使用记录中的 ContentID 查询 rendered-memory。旧实现先读取完整原编码文件，
        // 导致滚动回屏即使最终命中内存，也会被磁盘 I/O 和占位视图延迟阻塞。
        if let contentID = ContentID(
            persistentDescription: selected.contentID,
            expectedByteCount: selected.payloadLength
        ),
            let rendered = try await delivery.renderedImageIfPresent(
                contentID: contentID,
                request: request,
                generation: generation,
                keyDigest: selected.variantKeyDigest
            )
        {
            return ReusableLookup(conditionalRecord: selected, image: rendered)
        }

        guard
            let data = try await readCachedData(
                record: selected,
                request: request,
                generation: generation,
                failureReason: "original-encoded-read"
            )
        else {
            return ReusableLookup(conditionalRecord: nil, image: nil)
        }

        await diagnostics.record(
            DiagnosticEvent(
                kind: .originalEncodedHit,
                keyDigest: selected.variantKeyDigest,
                byteCount: data.count
            )
        )
        let image = try await delivery.imageFromReusableData(
            data: data,
            request: request,
            generation: generation,
            representation: selected,
            keyDigest: selected.variantKeyDigest
        )
        return ReusableLookup(conditionalRecord: selected, image: image)
    }

    private func fetchReusable(
        request: ImageRequest,
        generation: NamespaceGeneration,
        conditionalRecord: RepresentationRecord?,
        onFullQualityPreview: (@Sendable (DecodedImage) async throws -> Void)?
    ) async throws -> DecodedImage {
        do {
            let response = try await fetchStage.response(
                for: request,
                conditionalRecord: conditionalRecord,
                generation: generation
            )
            return try await processNetworkResponse(
                response,
                request: request,
                generation: generation,
                conditionalRecord: conditionalRecord,
                onFullQualityPreview: onFullQualityPreview
            )
        } catch let failure as PipelineFailure {
            if failure.disposition != .cancelled,
                failure.stage == .probe || failure.stage == .decode
            {
                await fetchStage.invalidateCompletionHandoff(
                    for: request,
                    conditionalRecord: conditionalRecord
                )
            }
            if let conditionalRecord,
                let stale = try await staleFallback(
                    record: conditionalRecord,
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

    private func processNetworkResponse(
        _ response: TimedTransportResponse,
        request: ImageRequest,
        generation: NamespaceGeneration,
        conditionalRecord: RepresentationRecord?,
        onFullQualityPreview: (@Sendable (DecodedImage) async throws -> Void)?
    ) async throws -> DecodedImage {
        guard response.head.statusCode == 304 else {
            return try await responseProcessor.process200(
                response,
                request: request,
                generation: generation,
                onFullQualityPreview: onFullQualityPreview
            )
        }
        return try await responseProcessor.process304(
            response,
            existing: conditionalRecord,
            request: request,
            generation: generation
        )
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
        guard
            let data = try await readCachedData(
                record: record,
                request: request,
                generation: generation,
                failureReason: "stale-fallback-read"
            )
        else { return nil }

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
            representation: nil,
            keyDigest: record.variantKeyDigest
        )
    }

    private func readCachedData(
        record: RepresentationRecord,
        request: ImageRequest,
        generation: NamespaceGeneration,
        failureReason: String
    ) async throws -> Data? {
        do {
            return try await cache.read(record, namespace: request.namespace)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as PipelineFailure where failure.disposition == .cancelled {
            throw failure
        } catch {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .cacheReadFailed,
                    keyDigest: record.variantKeyDigest,
                    reason: failureReason
                )
            )
            await cache.removeRecord(
                record.variantKeyDigest,
                namespace: request.namespace,
                generation: generation
            )
            await fetchStage.invalidateCompletionHandoff(
                for: request,
                conditionalRecord: nil
            )
            return nil
        }
    }

    private static func pixelCount(_ image: DecodedImage) -> Int {
        let (count, overflow) = image.pixelWidth.multipliedReportingOverflow(by: image.pixelHeight)
        return overflow ? Int.max : count
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
