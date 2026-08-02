import AkashicCore
import FoveaHTTP
import FoveaStorage
import ImageCraftCore

/// 将管线依赖图的构造与公共门面的不可变字段赋值分离。
struct FoveaPipelineInitialization {
    let diagnostics: any DiagnosticsSink
    let cache: PipelineCache
    let fetchStage: FetchStage
    let decodeStage: DecodeStage
    let deliveryCoordinator: ImageDeliveryCoordinator
    let imageCoordinator: ImageLoadCoordinator
    let encodedCoordinator: EncodedDataCoordinator

    init(
        configuration: PipelineConfiguration,
        transport: any HTTPTransporting,
        encodedStore: any OriginalEncodedStoring,
        recordStore: any RepresentationRecordStoring,
        renderedImageCache: (any RenderedImageCaching)?,
        namespaceRegistry: NamespaceRegistry,
        diagnostics: any DiagnosticsSink,
        decoder: any ImageDecoding,
        transformer: any ImageTransforming,
        clock: any WallClock,
        retrySleeper: any RetrySleeping,
        retryJitter: any RetryJittering
    ) {
        let diagnostics = pipelineDiagnosticsSink(diagnostics)
        let cache = Self.makeCache(
            configuration: configuration,
            encodedStore: encodedStore,
            recordStore: recordStore,
            renderedImageCache: renderedImageCache,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics
        )
        let fetchStage = Self.makeFetchStage(
            configuration: configuration,
            transport: transport,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics,
            clock: clock,
            retrySleeper: retrySleeper,
            retryJitter: retryJitter
        )
        let decodeStage = Self.makeDecodeStage(
            configuration: configuration, decoder: decoder, diagnostics: diagnostics
        )
        let delivery = Self.makeDelivery(
            configuration: configuration,
            transformer: transformer,
            cache: cache,
            decodeStage: decodeStage,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics
        )
        let responseProcessor = HTTPImageResponseProcessor(
            cache: cache,
            fetchStage: fetchStage,
            delivery: delivery,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics
        )
        self.diagnostics = diagnostics
        self.cache = cache
        self.fetchStage = fetchStage
        self.decodeStage = decodeStage
        self.deliveryCoordinator = delivery
        self.imageCoordinator = Self.makeImageCoordinator(
            configuration: configuration,
            transport: transport,
            cache: cache,
            fetchStage: fetchStage,
            responseProcessor: responseProcessor,
            delivery: delivery,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics,
            clock: clock
        )
        self.encodedCoordinator = EncodedDataCoordinator(
            transportReusePolicy: transport.reusePolicy,
            cache: cache,
            fetchStage: fetchStage,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics,
            clock: clock
        )
    }

    // 所有构造器必须复用同一组 registry、cache 与 diagnostics 实例；在此层重建依赖会破坏撤销、single-flight 和事件顺序。
    private static func makeCache(
        configuration: PipelineConfiguration,
        encodedStore: any OriginalEncodedStoring,
        recordStore: any RepresentationRecordStoring,
        renderedImageCache: (any RenderedImageCaching)?,
        namespaceRegistry: NamespaceRegistry,
        diagnostics: any DiagnosticsSink
    ) -> PipelineCache {
        let mutationLimit = FoveaPipeline.saturatedSum([
            configuration.maximumConcurrentFetches,
            configuration.maximumQueuedFetches,
            configuration.maximumConcurrentDecodes,
            configuration.maximumQueuedDecodes,
            1,
        ])
        return PipelineCache(
            encodedStore: encodedStore,
            recordStore: recordStore,
            memoryCostLimit: configuration.memoryCostLimit,
            renderedImageCache: renderedImageCache,
            transportVerifiedEncodedHandoffCostLimit: configuration.maximumTransportBytes,
            mutationQueueLimit: mutationLimit,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics
        )
    }

    private static func makeFetchStage(
        configuration: PipelineConfiguration,
        transport: any HTTPTransporting,
        namespaceRegistry: NamespaceRegistry,
        diagnostics: any DiagnosticsSink,
        clock: any WallClock,
        retrySleeper: any RetrySleeping,
        retryJitter: any RetryJittering
    ) -> FetchStage {
        FetchStage(
            configuration: configuration,
            transport: transport,
            diagnostics: diagnostics,
            clock: clock,
            namespaceRegistry: namespaceRegistry,
            retrySleeper: retrySleeper,
            retryJitter: retryJitter
        )
    }

    private static func makeDecodeStage(
        configuration: PipelineConfiguration,
        decoder: any ImageDecoding,
        diagnostics: any DiagnosticsSink
    ) -> DecodeStage {
        DecodeStage(
            decoder: decoder,
            limits: configuration.decodeLimits,
            diagnostics: diagnostics,
            maximumConcurrentDecodes: configuration.maximumConcurrentDecodes,
            maximumDecodeWorkingSetBytes: configuration.maximumDecodeWorkingSetBytes,
            maximumQueuedDecodes: configuration.maximumQueuedDecodes
        )
    }

    private static func makeDelivery(
        configuration: PipelineConfiguration,
        transformer: any ImageTransforming,
        cache: PipelineCache,
        decodeStage: DecodeStage,
        namespaceRegistry: NamespaceRegistry,
        diagnostics: any DiagnosticsSink
    ) -> ImageDeliveryCoordinator {
        let transformStage = TransformStage(
            transformer: transformer,
            limits: configuration.decodeLimits,
            maximumOutputBytes: configuration.maximumDecodeWorkingSetBytes
        )
        return ImageDeliveryCoordinator(
            cache: cache,
            decodeStage: decodeStage,
            transformStage: transformStage,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics
        )
    }

    private static func makeImageCoordinator(
        configuration: PipelineConfiguration,
        transport: any HTTPTransporting,
        cache: PipelineCache,
        fetchStage: FetchStage,
        responseProcessor: HTTPImageResponseProcessor,
        delivery: ImageDeliveryCoordinator,
        namespaceRegistry: NamespaceRegistry,
        diagnostics: any DiagnosticsSink,
        clock: any WallClock
    ) -> ImageLoadCoordinator {
        ImageLoadCoordinator(
            configuration: configuration,
            transportReusePolicy: transport.reusePolicy,
            cache: cache,
            fetchStage: fetchStage,
            responseProcessor: responseProcessor,
            delivery: delivery,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics,
            clock: clock
        )
    }
}
