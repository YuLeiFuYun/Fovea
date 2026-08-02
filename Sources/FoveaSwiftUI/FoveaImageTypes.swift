import FoveaCore
import ImageCraftCore
import SwiftUI

/// SwiftUI 可观察的加载阶段，包含预览、成功与失败状态。

public enum FoveaImagePhase {
    /// 尚未开始请求，或当前几何尺寸不可加载。
    case empty
    /// 请求正在执行，且当前没有可显示的预览。
    case loading
    /// 尚未终结请求的预览图像。
    case preview(DecodedImage)
    /// 最终成功解码的图像。
    case success(DecodedImage)
    /// 终结请求的结构化管线失败。
    case failure(PipelineFailure)
    /// 活动订阅已取消。
    case cancelled

    /// 不携带图像载荷的阶段标识。
    public var kind: FoveaImagePhaseKind {
        switch self {
        case .empty: .empty
        case .loading: .loading
        case .preview: .preview
        case .success: .success
        case .failure: .failure
        case .cancelled: .cancelled
        }
    }
}

/// ``FoveaImagePhase`` 的稳定无载荷标识。

public enum FoveaImagePhaseKind: String, Codable, Hashable, Sendable {
    /// 当前没有可加载身份。
    case empty
    /// 请求正在执行，但没有可见预览。
    case loading
    /// 当前显示非终结预览。
    case preview
    /// 最终图像已成功交付。
    case success
    /// 结构化终结失败已交付。
    case failure
    /// 活动订阅已取消。
    case cancelled
}

/// 声明 SwiftUI 图像是纯装饰，还是需要公开无障碍标签。

public enum FoveaImageAccessibility {
    /// 图像不传达独有信息，因此对无障碍系统隐藏。
    case decorative
    /// 公开调用方提供的无障碍标签。
    case label(Text)
}

/// 控制请求身份变化时是否继续显示上一次成功图像。

public enum FoveaImageRetentionPolicy: String, Codable, Hashable, Sendable {
    /// 请求身份变化时立即清除旧图。
    case clearImmediately
    /// 在替代图到达前保留上一次成功图像。
    case retainSuccessfulImageUntilReplacement
}

/// 控制加载阶段发布与占位视图延迟。

public struct FoveaImageLoadingPolicy: Hashable, Sendable {
    private static let maximumPlaceholderDelayNanoseconds: UInt64 = 60_000_000_000

    /// 发布加载占位视图前的延迟。
    public let placeholderDelayNanoseconds: UInt64
    /// 替换期间成功图像的保留行为。
    public let retention: FoveaImageRetentionPolicy

    /// 创建显式指定占位延迟与保留行为的加载策略。
    public init(
        placeholderDelayNanoseconds: UInt64 = 16_000_000,
        retention: FoveaImageRetentionPolicy = .clearImmediately
    ) {
        self.placeholderDelayNanoseconds = min(
            Self.maximumPlaceholderDelayNanoseconds,
            placeholderDelayNanoseconds
        )
        self.retention = retention
    }

    /// 默认加载策略：身份变化时立即清除旧图。
    public static let `default` = FoveaImageLoadingPolicy()
}

/// 应用系统无障碍偏好后的有效图像过渡。

public enum FoveaImageResolvedTransition: Equatable, Sendable {
    /// 不使用视觉过渡。
    case identity
    /// 持续时间非负的透明度过渡。
    case opacity(duration: Double)
}

/// 在遵守“减弱动态效果”设置的前提下解析图像过渡。

public struct FoveaImageTransitionPolicy: Hashable, Sendable {
    private static let maximumOpacityDuration = 10.0

    /// 请求的透明度过渡时长。
    public let opacityDuration: Double

    /// 创建透明度策略，并将负时长钳制为零。
    public init(opacityDuration: Double = 0.2) {
        self.opacityDuration =
            opacityDuration.isFinite
            ? min(Self.maximumOpacityDuration, max(0, opacityDuration))
            : FoveaImageTransitionPolicy.defaultOpacityDuration
    }

    private static let defaultOpacityDuration = 0.2

    /// 默认过渡策略。
    public static let `default` = FoveaImageTransitionPolicy(
        opacityDuration: defaultOpacityDuration
    )

    /// 在遵守“减弱动态效果”设置时解析有效过渡。
    public func resolved(reduceMotion: Bool) -> FoveaImageResolvedTransition {
        guard !reduceMotion, opacityDuration > 0 else { return .identity }
        return .opacity(duration: opacityDuration)
    }
}

/// 提供给 SwiftUI 失败视图的失败信息与恢复操作。

public struct FoveaImageFailureContext {
    /// 结构化管线失败。
    public let failure: PipelineFailure
    /// 由策略推导出的恢复操作。
    public let recoveryAction: FoveaImageRecoveryAction
    private let retryAction: @MainActor () -> Void

    package init(
        failure: PipelineFailure,
        recoveryAction: FoveaImageRecoveryAction,
        retryAction: @escaping @MainActor () -> Void
    ) {
        self.failure = failure
        self.recoveryAction = recoveryAction
        self.retryAction = retryAction
    }

    @MainActor
    /// 仅在恢复策略允许时执行重试。
    public func retry() {
        guard recoveryAction == .retry else { return }
        retryAction()
    }
}
