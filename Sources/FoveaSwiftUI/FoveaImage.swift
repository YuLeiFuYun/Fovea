import Combine
import FoveaCore
import ImageCraftCore
import SwiftUI

/// 用于固定请求、带显式占位与失败内容的 SwiftUI 图像视图。

public struct FoveaImage<Placeholder: View, Failure: View>: View {
    private let request: ImageRequest
    private let loader: any ImageLoading
    private let accessibility: FoveaImageAccessibility
    private let loadingPolicy: FoveaImageLoadingPolicy
    private let transitionPolicy: FoveaImageTransitionPolicy
    private let placeholder: () -> Placeholder
    private let failure: (FoveaImageFailureContext) -> Failure
    @StateObject private var model = FoveaImageModel()
    @State private var loadToken = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 创建带显式占位与失败构建器的固定请求图像视图。
    public init(
        request: ImageRequest,
        loader: any ImageLoading,
        accessibility: FoveaImageAccessibility,
        loadingPolicy: FoveaImageLoadingPolicy = .default,
        transitionPolicy: FoveaImageTransitionPolicy = .default,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping (FoveaImageFailureContext) -> Failure
    ) {
        self.request = request
        self.loader = loader
        self.accessibility = accessibility
        self.loadingPolicy = loadingPolicy
        self.transitionPolicy = transitionPolicy
        self.placeholder = placeholder
        self.failure = failure
    }

    /// 绑定当前请求身份生命周期的视图树。
    public var body: some View {
        content
            .transition(resolvedTransition)
            .animation(resolvedAnimation, value: model.phase.kind)
            .task(id: taskIdentity) {
                await model.load(
                    request: request,
                    loader: loader,
                    policy: loadingPolicy,
                    loadToken: loadToken
                )
            }
            .modifier(
                FoveaIdentityChangeModifier(identity: requestIdentity) { identity in
                    model.prepareForIdentityChange(
                        to: identity,
                        retention: loadingPolicy.retention
                    )
                }
            )
    }

    private var content: some View {
        FoveaImagePhaseContent(
            phase: model.phase,
            accessibility: accessibility,
            contentMode: request.contentMode,
            placeholder: placeholder,
            failure: failure,
            retryAction: retry
        )
    }

    private var resolvedTransition: AnyTransition {
        switch transitionPolicy.resolved(reduceMotion: reduceMotion) {
        case .identity: .identity
        case .opacity: .opacity
        }
    }

    private var resolvedAnimation: Animation? {
        switch transitionPolicy.resolved(reduceMotion: reduceMotion) {
        case .identity: nil
        case .opacity(let duration): .easeInOut(duration: duration)
        }
    }

    private var requestIdentity: String { request.displayIdentity }
    private var taskIdentity: String { "\(requestIdentity)|load:\(loadToken.uuidString)" }

    @MainActor
    private func retry() {
        loadToken = UUID()
    }
}

private struct FoveaIdentityChangeModifier: ViewModifier {
    let identity: String
    let action: (String) -> Void
    @State private var previousIdentity: String

    init(identity: String, action: @escaping (String) -> Void) {
        self.identity = identity
        self.action = action
        _previousIdentity = State(initialValue: identity)
    }

    func body(content: Content) -> some View {
        content.onReceive(Just(identity)) { newIdentity in
            guard previousIdentity != newIdentity else { return }
            previousIdentity = newIdentity
            action(newIdentity)
        }
    }
}

private struct FoveaGeometryTaskIdentity: Hashable {
    let widthPoints: Double
    let heightPoints: Double
    let scale: Double
    let contentMode: ImageContentMode
    let isStable: Bool
    let retryGeneration: UUID
}

/// 根据实时布局几何派生目标像素的 SwiftUI 图像视图。

public struct FoveaResponsiveImage<Placeholder: View, Failure: View>: View {
    private let loader: any ImageLoading
    private let accessibility: FoveaImageAccessibility
    private let contentMode: ImageContentMode
    private let geometryIsStable: Bool
    private let loadingPolicy: FoveaImageLoadingPolicy
    private let transitionPolicy: FoveaImageTransitionPolicy
    private let requestBuilder: @MainActor (ResolvedImageTarget) throws -> ImageRequest
    private let placeholder: () -> Placeholder
    private let failure: (FoveaImageFailureContext) -> Failure
    private let previewAppeared: @MainActor () -> Void
    private let successAppeared: @MainActor () -> Void
    @StateObject private var model: FoveaResponsiveImageModel
    @State private var retryGeneration = UUID()
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 创建几何感知图像视图，并根据已解析目标像素重建请求。
    public init(
        loader: any ImageLoading,
        accessibility: FoveaImageAccessibility,
        contentMode: ImageContentMode = .fit,
        geometryPolicy: TargetGeometryPolicy = .current,
        geometryIsStable: Bool = true,
        loadingPolicy: FoveaImageLoadingPolicy = .default,
        transitionPolicy: FoveaImageTransitionPolicy = .default,
        requestBuilder: @escaping @MainActor (ResolvedImageTarget) throws -> ImageRequest,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping (FoveaImageFailureContext) -> Failure
    ) {
        self.loader = loader
        self.accessibility = accessibility
        self.contentMode = contentMode
        self.geometryIsStable = geometryIsStable
        self.loadingPolicy = loadingPolicy
        self.transitionPolicy = transitionPolicy
        self.requestBuilder = requestBuilder
        self.placeholder = placeholder
        self.failure = failure
        self.previewAppeared = {}
        self.successAppeared = {}
        _model = StateObject(
            wrappedValue: FoveaResponsiveImageModel(policy: geometryPolicy)
        )
    }

    /// 创建带成功视图可见性观测的几何感知图像视图。
    ///
    /// 该入口仅用于基准测试，避免把测量钩子扩展为稳定公开 API。
    @_spi(Benchmarking)
    public init(
        loader: any ImageLoading,
        accessibility: FoveaImageAccessibility,
        contentMode: ImageContentMode = .fit,
        geometryPolicy: TargetGeometryPolicy = .current,
        geometryIsStable: Bool = true,
        loadingPolicy: FoveaImageLoadingPolicy = .default,
        transitionPolicy: FoveaImageTransitionPolicy = .default,
        onPreviewAppear: @escaping @MainActor () -> Void = {},
        onSuccessAppear: @escaping @MainActor () -> Void,
        requestBuilder: @escaping @MainActor (ResolvedImageTarget) throws -> ImageRequest,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping (FoveaImageFailureContext) -> Failure
    ) {
        self.loader = loader
        self.accessibility = accessibility
        self.contentMode = contentMode
        self.geometryIsStable = geometryIsStable
        self.loadingPolicy = loadingPolicy
        self.transitionPolicy = transitionPolicy
        self.requestBuilder = requestBuilder
        self.placeholder = placeholder
        self.failure = failure
        self.previewAppeared = onPreviewAppear
        self.successAppeared = onSuccessAppear
        _model = StateObject(
            wrappedValue: FoveaResponsiveImageModel(policy: geometryPolicy)
        )
    }

    /// 由几何驱动的视图树与请求生命周期。
    public var body: some View {
        GeometryReader { proxy in
            FoveaImagePhaseContent(
                phase: model.phase,
                accessibility: accessibility,
                contentMode: contentMode,
                placeholder: placeholder,
                failure: failure,
                retryAction: retryGeometryResolution,
                previewAppeared: previewAppeared,
                successAppeared: successAppeared
            )
            .transition(resolvedTransition)
            .animation(resolvedAnimation, value: model.phase.kind)
            .task(id: taskIdentity(for: proxy.size)) {
                await model.updateAndLoad(
                    widthPoints: proxy.size.width,
                    heightPoints: proxy.size.height,
                    scale: displayScale,
                    contentMode: contentMode,
                    isStable: geometryIsStable,
                    retryGeneration: retryGeneration,
                    loader: loader,
                    loadingPolicy: loadingPolicy,
                    requestBuilder: requestBuilder
                )
            }
        }
    }

    private func taskIdentity(for size: CGSize) -> FoveaGeometryTaskIdentity {
        FoveaGeometryTaskIdentity(
            widthPoints: size.width,
            heightPoints: size.height,
            scale: displayScale,
            contentMode: contentMode,
            isStable: geometryIsStable,
            retryGeneration: retryGeneration
        )
    }

    private var resolvedTransition: AnyTransition {
        switch transitionPolicy.resolved(reduceMotion: reduceMotion) {
        case .identity: .identity
        case .opacity: .opacity
        }
    }

    private var resolvedAnimation: Animation? {
        switch transitionPolicy.resolved(reduceMotion: reduceMotion) {
        case .identity: nil
        case .opacity(let duration): .easeInOut(duration: duration)
        }
    }

    @MainActor
    private func retryGeometryResolution() {
        retryGeneration = UUID()
    }
}

extension FoveaImage where Placeholder == ProgressView<EmptyView, EmptyView>, Failure == EmptyView {
    /// 创建使用标准进度占位且不提供失败 UI 的固定请求图像视图。
    public init(
        request: ImageRequest,
        loader: any ImageLoading,
        accessibility: FoveaImageAccessibility,
        loadingPolicy: FoveaImageLoadingPolicy = .default,
        transitionPolicy: FoveaImageTransitionPolicy = .default
    ) {
        self.init(
            request: request,
            loader: loader,
            accessibility: accessibility,
            loadingPolicy: loadingPolicy,
            transitionPolicy: transitionPolicy
        ) {
            ProgressView()
        } failure: { _ in
            EmptyView()
        }
    }
}
