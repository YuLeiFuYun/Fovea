import AkashicCore
import Foundation
import FoveaHTTP
import FoveaStorage
import ImageCraftCore

/// Fovea 的公共组合门面。
///
/// 该类型只负责不可变依赖装配、公开错误边界和 namespace 生命周期；缓存选择、
/// HTTP 表示处理、原编码入口及像素交付分别由固定职责协作者完成。公共构造器要求
/// 调用者显式选择 `ProfileAccessPolicy`，避免自定义组合根意外放开私有 profile。
public final class FoveaPipeline: ProgressiveImageLoading, EncodedDataLoading, NamespaceRevoking,
    Sendable
{
    public let id: PipelineID
    public let configuration: PipelineConfiguration
    /// 当前解码插件的稳定身份、版本与能力声明。
    public let codecDescriptor: ImageCodecDescriptor

    let cache: PipelineCache
    let fetchStage: FetchStage
    let decodeStage: DecodeStage
    let deliveryCoordinator: ImageDeliveryCoordinator
    let imageCoordinator: ImageLoadCoordinator
    let encodedCoordinator: EncodedDataCoordinator
    let namespaceRegistry: NamespaceRegistry
    let diagnostics: any DiagnosticsSink
    let profileAccessPolicy: ProfileAccessPolicy
    let imageLoadAdmission: AdaptiveImageLoadAdmission
    let encodedWarmups: AdaptiveEncodedWarmupCoordinator
    let progressivePreviewHub: PipelineProgressivePreviewHub
    let lifetimeAnchors = PipelineLifetimeAnchorStore()

    /// 使用完整 codec descriptor、能力与资源契约构造管线。
    public convenience init(
        configuration: PipelineConfiguration = PipelineConfiguration(),
        transport: any HTTPTransporting,
        encodedStore: any OriginalEncodedStoring,
        recordStore: any RepresentationRecordStoring,
        renderedImageCache: (any RenderedImageCaching)? = nil,
        diagnostics: any DiagnosticsSink = NullDiagnosticsSink(),
        profileAccessPolicy: ProfileAccessPolicy,
        codec: any ImageCodec,
        transformer: any ImageTransforming = IdentityImageTransformer()
    ) {
        self.init(
            id: PipelineID(),
            configuration: configuration,
            transport: transport,
            encodedStore: encodedStore,
            recordStore: recordStore,
            renderedImageCache: renderedImageCache,
            namespaceRegistry: NamespaceRegistry(
                maximumTrackedNamespaces: configuration.maximumTrackedNamespaces
            ),
            diagnostics: diagnostics,
            profileAccessPolicy: profileAccessPolicy,
            codec: codec,
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
        renderedImageCache: (any RenderedImageCaching)? = nil,
        namespaceRegistry: NamespaceRegistry,
        diagnostics: any DiagnosticsSink = NullDiagnosticsSink(),
        profileAccessPolicy: ProfileAccessPolicy = .unrestricted,
        codec: any ImageCodec,
        transformer: any ImageTransforming = IdentityImageTransformer(),
        clock: any WallClock = SystemWallClock(),
        retrySleeper: any RetrySleeping = SystemRetrySleeper(),
        retryJitter: any RetryJittering = SystemRetryJitter()
    ) {
        let adaptiveStateLimit = Self.saturatedSum([
            configuration.maximumConcurrentFetches,
            configuration.maximumQueuedFetches,
        ])
        let assembly = FoveaPipelineInitialization(
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
            retryJitter: retryJitter
        )
        self.id = id
        self.configuration = configuration
        self.profileAccessPolicy = profileAccessPolicy
        self.imageLoadAdmission = AdaptiveImageLoadAdmission(maximumStateCount: adaptiveStateLimit)
        self.encodedWarmups = AdaptiveEncodedWarmupCoordinator(
            maximumEntryCount: adaptiveStateLimit)
        self.progressivePreviewHub = PipelineProgressivePreviewHub(
            decodeStage: assembly.decodeStage,
            sharesAcrossSubscribers: transport.reusePolicy.allowsCrossRequestReuse,
            supportsProgressObservation:
                transport is any TransportProgressObservationSupporting
        )
        self.cache = assembly.cache
        self.fetchStage = assembly.fetchStage
        self.decodeStage = assembly.decodeStage
        self.codecDescriptor = assembly.decodeStage.codecDescriptor
        self.deliveryCoordinator = assembly.deliveryCoordinator
        self.imageCoordinator = assembly.imageCoordinator
        self.encodedCoordinator = assembly.encodedCoordinator
        self.namespaceRegistry = namespaceRegistry
        self.diagnostics = assembly.diagnostics
    }

    static func saturatedSum(_ values: [Int]) -> Int {
        values.reduce(0) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? Int.max : sum
        }
    }
}
