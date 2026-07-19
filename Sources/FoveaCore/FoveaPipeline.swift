import AkashicCore
import Foundation
import FoveaHTTP
import ImageCraftCore

/// Fovea 的公共组合门面。
///
/// 该类型只负责不可变依赖装配、公开错误边界和 namespace 生命周期；缓存选择、
/// HTTP 表示处理、原编码入口及像素交付分别由固定职责协作者完成。
public final class FoveaPipeline: ImageLoading, EncodedDataLoading, Sendable {
  public let id: PipelineID
  public let configuration: PipelineConfiguration

  private let cache: PipelineCache
  private let fetchStage: FetchStage
  private let decodeStage: DecodeStage
  private let imageCoordinator: ImageLoadCoordinator
  private let encodedCoordinator: EncodedDataCoordinator
  private let namespaceRegistry: NamespaceRegistry
  private let diagnostics: any DiagnosticsSink

  public convenience init(
    configuration: PipelineConfiguration = PipelineConfiguration(),
    transport: any HTTPTransporting,
    encodedStore: any OriginalEncodedStoring,
    recordStore: any RepresentationRecordStoring,
    diagnostics: any DiagnosticsSink = NullDiagnosticsSink(),
    decoder: any ImageDecoding,
    transformer: any ImageTransforming = IdentityImageTransformer()
  ) {
    self.init(
      id: PipelineID(),
      configuration: configuration,
      transport: transport,
      encodedStore: encodedStore,
      recordStore: recordStore,
      namespaceRegistry: NamespaceRegistry(),
      diagnostics: diagnostics,
      decoder: decoder,
      transformer: transformer,
      clock: SystemWallClock(),
      retrySleeper: SystemRetrySleeper(),
      retryJitter: SystemRetryJitter()
    )
  }

  package init(
    id: PipelineID = PipelineID(),
    configuration: PipelineConfiguration = PipelineConfiguration(),
    transport: any HTTPTransporting,
    encodedStore: any OriginalEncodedStoring,
    recordStore: any RepresentationRecordStoring,
    namespaceRegistry: NamespaceRegistry,
    diagnostics: any DiagnosticsSink = NullDiagnosticsSink(),
    decoder: any ImageDecoding,
    transformer: any ImageTransforming = IdentityImageTransformer(),
    clock: any WallClock = SystemWallClock(),
    retrySleeper: any RetrySleeping = SystemRetrySleeper(),
    retryJitter: any RetryJittering = SystemRetryJitter()
  ) {
    self.id = id
    self.configuration = configuration

    let diagnostics = pipelineDiagnosticsSink(diagnostics)
    let mutationQueueLimit = Self.saturatedSum([
      configuration.maximumConcurrentFetches,
      configuration.maximumQueuedFetches,
      configuration.maximumConcurrentDecodes,
      configuration.maximumQueuedDecodes,
      1,
    ])
    let cache = PipelineCache(
      encodedStore: encodedStore,
      recordStore: recordStore,
      memoryCostLimit: configuration.memoryCostLimit,
      mutationQueueLimit: mutationQueueLimit,
      namespaceRegistry: namespaceRegistry,
      diagnostics: diagnostics
    )
    let fetchStage = FetchStage(
      configuration: configuration,
      transport: transport,
      diagnostics: diagnostics,
      clock: clock,
      namespaceRegistry: namespaceRegistry,
      retrySleeper: retrySleeper,
      retryJitter: retryJitter
    )
    let decodeStage = DecodeStage(
      decoder: decoder,
      limits: configuration.decodeLimits,
      diagnostics: diagnostics,
      maximumConcurrentDecodes: configuration.maximumConcurrentDecodes,
      maximumQueuedDecodes: configuration.maximumQueuedDecodes
    )
    let transformStage = TransformStage(transformer: transformer)
    let delivery = ImageDeliveryCoordinator(
      cache: cache,
      decodeStage: decodeStage,
      transformStage: transformStage,
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

    self.cache = cache
    self.fetchStage = fetchStage
    self.decodeStage = decodeStage
    self.imageCoordinator = ImageLoadCoordinator(
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
    self.encodedCoordinator = EncodedDataCoordinator(
      transportReusePolicy: transport.reusePolicy,
      cache: cache,
      fetchStage: fetchStage,
      namespaceRegistry: namespaceRegistry,
      diagnostics: diagnostics,
      clock: clock
    )
    self.namespaceRegistry = namespaceRegistry
    self.diagnostics = diagnostics
  }

  @concurrent
  public func image(for request: ImageRequest) async throws -> DecodedImage {
    try await execute {
      try validateAuthorization(of: request)
      return try await imageCoordinator.load(request: request)
    }
  }

  public func encodedData(for request: ImageRequest) async throws -> Data {
    try await execute {
      try validateAuthorization(of: request)
      return try await encodedCoordinator.load(request: request)
    }
  }

  /// 立即清空当前 pipeline 的 RenderedMemory。
  /// 系统内存压力、账户切换或宿主应用主动降级时可安全重复调用。
  @discardableResult
  public func purgeMemoryCache() async -> Int {
    let removed = await cache.purgeRendered()
    await diagnostics.record(
      DiagnosticEvent(
        kind: .renderedMemoryPurged,
        byteCount: removed,
        reason: "explicit-or-system-pressure"
      )
    )
    return removed
  }

  /// 回收未被表征记录引用的持久化数据块。
  /// 自定义存储必须同时实现对应的维护协议，否则以结构化能力错误失败。
  public func garbageCollectCaches() async throws -> GarbageCollectionResult {
    do {
      return try await cache.garbageCollect()
    } catch let failure as PipelineFailure {
      throw failure
    } catch is CancellationError {
      throw PipelineFailure.cancelled(stage: .persistence)
    } catch {
      throw PipelineFailure(
        category: .cacheWrite,
        stage: .persistence,
        disposition: .cacheDegraded,
        reasonCode: "cache-garbage-collection-failed"
      )
    }
  }

  public func revoke(namespace: SecurityNamespaceID) async throws {
    _ = await namespaceRegistry.revoke(namespace)
    await fetchStage.cancelAll(namespace: namespace)
    await decodeStage.cancelAll(namespace: namespace)
    let cleanupFailed = await cache.cleanup(namespace: namespace)
    await diagnostics.record(
      DiagnosticEvent(
        kind: .namespaceRevoked,
        reason: cleanupFailed ? "persistent-cleanup-failed" : nil
      )
    )
    if cleanupFailed { throw PipelineFailure.namespaceCleanupFailed }
  }

  private func validateAuthorization(of request: ImageRequest) throws {
    guard request.containsCredentialHeaders else { return }
    guard request.authorizationContext != .public, request.credentialGeneration != nil else {
      throw PipelineFailure.missingAuthorizationContext
    }
  }

  private func execute<Value: Sendable>(
    _ operation: () async throws -> Value
  ) async throws -> Value {
    do {
      return try await operation()
    } catch let failure as PipelineFailure {
      await record(failure)
      throw failure
    } catch is CancellationError {
      let failure = PipelineFailure.cancelled(stage: .pipeline)
      await record(failure)
      throw failure
    } catch {
      let failure = PipelineFailure.internalFailure(stage: .pipeline)
      await record(failure)
      throw failure
    }
  }

  private func record(_ failure: PipelineFailure) async {
    await diagnostics.record(
      DiagnosticEvent(
        kind: .pipelineFailed,
        statusCode: failure.statusCode,
        reason: failure.reasonCode,
        failureCategory: failure.category,
        failureStage: failure.stage,
        failureDisposition: failure.disposition
      )
    )
  }

  private static func saturatedSum(_ values: [Int]) -> Int {
    values.reduce(0) { partial, value in
      let (sum, overflow) = partial.addingReportingOverflow(value)
      return overflow ? Int.max : sum
    }
  }
}
