import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import ImageCraftCore
import ImageCraftImageIO

/// 由 Fovea 官方组件构成的安全默认组合根。
///
/// 该入口固定使用禁用 URLCache 与 Cookie 的 `URLSessionTransport`、同一
/// StoreGeneration 下的原编码/表征存储，以及可替换的 codec、transformer 与渲染缓存。
/// 默认 codec 当前由独立的 `ImageCraftImageIO` 产品提供；调用方可显式注入
/// AxiomRaster 或第三方实现，而无需改变网络、缓存身份或持久化布局。
public struct FoveaSystemPipeline: Sendable {
    /// 完成组合的不可变图像加载管线。
    public let pipeline: FoveaPipeline
    /// 管线使用的活动持久化存储代际。
    public let storageGenerationIdentifier: String
    /// 实际持久化 bundle provider 与 generation compatibility 的稳定组合指纹。
    public let persistentStoreProviderFingerprint: String
    package let memoryPressureMonitor: FoveaMemoryPressureMonitor?
    private let transport: URLSessionTransport

    /// 打开已验证持久化存储，并以完整 `ImageCodec` 契约组合安全默认管线。
    public static func open(
        cacheRoot: URL,
        configuration: PipelineConfiguration = PipelineConfiguration(),
        diagnostics: any DiagnosticsSink = NullDiagnosticsSink(),
        profileAccessPolicy: ProfileAccessPolicy = .publicOnly,
        transportPolicy: URLSessionTransportPolicy = .secureDefault,
        encodedSoftTotalBytes: Int = 128 * 1024 * 1024,
        maximumEncodedBlobBytes: Int = 64 * 1024 * 1024,
        automaticallyPurgesMemoryOnPressure: Bool = true,
        sessionConfiguration: URLSessionConfiguration? = nil,
        stagingDirectory: URL? = nil,
        transportReusePolicy: TransportReusePolicy? = nil,
        codec: any ImageCodec = ImageIOImageDecoder(),
        transformer: any ImageTransforming = IdentityImageTransformer(),
        renderedImageCache: (any RenderedImageCaching)? = nil
    ) async throws -> FoveaSystemPipeline {
        try await openConfigured(
            cacheRoot: cacheRoot,
            configuration: configuration,
            diagnostics: diagnostics,
            profileAccessPolicy: profileAccessPolicy,
            transportPolicy: transportPolicy,
            encodedSoftTotalBytes: encodedSoftTotalBytes,
            maximumEncodedBlobBytes: maximumEncodedBlobBytes,
            automaticallyPurgesMemoryOnPressure: automaticallyPurgesMemoryOnPressure,
            sessionConfiguration: sessionConfiguration,
            stagingDirectory: stagingDirectory,
            transportReusePolicy: transportReusePolicy,
            codec: codec,
            transformer: transformer,
            renderedImageCache: renderedImageCache
        )
    }

    private static func openConfigured(
        cacheRoot: URL,
        configuration: PipelineConfiguration,
        diagnostics: any DiagnosticsSink,
        profileAccessPolicy: ProfileAccessPolicy,
        transportPolicy: URLSessionTransportPolicy,
        encodedSoftTotalBytes: Int,
        maximumEncodedBlobBytes: Int,
        automaticallyPurgesMemoryOnPressure: Bool,
        sessionConfiguration: URLSessionConfiguration?,
        stagingDirectory: URL?,
        transportReusePolicy: TransportReusePolicy?,
        codec: any ImageCodec,
        transformer: any ImageTransforming,
        renderedImageCache: (any RenderedImageCaching)?
    ) async throws -> FoveaSystemPipeline {
        let stores: FoveaPersistentStores
        do {
            stores = try await FoveaPersistentStores.open(
                root: cacheRoot,
                encodedSoftTotalBytes: encodedSoftTotalBytes,
                maximumEncodedBlobBytes: maximumEncodedBlobBytes,
                maximumTrackedNamespaces: configuration.maximumTrackedNamespaces
            )
        } catch is NamespaceGenerationStoreError {
            throw PipelineFailure.namespaceGenerationPersistenceFailed
        }
        return try await compose(
            stores: stores.qualifiedBundle(),
            configuration: configuration,
            diagnostics: diagnostics,
            profileAccessPolicy: profileAccessPolicy,
            transportPolicy: transportPolicy,
            automaticallyPurgesMemoryOnPressure: automaticallyPurgesMemoryOnPressure,
            sessionConfiguration: sessionConfiguration,
            stagingDirectory: stagingDirectory,
            transportReusePolicy: transportReusePolicy,
            codec: codec,
            transformer: transformer,
            renderedImageCache: renderedImageCache
        )
    }

    /// 供 `FoveaAdvancedSystem` 使用的 bundle 组合入口；默认模块不直接公开 provider seam。
    package static func openQualified(
        stores: FoveaPersistentStoreBundle,
        configuration: PipelineConfiguration = PipelineConfiguration(),
        diagnostics: any DiagnosticsSink = NullDiagnosticsSink(),
        profileAccessPolicy: ProfileAccessPolicy = .publicOnly,
        transportPolicy: URLSessionTransportPolicy = .secureDefault,
        automaticallyPurgesMemoryOnPressure: Bool = true,
        sessionConfiguration: URLSessionConfiguration? = nil,
        stagingDirectory: URL? = nil,
        transportReusePolicy: TransportReusePolicy? = nil,
        codec: any ImageCodec,
        transformer: any ImageTransforming = IdentityImageTransformer(),
        renderedImageCache: (any RenderedImageCaching)? = nil
    ) async throws -> FoveaSystemPipeline {
        try await compose(
            stores: stores,
            configuration: configuration,
            diagnostics: diagnostics,
            profileAccessPolicy: profileAccessPolicy,
            transportPolicy: transportPolicy,
            automaticallyPurgesMemoryOnPressure: automaticallyPurgesMemoryOnPressure,
            sessionConfiguration: sessionConfiguration,
            stagingDirectory: stagingDirectory,
            transportReusePolicy: transportReusePolicy,
            codec: codec,
            transformer: transformer,
            renderedImageCache: renderedImageCache
        )
    }

    private static func compose(
        stores: FoveaPersistentStoreBundle,
        configuration: PipelineConfiguration,
        diagnostics: any DiagnosticsSink,
        profileAccessPolicy: ProfileAccessPolicy,
        transportPolicy: URLSessionTransportPolicy,
        automaticallyPurgesMemoryOnPressure: Bool,
        sessionConfiguration: URLSessionConfiguration?,
        stagingDirectory: URL?,
        transportReusePolicy: TransportReusePolicy?,
        codec: any ImageCodec,
        transformer: any ImageTransforming,
        renderedImageCache: (any RenderedImageCaching)?
    ) async throws -> FoveaSystemPipeline {
        let namespaceRegistry = try await NamespaceRegistry.open(
            maximumTrackedNamespaces: configuration.maximumTrackedNamespaces,
            persistence: stores.namespaceGenerations
        )
        let transport = URLSessionTransport(
            configuration: sessionConfiguration,
            stagingDirectory: stagingDirectory,
            policy: transportPolicy,
            reusePolicy: transportReusePolicy
        )
        let pipeline = FoveaPipeline(
            configuration: configuration,
            transport: transport,
            encodedStore: stores.encoded,
            recordStore: stores.records,
            renderedImageCache: renderedImageCache,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics,
            profileAccessPolicy: profileAccessPolicy.restrictingDestinations(
                transportPolicy.destinationPolicy
            ),
            codec: codec,
            transformer: transformer
        )
        await pipeline.retainLifetimeAnchor(stores)
        let monitor =
            automaticallyPurgesMemoryOnPressure
            ? FoveaMemoryPressureMonitor(pipeline: pipeline)
            : nil
        if let monitor {
            await pipeline.retainLifetimeAnchor(monitor)
        }
        return FoveaSystemPipeline(
            pipeline: pipeline,
            storageGenerationIdentifier: stores.generation.identifier.rawValue.uuidString
                .lowercased(),
            persistentStoreProviderFingerprint: stores.providerIdentity.cacheFingerprint,
            memoryPressureMonitor: monitor,
            transport: transport
        )
    }

    /// 确定性取消网络工作并释放传输暂存资源。
    /// 不可变管线仍可读取，但后续网络执行会以取消失败。
    public func invalidateAndCancel() async {
        await pipeline.cancelAdaptiveWork()
        await transport.invalidateAndCancel()
    }

    package func simulateMemoryPressureForTesting() async -> Int {
        guard let memoryPressureMonitor else { return 0 }
        return await memoryPressureMonitor.simulatePressureForTesting()
    }
}
