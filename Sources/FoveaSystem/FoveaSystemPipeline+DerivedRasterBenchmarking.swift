import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import ImageCraftCore
import ImageCraftImageIO

/// 仅 Comparative Lab 使用的实验性 derived-raster persistence 配置。
///
/// 此 SPI 不改变 public 默认 composition；每次 benchmark 必须把这些值与结果一起记录，它们都不是 release default 或 performance claim。
@_spi(FoveaBenchmarking)
public struct FoveaDerivedRasterBenchmarkConfiguration: Equatable, Sendable {
    public let profileID = "derived-raster-observed-v1"
    public let softTotalBytes: Int
    public let maximumBlobBytes: Int
    public let maximumWriteBytesPerWindow: Int
    public let writeBudgetWindowNanoseconds: UInt64
    public let maximumContainerToOriginalPermille: Int
    public let maximumCreationNanoseconds: UInt64
    public let estimatedPersistentReadOverheadNanoseconds: UInt64
    public let safetyMarginHits: Int
    public let maximumConcurrentCreations: Int
    public let maximumQueuedCreations: Int

    public init(
        softTotalBytes: Int,
        maximumBlobBytes: Int,
        maximumWriteBytesPerWindow: Int,
        writeBudgetWindowNanoseconds: UInt64,
        maximumContainerToOriginalPermille: Int,
        maximumCreationNanoseconds: UInt64,
        estimatedPersistentReadOverheadNanoseconds: UInt64,
        safetyMarginHits: Int = 1,
        maximumConcurrentCreations: Int = 1,
        maximumQueuedCreations: Int = 4
    ) {
        self.softTotalBytes = max(1, softTotalBytes)
        self.maximumBlobBytes = max(1, maximumBlobBytes)
        self.maximumWriteBytesPerWindow = max(1, maximumWriteBytesPerWindow)
        self.writeBudgetWindowNanoseconds = max(1, writeBudgetWindowNanoseconds)
        self.maximumContainerToOriginalPermille = max(1, maximumContainerToOriginalPermille)
        self.maximumCreationNanoseconds = max(1, maximumCreationNanoseconds)
        self.estimatedPersistentReadOverheadNanoseconds =
            estimatedPersistentReadOverheadNanoseconds
        self.safetyMarginHits = max(0, safetyMarginHits)
        self.maximumConcurrentCreations = max(1, maximumConcurrentCreations)
        self.maximumQueuedCreations = max(0, maximumQueuedCreations)
    }

    package var storeLimits: DerivedRasterStoreLimits {
        DerivedRasterStoreLimits(
            softTotalBytes: softTotalBytes,
            maximumBlobBytes: maximumBlobBytes,
            maximumWriteBytesPerWindow: maximumWriteBytesPerWindow,
            writeBudgetWindowNanoseconds: writeBudgetWindowNanoseconds
        )
    }

    package var runtimeConfiguration: DerivedRasterRuntimeConfiguration {
        DerivedRasterRuntimeConfiguration(
            maximumContainerBytes: maximumBlobBytes,
            maximumContainerToOriginalPermille: maximumContainerToOriginalPermille,
            maximumCreationNanoseconds: maximumCreationNanoseconds,
            estimatedPersistentReadOverheadNanoseconds:
                estimatedPersistentReadOverheadNanoseconds,
            safetyMarginHits: safetyMarginHits,
            maximumConcurrentCreations: maximumConcurrentCreations,
            maximumQueuedCreations: maximumQueuedCreations
        )
    }
}

extension FoveaSystemPipeline {
    /// 打开与 `open` 相同的官方 system composition，但在当前 storage generation 中显式配置一个 derived-raster store；默认 public 入口绝不调用此 SPI。
    @_spi(FoveaBenchmarking)
    public static func openWithDerivedRasterForBenchmarking(
        cacheRoot: URL,
        derivedRaster: FoveaDerivedRasterBenchmarkConfiguration,
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
            renderedImageCache: renderedImageCache,
            derivedRasterStoreLimits: derivedRaster.storeLimits,
            derivedRasterConfiguration: derivedRaster.runtimeConfiguration
        )
    }
}
