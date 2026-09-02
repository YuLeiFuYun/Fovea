#if canImport(AppKit)
    import AppKit
    import FoveaCore
    import ImageCraftCore

    /// 控制 AppKit 图像视图在替换期间是否保留上一次成功图像。

    public enum FoveaImageViewRetentionPolicy: Sendable {
        /// 请求身份变化时清除旧图。
        case clearImmediately
        /// 在替代图交付前保留上一次成功图像。
        case retainSuccessfulImageUntilReplacement

        fileprivate var coreRetention: ImageDisplayRetention {
            switch self {
            case .clearImmediately: .clearImmediately
            case .retainSuccessfulImageUntilReplacement: .retainSuccessfulImageUntilReplacement
            }
        }
    }

    /// 描述已加载 AppKit 图像使用的无障碍语义。

    public enum FoveaImageViewAccessibility: Sendable {
        /// 图像仅用于装饰，因此对无障碍系统隐藏。
        case decorative
        /// 公开调用方提供的无障碍标签。
        case label(String)
    }

    /// 具备请求身份栅栏、可选渐进事件单调性和窗口移除取消语义的 AppKit 图片视图。
    @MainActor
    public final class FoveaImageView: NSImageView {
        /// 视图移出窗口时是否取消活动图像订阅。
        public var automaticallyCancelsWhenRemovedFromWindow = true

        private let displaySession = ImageDisplaySession()
        private let staticLoadRecovery = ImageViewStaticLoadRecovery()
        private var loadTask: Task<Void, Never>?
        private var activeStaticLoadToken: UUID?
        private var placeholderImage: NSImage?
        private var retentionPolicy: FoveaImageViewRetentionPolicy = .clearImmediately
        private var animationPresenter: FoveaAnimatedImageViewPresenter?
        private var animationBenchmarkPresentationHandlerStorage:
            FoveaAppKitAnimationBenchmarkPresentationHandler?
        private var animationBenchmarkRefreshSampleHandlerStorage:
            FoveaAppKitAnimationRefreshSampleHandler?

        @_spi(AnimationLifecycle)
        public override var isHidden: Bool {
            didSet { updateAnimationVisibility() }
        }

        @_spi(AnimationLifecycle)
        public override var alphaValue: CGFloat {
            didSet { updateAnimationVisibility() }
        }

        @_spi(AnimationLifecycle)
        public override var imageScaling: NSImageScaling {
            didSet { animationPresenter?.refreshForImageViewGeometryPolicyChange() }
        }

        @_spi(AnimationLifecycle)
        public override var imageAlignment: NSImageAlignment {
            didSet { animationPresenter?.refreshForImageViewGeometryPolicyChange() }
        }

        @_spi(AnimationLifecycle)
        public override var imageFrameStyle: NSImageView.FrameStyle {
            didSet { animationPresenter?.refreshForImageViewGeometryPolicyChange() }
        }

        deinit {
            loadTask?.cancel()
        }

        /// 使用显式无障碍与保留策略，开始或替换经过身份检查的加载。
        public func setImage(
            request: ImageRequest,
            loader: any ImageLoading,
            accessibility: FoveaImageViewAccessibility,
            placeholder: NSImage? = nil,
            retention: FoveaImageViewRetentionPolicy = .clearImmediately,
            placeholderDelayNanoseconds: UInt64 = 16_000_000,
            forceReload: Bool = false,
            completion: (@MainActor @Sendable (Result<DecodedImage, PipelineFailure>) -> Void)? =
                nil
        ) {
            animationPresenter?.cancel(clearImage: false)
            apply(accessibility)
            placeholderImage = placeholder
            retentionPolicy = retention
            if !forceReload, displaySession.isCurrentIdentity(request.displayIdentity) {
                if case .cancelled = displaySession.phase {
                    // loader 发起的取消会终止旧任务，但相同 display identity 仍允许显式 setImage 再次启动。
                } else {
                    return
                }
            }
            let recipe = staticLoadRecovery.install(
                request: request,
                loader: loader,
                placeholderDelayNanoseconds: placeholderDelayNanoseconds,
                completion: completion
            )
            startStaticLoad(recipe, forceReload: forceReload)
        }

        /// 取消活动订阅，并按需清除当前显示图像。
        public func cancelImageRequest(clearImage: Bool = false) {
            animationPresenter?.cancel(clearImage: clearImage)
            staticLoadRecovery.clear()
            loadTask?.cancel()
            loadTask = nil
            activeStaticLoadToken = nil
            displaySession.invalidate(clear: clearImage) { [weak self] phase in
                self?.apply(phase, completion: nil)
            }
        }

        /// 包内动画加载面使用的展示入口；不改变公开静态图 API。
        package func setAnimation(
            handle: AnimationPlaybackHandle,
            runtime: AnimationPlaybackRuntime,
            accessibility: FoveaImageViewAccessibility,
            clearCurrentImage: Bool = true,
            schedulingControl: FoveaAppKitAnimationSchedulingControl = .platformDefault
        ) {
            apply(accessibility)
            staticLoadRecovery.clear()
            loadTask?.cancel()
            loadTask = nil
            activeStaticLoadToken = nil
            displaySession.invalidate(clear: false) { _ in }
            if clearCurrentImage { image = nil }
            let presenter =
                animationPresenter
                ?? FoveaAnimatedImageViewPresenter(imageView: self)
            animationPresenter = presenter
            presenter.benchmarkPresentationHandler =
                animationBenchmarkPresentationHandlerStorage
            presenter.benchmarkRefreshSampleHandler =
                animationBenchmarkRefreshSampleHandlerStorage
            presenter.present(
                handle: handle,
                runtime: runtime,
                initiallyVisible: isEffectivelyVisibleForAnimation,
                schedulingControl: schedulingControl
            )
        }

        package func setLiveMultipartJPEG(
            session: MultipartJPEGLivePlaybackSession,
            accessibility: FoveaImageViewAccessibility,
            clearCurrentImage: Bool = true
        ) {
            apply(accessibility)
            staticLoadRecovery.clear()
            loadTask?.cancel()
            loadTask = nil
            activeStaticLoadToken = nil
            displaySession.invalidate(clear: false) { _ in }
            if clearCurrentImage { image = nil }
            let presenter =
                animationPresenter
                ?? FoveaAnimatedImageViewPresenter(imageView: self)
            animationPresenter = presenter
            presenter.presentLive(
                session: session,
                initiallyVisible: isEffectivelyVisibleForAnimation
            )
        }

        package func setLiveMultipartJPEG(
            handle: MultipartJPEGLivePlaybackHandle,
            accessibility: FoveaImageViewAccessibility,
            clearCurrentImage: Bool = true
        ) {
            apply(accessibility)
            staticLoadRecovery.clear()
            loadTask?.cancel()
            loadTask = nil
            activeStaticLoadToken = nil
            displaySession.invalidate(clear: false) { _ in }
            if clearCurrentImage { image = nil }
            let presenter =
                animationPresenter
                ?? FoveaAnimatedImageViewPresenter(imageView: self)
            animationPresenter = presenter
            presenter.presentLive(
                handle: handle,
                initiallyVisible: isEffectivelyVisibleForAnimation
            )
        }

        package func cancelAnimation(clearImage: Bool = false) {
            animationPresenter?.cancel(clearImage: clearImage)
        }

        /// 在复用视图中调用，确保旧请求与旧像素都不会进入下一次展示身份。
        public override func prepareForReuse() {
            super.prepareForReuse()
            cancelImageRequest(clearImage: true)
            placeholderImage = nil
            apply(.decorative)
        }

        /// 启用自动取消时，取消窗口外工作。
        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let presentsAnimation = animationPresenter?.isPresenting == true
            updateAnimationVisibility()
            guard automaticallyCancelsWhenRemovedFromWindow, !presentsAnimation else { return }
            if window == nil {
                if activeStaticLoadToken != nil {
                    suspendStaticLoadForWindowDetach()
                }
            } else if let recipe = staticLoadRecovery.takeResumeRecipe() {
                startStaticLoad(recipe, forceReload: false)
            }
        }

        /// 底层显示缩放变化时重新构建 AppKit 图像。
        public override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            if animationPresenter?.isPresenting == true {
                animationPresenter?.refreshForBackingScaleChange()
            } else {
                apply(displaySession.phase, completion: nil)
            }
        }

        @_spi(AnimationLifecycle)
        public override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            updateAnimationVisibility()
        }

        @_spi(AnimationLifecycle)
        public override func viewDidHide() {
            super.viewDidHide()
            updateAnimationVisibility()
        }

        @_spi(AnimationLifecycle)
        public override func viewDidUnhide() {
            super.viewDidUnhide()
            updateAnimationVisibility()
        }

        @_spi(AnimationLifecycle)
        public override func layout() {
            super.layout()
            animationPresenter?.refreshForLayoutChange()
            updateAnimationVisibility()
        }

        package var animationVisibilityForTesting: Bool? {
            animationPresenter?.effectiveVisibilityForTesting
        }

        package var animationDisplayLinkPausedForTesting: Bool? {
            animationPresenter?.presentationDriverPausedForTesting
        }

        package var animationCompositorPresentationActiveForTesting: Bool? {
            animationPresenter?.compositorPresentationActiveForTesting
        }

        package var animationCompositorLayerAttachedForTesting: Bool? {
            animationPresenter?.compositorLayerAttachedForTesting
        }

        package var animationCompositorAnimationBeginTimeForTesting: CFTimeInterval? {
            animationPresenter?.compositorAnimationBeginTimeForTesting
        }

        package var animationCompositorLayerCurrentTimeForTesting: CFTimeInterval? {
            animationPresenter?.compositorLayerCurrentTimeForTesting
        }

        package var animationCompositorLayerFrameForTesting: CGRect? {
            animationPresenter?.compositorLayerFrameForTesting
        }

        package var animationBenchmarkPresentationHandler:
            FoveaAppKitAnimationBenchmarkPresentationHandler?
        {
            get { animationBenchmarkPresentationHandlerStorage }
            set {
                animationBenchmarkPresentationHandlerStorage = newValue
                animationPresenter?.benchmarkPresentationHandler = newValue
            }
        }

        package var animationBenchmarkRefreshSampleHandler:
            FoveaAppKitAnimationRefreshSampleHandler?
        {
            get { animationBenchmarkRefreshSampleHandlerStorage }
            set {
                animationBenchmarkRefreshSampleHandlerStorage = newValue
                animationPresenter?.benchmarkRefreshSampleHandler = newValue
            }
        }

        package var animationPresentationDiagnostics:
            FoveaAppKitAnimationPresentationDiagnosticsSnapshot?
        {
            animationPresenter?.presentationDiagnostics
        }

        private func startStaticLoad(
            _ recipe: ImageViewStaticLoadRecovery.Recipe,
            forceReload: Bool
        ) {
            loadTask?.cancel()
            activeStaticLoadToken = recipe.token
            let coreRetention = retentionPolicy.coreRetention
            displaySession.prepareForIdentityChange(
                to: recipe.request.displayIdentity,
                retention: coreRetention
            ) { [weak self] phase in
                self?.apply(phase, completion: nil)
            }

            let session = displaySession
            loadTask = Task { @MainActor [weak self, session, recipe, coreRetention] in
                await session.load(
                    request: recipe.request,
                    loader: recipe.loader,
                    placeholderDelayNanoseconds: recipe.placeholderDelayNanoseconds,
                    retention: coreRetention,
                    force: forceReload
                ) { [weak self] phase in
                    self?.applyStaticPhase(phase, token: recipe.token)
                }
                self?.finishStaticLoadTask(token: recipe.token)
            }
        }

        private func suspendStaticLoadForWindowDetach() {
            staticLoadRecovery.suspend(resumeWhenAttached: true)
            loadTask?.cancel()
            loadTask = nil
            activeStaticLoadToken = nil
            displaySession.invalidate(clear: retentionPolicy == .clearImmediately) {
                [weak self] phase in
                self?.apply(phase, completion: nil)
            }
        }

        private func applyStaticPhase(_ phase: ImageDisplaySessionPhase, token: UUID) {
            apply(phase, completion: nil)
            switch phase {
            case .success(let decoded):
                markStaticLoadTerminal(token: token)
                staticLoadRecovery.resolve(.success(decoded), token: token)
            case .failure(let failure):
                markStaticLoadTerminal(token: token)
                staticLoadRecovery.resolve(.failure(failure), token: token)
            case .cancelled:
                markStaticLoadTerminal(token: token)
                staticLoadRecovery.clear()
            case .empty, .loading, .preview:
                break
            }
        }

        private func markStaticLoadTerminal(token: UUID) {
            guard activeStaticLoadToken == token else { return }
            activeStaticLoadToken = nil
        }

        private func finishStaticLoadTask(token: UUID) {
            if activeStaticLoadToken == token {
                activeStaticLoadToken = nil
                loadTask = nil
            } else if activeStaticLoadToken == nil {
                loadTask = nil
            }
        }

        private var isEffectivelyVisibleForAnimation: Bool {
            AnimationPresentationVisibility.isEffectivelyVisible(
                windowAttached: window != nil,
                superviewAttached: superview != nil,
                hidden: isHiddenOrHasHiddenAncestor,
                alpha: Double(alphaValue),
                intersectsVisibleRegion: true
            )
        }

        private func updateAnimationVisibility() {
            animationPresenter?.setVisible(isEffectivelyVisibleForAnimation)
        }

        private func apply(_ accessibility: FoveaImageViewAccessibility) {
            switch accessibility {
            case .decorative:
                setAccessibilityElement(false)
                setAccessibilityLabel(nil)
            case .label(let label):
                setAccessibilityElement(true)
                setAccessibilityLabel(label)
            }
        }

        private func apply(
            _ phase: ImageDisplaySessionPhase,
            completion: (@MainActor @Sendable (Result<DecodedImage, PipelineFailure>) -> Void)?
        ) {
            switch phase {
            case .empty, .loading:
                image = placeholderImage
            case .preview(let decoded), .success(let decoded):
                let scale = max(
                    1, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
                image = NSImage(
                    cgImage: decoded.cgImage,
                    size: NSSize(
                        width: CGFloat(decoded.pixelWidth) / scale,
                        height: CGFloat(decoded.pixelHeight) / scale
                    )
                )
                if case .success = phase { completion?(.success(decoded)) }
            case .failure(let failure):
                if retentionPolicy == .clearImmediately { image = placeholderImage }
                completion?(.failure(failure))
            case .cancelled:
                if retentionPolicy == .clearImmediately { image = placeholderImage }
            }
        }
    }

    @MainActor
    enum FoveaAppKitAnimationStartRunner {
        static func run(
            runtime: AnimationPlaybackRuntime,
            handle: AnimationPlaybackHandle,
            initiallyVisible: Bool,
            presentationDriver: (any FoveaAppKitAnimationPresentationDriving)?,
            usesExternalPresentationTicks: Bool,
            output: @escaping AnimationPlaybackDriver.OutputHandler,
            failure: @escaping AnimationPlaybackDriver.FailureHandler,
            externalPresentationState:
                @escaping AnimationPlaybackDriver
                .ExternalPresentationStateHandler,
            externalPresentationInvalidation:
                @escaping AnimationPlaybackDriver
                .ExternalPresentationInvalidationHandler,
            externalPresentationRevalidation:
                @escaping AnimationPlaybackDriver
                .ExternalPresentationRevalidationHandler,
            isCurrent: @escaping @MainActor @Sendable () -> Bool
        ) async throws {
            if let presentationDriver, usesExternalPresentationTicks {
                try await runExternallyDriven(
                    runtime: runtime,
                    handle: handle,
                    initiallyVisible: initiallyVisible,
                    presentationDriver: presentationDriver,
                    output: output,
                    failure: failure,
                    externalPresentationState: externalPresentationState,
                    externalPresentationInvalidation: externalPresentationInvalidation,
                    externalPresentationRevalidation: externalPresentationRevalidation,
                    isCurrent: isCurrent
                )
                return
            }
            try await runAutomatic(
                runtime: runtime,
                handle: handle,
                initiallyVisible: initiallyVisible,
                presentationDriver: presentationDriver,
                output: output,
                failure: failure,
                isCurrent: isCurrent
            )
        }

        private static func runExternallyDriven(
            runtime: AnimationPlaybackRuntime,
            handle: AnimationPlaybackHandle,
            initiallyVisible: Bool,
            presentationDriver: any FoveaAppKitAnimationPresentationDriving,
            output: @escaping AnimationPlaybackDriver.OutputHandler,
            failure: @escaping AnimationPlaybackDriver.FailureHandler,
            externalPresentationState:
                @escaping AnimationPlaybackDriver
                .ExternalPresentationStateHandler,
            externalPresentationInvalidation:
                @escaping AnimationPlaybackDriver
                .ExternalPresentationInvalidationHandler,
            externalPresentationRevalidation:
                @escaping AnimationPlaybackDriver
                .ExternalPresentationRevalidationHandler,
            isCurrent: @escaping @MainActor @Sendable () -> Bool
        ) async throws {
            try await runtime.start(
                handle,
                output: output,
                failure: failure,
                initiallyVisible: initiallyVisible,
                schedulingMode: .externalPresentationTicks,
                externalPresentationState: externalPresentationState,
                externalPresentationInvalidation: externalPresentationInvalidation,
                externalPresentationRevalidation: externalPresentationRevalidation
            )
            try Task.checkCancellation()
            guard isCurrent() else {
                presentationDriver.invalidate()
                return
            }
            presentationDriver.start()
        }

        private static func runAutomatic(
            runtime: AnimationPlaybackRuntime,
            handle: AnimationPlaybackHandle,
            initiallyVisible: Bool,
            presentationDriver: (any FoveaAppKitAnimationPresentationDriving)?,
            output: @escaping AnimationPlaybackDriver.OutputHandler,
            failure: @escaping AnimationPlaybackDriver.FailureHandler,
            isCurrent: @escaping @MainActor @Sendable () -> Bool
        ) async throws {
            try await runtime.start(
                handle,
                output: output,
                failure: failure,
                initiallyVisible: initiallyVisible
            )
            guard let presentationDriver else { return }
            try Task.checkCancellation()
            guard isCurrent() else {
                presentationDriver.invalidate()
                return
            }
            presentationDriver.setPlaybackActive(initiallyVisible)
            presentationDriver.start()
        }
    }
#endif
