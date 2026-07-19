import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import ImageCraftImageIO

/// 由 Fovea 官方组件构成的安全默认组合根。
///
/// 该入口固定使用禁用 URLCache 与 Cookie 的 `URLSessionTransport`、同一
/// StoreGeneration 下的原编码/表征存储，以及目标像素优先的 ImageIO 解码器。
/// 需要自定义 transport、decoder 或 store 的调用方应直接构造 `FoveaPipeline`，
/// 从而让非默认复用和安全语义保持显式。
public struct FoveaSystemPipeline: Sendable {
  public let pipeline: FoveaPipeline
  public let storageGenerationIdentifier: String
  private let memoryPressureMonitor: FoveaMemoryPressureMonitor?

  public static func open(
    cacheRoot: URL,
    configuration: PipelineConfiguration = PipelineConfiguration(),
    diagnostics: any DiagnosticsSink = NullDiagnosticsSink(),
    profileAccessPolicy: ProfileAccessPolicy = .publicOnly,
    transportPolicy: URLSessionTransportPolicy = .secureDefault,
    encodedSoftLimitBytes: Int = 128 * 1024 * 1024,
    automaticallyPurgesMemoryOnPressure: Bool = true
  ) async throws -> FoveaSystemPipeline {
    let stores = try await FoveaPersistentStores.open(
      root: cacheRoot,
      encodedSoftLimitBytes: encodedSoftLimitBytes
    )
    let pipeline = FoveaPipeline(
      configuration: configuration,
      transport: URLSessionTransport(policy: transportPolicy),
      encodedStore: stores.encoded,
      recordStore: stores.records,
      diagnostics: diagnostics,
      profileAccessPolicy: profileAccessPolicy,
      decoder: ImageIOImageDecoder()
    )
    let monitor =
      automaticallyPurgesMemoryOnPressure
      ? FoveaMemoryPressureMonitor(pipeline: pipeline)
      : nil
    return FoveaSystemPipeline(
      pipeline: pipeline,
      storageGenerationIdentifier: stores.generation.identifier,
      memoryPressureMonitor: monitor
    )
  }

  package func simulateMemoryPressureForTesting() async -> Int {
    guard let memoryPressureMonitor else { return 0 }
    return await memoryPressureMonitor.simulatePressureForTesting()
  }
}
