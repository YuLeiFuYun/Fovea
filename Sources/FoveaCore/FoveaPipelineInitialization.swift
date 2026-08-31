import AkashicCore
import FoveaHTTP
import FoveaStorage
import ImageCraftCore

/// 将管线依赖图的构造与公共门面的不可变字段赋值分离。
struct FoveaPipelineInitialization {
    private struct CoreComponents {
        let cache: PipelineCache
        let fetchStage: FetchStage
        let decodeStage: DecodeStage
        let delivery: ImageDeliveryCoordinator
        let responseProcessor: HTTPImageResponseProcessor
    }

    let diagnostics: any DiagnosticsSink
    let cache: PipelineCache
    let fetchStage: FetchStage
    let decodeStage: DecodeStage
    let deliveryCoordinator: ImageDeliveryCoordinator
    let imageCoordinator: ImageLoadCoordinator
    let encodedCoordinator: EncodedDataCoordinator
    let derivedRasterRuntime: DerivedRasterRuntime?

    init(
        configuration: PipelineConfiguration,
        transport: any HTTPTransporting,
        encodedStore: any OriginalEncodedStoring,
        recordStore: any RepresentationRecordStoring,
        renderedImageCache: (any RenderedImageCaching)?,
        namespaceRegistry: NamespaceRegistry,
        diagnostics: any DiagnosticsSink,
        codec: any ImageCodec,
        transformer: any ImageTransforming,
        derivedRasterStore: (any DerivedRasterStoring)?,
        derivedRasterConfiguration: DerivedRasterRuntimeConfiguration?,
        derivedRasterCostEstimator: any DerivedRasterCostEstimating,
        clock: any WallClock,
        retrySleeper: any RetrySleeping,
        retryJitter: any RetryJittering,
        globalDecodePermits: AsyncPermitPool? = nil,
        globalDecodeWorkingSetPermits: AsyncPermitPool? = nil
    ) {
        let diagnostics = pipelineDiagnosticsSink(diagnostics)
        let derivedRasterRuntime = Self.makeDerivedRasterRuntime(
            store: derivedRasterStore,
            configuration: derivedRasterConfiguration,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics,
            clock: clock,
            costEstimator: derivedRasterCostEstimator
        )
        let core = Self.makeCoreComponents(
            configuration: configuration,
            transport: transport,
            encodedStore: encodedStore,
            recordStore: recordStore,
            renderedImageCache: renderedImageCache,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics,
            codec: codec,
            transformer: transformer,
            clock: clock,
            retrySleeper: retrySleeper,
            retryJitter: retryJitter,
            globalDecodePermits: globalDecodePermits,
            globalDecodeWorkingSetPermits: globalDecodeWorkingSetPermits
        )
        self.diagnostics = diagnostics
        cache = core.cache
        fetchStage = core.fetchStage
        decodeStage = core.decodeStage
        deliveryCoordinator = core.delivery
        self.derivedRasterRuntime = derivedRasterRuntime
        imageCoordinator = Self.makeImageCoordinator(
            configuration: configuration,
            transport: transport,
            cache: core.cache,
            fetchStage: core.fetchStage,
            responseProcessor: core.responseProcessor,
            delivery: core.delivery,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics,
            clock: clock,
            derivedRasterRuntime: derivedRasterRuntime
        )
        encodedCoordinator = Self.makeEncodedCoordinator(
            transportReusePolicy: transport.reusePolicy,
            cache: core.cache,
            fetchStage: core.fetchStage,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics,
            clock: clock
        )
    }

    private static func makeCoreComponents(
        configuration: PipelineConfiguration,
        transport: any HTTPTransporting,
        encodedStore: any OriginalEncodedStoring,
        recordStore: any RepresentationRecordStoring,
        renderedImageCache: (any RenderedImageCaching)?,
        namespaceRegistry: NamespaceRegistry,
        diagnostics: any DiagnosticsSink,
        codec: any ImageCodec,
        transformer: any ImageTransforming,
        clock: any WallClock,
        retrySleeper: any RetrySleeping,
        retryJitter: any RetryJittering,
        globalDecodePermits: AsyncPermitPool?,
        globalDecodeWorkingSetPermits: AsyncPermitPool?
    ) -> CoreComponents {
        let cache = makeCache(
            configuration: configuration,
            encodedStore: encodedStore,
            recordStore: recordStore,
            renderedImageCache: renderedImageCache,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics
        )
        let fetchStage = makeFetchStage(
            configuration: configuration,
            transport: transport,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics,
            clock: clock,
            retrySleeper: retrySleeper,
            retryJitter: retryJitter
        )
        let decodeStage = makeDecodeStage(
            configuration: configuration,
            codec: codec,
            diagnostics: diagnostics,
            globalDecodePermits: globalDecodePermits,
            globalDecodeWorkingSetPermits: globalDecodeWorkingSetPermits
        )
        let delivery = makeDelivery(
            configuration: configuration,
            transformer: transformer,
            cache: cache,
            decodeStage: decodeStage,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics
        )
        return CoreComponents(
            cache: cache,
            fetchStage: fetchStage,
            decodeStage: decodeStage,
            delivery: delivery,
            responseProcessor: makeResponseProcessor(
                cache: cache,
                fetchStage: fetchStage,
                delivery: delivery,
                namespaceRegistry: namespaceRegistry,
                diagnostics: diagnostics
            )
        )
    }

    private static func makeDerivedRasterRuntime(
        store: (any DerivedRasterStoring)?,
        configuration: DerivedRasterRuntimeConfiguration?,
        namespaceRegistry: NamespaceRegistry,
        diagnostics: any DiagnosticsSink,
        clock: any WallClock,
        costEstimator: any DerivedRasterCostEstimating
    ) -> DerivedRasterRuntime? {
        store.flatMap { store in
            configuration.map { configuration in
                DerivedRasterRuntime(
                    configuration: configuration,
                    store: store,
                    namespaceRegistry: namespaceRegistry,
                    diagnostics: diagnostics,
                    clock: clock,
                    costEstimator: costEstimator
                )
            }
        }
    }

    private static func makeResponseProcessor(
        cache: PipelineCache,
        fetchStage: FetchStage,
        delivery: ImageDeliveryCoordinator,
        namespaceRegistry: NamespaceRegistry,
        diagnostics: any DiagnosticsSink
    ) -> HTTPImageResponseProcessor {
        HTTPImageResponseProcessor(
            cache: cache,
            fetchStage: fetchStage,
            delivery: delivery,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics
        )
    }

    private static func makeEncodedCoordinator(
        transportReusePolicy: TransportReusePolicy,
        cache: PipelineCache,
        fetchStage: FetchStage,
        namespaceRegistry: NamespaceRegistry,
        diagnostics: any DiagnosticsSink,
        clock: any WallClock
    ) -> EncodedDataCoordinator {
        EncodedDataCoordinator(
            transportReusePolicy: transportReusePolicy,
            cache: cache,
            fetchStage: fetchStage,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics,
            clock: clock
        )
    }

    /// 所有构造器必须复用同一组 registry、cache 与 diagnostics 实例；在此层重建依赖会破坏撤销、single-flight 和事件顺序。
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
        codec: any ImageCodec,
        diagnostics: any DiagnosticsSink,
        globalDecodePermits: AsyncPermitPool?,
        globalDecodeWorkingSetPermits: AsyncPermitPool?
    ) -> DecodeStage {
        DecodeStage(
            codec: codec,
            limits: configuration.decodeLimits,
            diagnostics: diagnostics,
            maximumConcurrentDecodes: configuration.maximumConcurrentDecodes,
            maximumDecodeWorkingSetBytes: configuration.maximumDecodeWorkingSetBytes,
            maximumQueuedDecodes: configuration.maximumQueuedDecodes,
            globalDecodePermits: globalDecodePermits,
            globalWorkingSetPermits: globalDecodeWorkingSetPermits
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
        clock: any WallClock,
        derivedRasterRuntime: DerivedRasterRuntime?
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
            clock: clock,
            derivedRasterRuntime: derivedRasterRuntime
        )
    }
}
