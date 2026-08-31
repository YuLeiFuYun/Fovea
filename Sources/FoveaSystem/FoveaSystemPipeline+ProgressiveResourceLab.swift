import Foundation
import FoveaCore
import FoveaHTTP
import ImageCraftImageIO

extension FoveaSystemPipeline {
    /// 仅 package 内用于 H013 的构造 seam；普通 public `open` 保持不变。
    package static func openProgressiveResourceLab(
        cacheRoot: URL,
        configuration: PipelineConfiguration,
        sessionConfiguration: URLSessionConfiguration,
        stagingDirectory: URL,
        recorder: FoveaProgressiveResourceRecorder,
        renderedImageCache: any RenderedImageCaching
    ) async throws -> FoveaSystemPipeline {
        try await openConfigured(
            cacheRoot: cacheRoot,
            configuration: configuration,
            diagnostics: NullDiagnosticsSink(),
            profileAccessPolicy: .unrestricted,
            transportPolicy: .secureDefault,
            encodedSoftTotalBytes: 8 * 1024 * 1024,
            maximumEncodedBlobBytes: 4 * 1024 * 1024,
            automaticallyPurgesMemoryOnPressure: false,
            sessionConfiguration: sessionConfiguration,
            stagingDirectory: stagingDirectory,
            transportReusePolicy: .taskLocal,
            codec: ImageIOImageDecoder(),
            transformer: IdentityImageTransformer(),
            renderedImageCache: renderedImageCache,
            progressiveResourceRecorder: recorder
        )
    }
}
