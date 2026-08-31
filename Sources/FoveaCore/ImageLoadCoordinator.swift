import Foundation
import FoveaHTTP
import FoveaStorage
import ImageCraftCore

/// 负责缓存候选选择、回源或再验证，以及订阅者级 stale 裁决。
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
    private let reusableLookup: ReusableImageLookupCoordinator
    private let validatedOriginalPrefetch: ValidatedOriginalPrefetchCoordinator
    private let transportVerifiedHandoffDelivery: TransportVerifiedHandoffDelivery

    init(
        configuration: PipelineConfiguration,
        transportReusePolicy: TransportReusePolicy,
        cache: PipelineCache,
        fetchStage: FetchStage,
        responseProcessor: HTTPImageResponseProcessor,
        delivery: ImageDeliveryCoordinator,
        namespaceRegistry: NamespaceRegistry,
        diagnostics: any DiagnosticsSink,
        clock: any WallClock,
        derivedRasterRuntime: DerivedRasterRuntime? = nil
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
        let derivedRaster = derivedRasterRuntime.map {
            DerivedRasterLoadCoordinator(
                runtime: $0,
                cache: cache,
                delivery: delivery,
                namespaceRegistry: namespaceRegistry,
                clock: clock
            )
        }
        reusableLookup = ReusableImageLookupCoordinator(
            cache: cache,
            fetchStage: fetchStage,
            delivery: delivery,
            diagnostics: diagnostics,
            clock: clock,
            derivedRaster: derivedRaster
        )
        validatedOriginalPrefetch = ValidatedOriginalPrefetchCoordinator(
            configuration: configuration,
            transportReusePolicy: transportReusePolicy,
            cache: cache,
            fetchStage: fetchStage,
            responseProcessor: responseProcessor,
            namespaceRegistry: namespaceRegistry,
            clock: clock
        )
        transportVerifiedHandoffDelivery = TransportVerifiedHandoffDelivery(
            cache: cache,
            fetchStage: fetchStage,
            responseProcessor: responseProcessor,
            delivery: delivery,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics
        )
    }

    func load(
        request: ImageRequest,
        onFullQualityPreview: (@Sendable (DecodedImage) async throws -> Void)? = nil,
        progressObserver: TransportProgressObserver? = nil,
        progressiveFinalization: PipelineProgressiveFinalization? = nil
    ) async throws -> DecodedImage {
        let generation = try await namespaceRegistry.generation(
            for: request.storageNamespaceFingerprint)
        guard transportReusePolicy.allowsCrossRequestReuse else {
            return try await loadTaskLocal(
                request: request,
                generation: generation,
                onFullQualityPreview: onFullQualityPreview,
                progressObserver: progressObserver,
                progressiveFinalization: progressiveFinalization
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
            return try await transportVerifiedHandoffDelivery.deliver(
                handoff,
                request: request,
                generation: generation,
                onFullQualityPreview: onFullQualityPreview
            )
        }

        let lookup = try await reusableLookup.lookup(request: request, generation: generation)
        if let image = lookup.image {
            return image
        }
        guard request.cachePolicy != .onlyIfCached else {
            throw PipelineFailure.onlyIfCachedMiss
        }

        return try await fetchReusable(
            request: request,
            generation: generation,
            conditionalRecord: lookup.conditionalRecord,
            onFullQualityPreview: onFullQualityPreview,
            progressObserver: progressObserver,
            progressiveFinalization: progressiveFinalization
        )
    }

    struct WarmMemoryBenchmarkResult: Sendable {
        let image: DecodedImage
        let namespaceGenerationNanoseconds: UInt64
        let aliasAuthorizationNanoseconds: UInt64
        let aliasIndexLookupNanoseconds: UInt64
        let representationAuthorizationNanoseconds: UInt64
        let varySelectionNanoseconds: UInt64
        let fixedIdentityAuthorizationNanoseconds: UInt64
        let renderedImageLookupNanoseconds: UInt64
        let freshnessClockNanoseconds: UInt64
        let freshnessEvaluationNanoseconds: UInt64
        let activeNamespaceFenceNanoseconds: UInt64
        let cancellationFenceNanoseconds: UInt64
        let coordinatorTotalNanoseconds: UInt64
    }

    func warmMemoryHitForBenchmarking(
        request: ImageRequest
    ) async throws -> WarmMemoryBenchmarkResult {
        let totalStarted = DispatchTime.now().uptimeNanoseconds
        let generationStarted = totalStarted
        let generation = try await namespaceRegistry.generation(
            for: request.storageNamespaceFingerprint)
        let generationFinished = DispatchTime.now().uptimeNanoseconds
        let lookup = await cache.renderedImageForBenchmarking(
            for: request,
            generation: generation,
            currentDate: { [clock] in await clock.now() }
        )
        guard let image = lookup.image else {
            throw PipelineFailure.onlyIfCachedMiss
        }
        let activeStarted = DispatchTime.now().uptimeNanoseconds
        try await requireActive(generation, for: request)
        let activeFinished = DispatchTime.now().uptimeNanoseconds
        let cancellationStarted = activeFinished
        try Task.checkCancellation()
        let cancellationFinished = DispatchTime.now().uptimeNanoseconds
        return WarmMemoryBenchmarkResult(
            image: image,
            namespaceGenerationNanoseconds: generationFinished &- generationStarted,
            aliasAuthorizationNanoseconds: lookup.aliasAuthorizationNanoseconds,
            aliasIndexLookupNanoseconds: lookup.aliasIndexLookupNanoseconds,
            representationAuthorizationNanoseconds:
                lookup.representationAuthorizationNanoseconds,
            varySelectionNanoseconds: lookup.varySelectionNanoseconds,
            fixedIdentityAuthorizationNanoseconds:
                lookup.fixedIdentityAuthorizationNanoseconds,
            renderedImageLookupNanoseconds: lookup.renderedImageLookupNanoseconds,
            freshnessClockNanoseconds: lookup.freshnessClockNanoseconds,
            freshnessEvaluationNanoseconds: lookup.freshnessEvaluationNanoseconds,
            activeNamespaceFenceNanoseconds: activeFinished &- activeStarted,
            cancellationFenceNanoseconds: cancellationFinished &- cancellationStarted,
            coordinatorTotalNanoseconds: cancellationFinished &- totalStarted
        )
    }

    func warmOriginal(request: ImageRequest) async throws {
        guard transportReusePolicy.allowsCrossRequestReuse,
            request.cachePolicy == .automatic,
            request.authorizationContext == .public,
            !request.containsCredentialHeaders
        else { return }

        let generation = try await namespaceRegistry.generation(
            for: request.storageNamespaceFingerprint)
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
            for: request.fetchBaseDigest,
            namespace: request.namespace,
            namespaceFingerprint: request.storageNamespaceFingerprint,
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

    func prefetchValidatedOriginal(request: ImageRequest) async throws {
        try await validatedOriginalPrefetch.prefetch(request: request)
    }

    private func loadTaskLocal(
        request: ImageRequest,
        generation: NamespaceGeneration,
        onFullQualityPreview: (@Sendable (DecodedImage) async throws -> Void)?,
        progressObserver: TransportProgressObserver?,
        progressiveFinalization: PipelineProgressiveFinalization?
    ) async throws -> DecodedImage {
        guard request.cachePolicy != .onlyIfCached else {
            throw PipelineFailure.onlyIfCachedMiss
        }
        let response = try await fetchStage.response(
            for: request,
            conditionalRecord: nil,
            generation: generation,
            progressObserver: progressObserver
        )
        return try await responseProcessor.process200(
            response,
            request: request,
            generation: generation,
            allowReusableState: false,
            onFullQualityPreview: onFullQualityPreview,
            progressiveFinalization: progressiveFinalization
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

        try await requireActive(generation, for: request)
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

    private func fetchReusable(
        request: ImageRequest,
        generation: NamespaceGeneration,
        conditionalRecord: RepresentationRecord?,
        onFullQualityPreview: (@Sendable (DecodedImage) async throws -> Void)?,
        progressObserver: TransportProgressObserver?,
        progressiveFinalization: PipelineProgressiveFinalization?
    ) async throws -> DecodedImage {
        do {
            let response = try await fetchStage.response(
                for: request,
                conditionalRecord: conditionalRecord,
                generation: generation,
                progressObserver: progressObserver
            )
            return try await processNetworkResponse(
                response,
                request: request,
                generation: generation,
                conditionalRecord: conditionalRecord,
                onFullQualityPreview: onFullQualityPreview,
                progressiveFinalization: progressiveFinalization
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
        onFullQualityPreview: (@Sendable (DecodedImage) async throws -> Void)?,
        progressiveFinalization: PipelineProgressiveFinalization?
    ) async throws -> DecodedImage {
        guard response.head.statusCode == 304 else {
            return try await responseProcessor.process200(
                response,
                request: request,
                generation: generation,
                onFullQualityPreview: onFullQualityPreview,
                progressiveFinalization: progressiveFinalization
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
        try await requireActive(generation, for: request)
        guard
            let data = try await reusableLookup.readCachedData(
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

    private static func pixelCount(_ image: DecodedImage) -> Int {
        let (count, overflow) = image.pixelWidth.multipliedReportingOverflow(by: image.pixelHeight)
        return overflow ? Int.max : count
    }

    private func requireActive(
        _ generation: NamespaceGeneration,
        for request: ImageRequest
    ) async throws {
        guard
            await namespaceRegistry.isActive(
                generation,
                for: request.storageNamespaceFingerprint
            )
        else {
            throw PipelineFailure.namespaceRevoked
        }
    }
}
