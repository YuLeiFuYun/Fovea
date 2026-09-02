#if canImport(AppKit)
    import AppKit
    import Dispatch
    import FoveaCore
    import ImageCraftCore
    import QuartzCore

    // Presenter 只拥有 MainActor 像素发布与 presentation generation；解码、时钟、缓存和网络仍由 FoveaCore/System 持有。
    // 静态动画与 live MJPEG 在同一视图上互斥，任何替换都先撤销旧发布身份。
    /// 将一个独立动画 handle 的输出绑定到 AppKit image view，并阻止旧 presentation 迟到覆盖。
    @MainActor
    package final class FoveaAnimatedImageViewPresenter {
        private weak var imageView: NSImageView?
        private var handle: AnimationPlaybackHandle?
        private var animationRuntime: AnimationPlaybackRuntime?
        private var animationDriverHasStarted = false
        private var liveSession: MultipartJPEGLivePlaybackSession?
        private var liveHandle: MultipartJPEGLivePlaybackHandle?
        private var startTask: Task<Void, Never>?
        private var visibilityTask: Task<Void, Never>?
        private var compositorUpgradeTask: Task<Void, Never>?
        private var presentationDriver: (any FoveaAppKitAnimationPresentationDriving)?
        private let compositor: FoveaAppKitCompositorController
        private var presentationID = UUID()
        private var lastDecodedImage: DecodedImage?
        private var lastEffectiveVisibility: Bool?
        private var lastBenchmarkPresentationFrameIndex: Int?
        private var schedulingControl: FoveaAppKitAnimationSchedulingControl = .platformDefault
        package private(set) var isPresenting = false
        package private(set) var lastFailureDescription: String?
        package var benchmarkPresentationHandler: FoveaAppKitAnimationBenchmarkPresentationHandler?
        package var benchmarkRefreshSampleHandler: FoveaAppKitAnimationRefreshSampleHandler?

        package init(imageView: NSImageView) {
            self.imageView = imageView
            self.compositor = FoveaAppKitCompositorController(imageView: imageView)
        }

        deinit {
            startTask?.cancel()
            visibilityTask?.cancel()
            if let handle { Task { await handle.cancel() } }
            if let liveSession { Task { await liveSession.cancel() } }
            if let liveHandle { Task { await liveHandle.cancel() } }
        }

        package func present(
            handle: AnimationPlaybackHandle,
            runtime: AnimationPlaybackRuntime,
            initiallyVisible: Bool,
            schedulingControl: FoveaAppKitAnimationSchedulingControl = .platformDefault
        ) {
            cancel(clearImage: false)
            let presentationID = UUID()
            self.presentationID = presentationID
            self.handle = handle
            animationRuntime = runtime
            animationDriverHasStarted = false
            self.schedulingControl = schedulingControl
            let presentationDriver: (any FoveaAppKitAnimationPresentationDriving)?
            if #available(macOS 14.0, *), let imageView,
                schedulingControl.usesExternalPresentationTicks
                    || benchmarkRefreshSampleHandler != nil
            {
                let requestedPreferredFramesPerSecond: Int?
                if schedulingControl.coalescesUnchangedSourceFrames {
                    let maximumFramesPerSecond = max(
                        1,
                        imageView.window?.screen?.maximumFramesPerSecond
                            ?? NSScreen.main?.maximumFramesPerSecond
                            ?? 60
                    )
                    requestedPreferredFramesPerSecond =
                        handle.presentationCadenceRecommendation?.preferredFramesPerSecond(
                            maximumFramesPerSecond: maximumFramesPerSecond
                        )
                } else {
                    requestedPreferredFramesPerSecond = nil
                }
                presentationDriver = FoveaAnimationDisplayLinkDriver(
                    view: imageView,
                    driver: handle.driver,
                    drivesPlayback: schedulingControl.usesExternalPresentationTicks,
                    coalescesUnchangedSourceFrames:
                        schedulingControl.coalescesUnchangedSourceFrames,
                    requestedPreferredFramesPerSecond: requestedPreferredFramesPerSecond,
                    refreshFrameProvider: { [weak self] in
                        self?.lastBenchmarkPresentationFrameIndex
                    },
                    refreshSampleHandler: benchmarkRefreshSampleHandler
                )
            } else {
                presentationDriver = nil
            }
            self.presentationDriver = presentationDriver
            lastEffectiveVisibility = initiallyVisible
            lastBenchmarkPresentationFrameIndex = nil
            isPresenting = true
            lastFailureDescription = nil

            // AppKit 的视图绑定 display link 在视图脱离层级时本就不会回调。现代外部 tick 因此延后到
            // 首次可见再启动，让 runtime.start 仍能立即发布首帧，而不伪造合成 vsync；macOS 12-13
            // 的旧 deadline 调度继续保留“隐藏启动、恢复后继续”的既有语义。
            let defersExternalStartup =
                schedulingControl.usesExternalPresentationTicks
                && presentationDriver != nil
                && !initiallyVisible
            if !defersExternalStartup {
                _ = startAnimationIfNeeded(initiallyVisible: initiallyVisible)
            }
        }

        package func presentLive(
            session: MultipartJPEGLivePlaybackSession,
            initiallyVisible: Bool
        ) {
            cancel(clearImage: false)
            let presentationID = UUID()
            self.presentationID = presentationID
            liveSession = session
            lastEffectiveVisibility = initiallyVisible
            isPresenting = true
            lastFailureDescription = nil
            startTask = Task { [weak self] in
                do {
                    try await session.start(
                        output: { [weak self] output in
                            await self?.apply(
                                output.image,
                                presentationID: presentationID
                            )
                        },
                        failure: { [weak self] error in
                            await self?.recordFailure(
                                error,
                                presentationID: presentationID
                            )
                        },
                        initiallyVisible: initiallyVisible
                    )
                } catch is CancellationError {
                    return
                } catch {
                    self?.recordFailure(error, presentationID: presentationID)
                }
            }
        }

        package func presentLive(
            handle: MultipartJPEGLivePlaybackHandle,
            initiallyVisible: Bool
        ) {
            cancel(clearImage: false)
            let presentationID = UUID()
            self.presentationID = presentationID
            liveHandle = handle
            lastEffectiveVisibility = initiallyVisible
            isPresenting = true
            lastFailureDescription = nil
            startTask = Task { [weak self] in
                do {
                    try await handle.start(
                        output: { [weak self] output in
                            await self?.apply(
                                output.image,
                                presentationID: presentationID
                            )
                        },
                        failure: { [weak self] error in
                            await self?.recordFailure(
                                error,
                                presentationID: presentationID
                            )
                        },
                        initiallyVisible: initiallyVisible
                    )
                } catch is CancellationError {
                    return
                } catch {
                    self?.recordFailure(error, presentationID: presentationID)
                }
            }
        }

        package func setVisible(_ visible: Bool) {
            guard isPresenting, lastEffectiveVisibility != visible else { return }
            lastEffectiveVisibility = visible
            let previousVisibilityTask = visibilityTask
            if !visible { presentationDriver?.setPlaybackActive(false) }
            let startedNow: Bool
            if visible {
                startedNow = startAnimationIfNeeded(initiallyVisible: true)
            } else {
                startedNow = false
            }
            let animationDriverHasStarted = animationDriverHasStarted
            let handle = handle
            let liveSession = liveSession
            let liveHandle = liveHandle
            let startTask = startTask
            let presentationID = presentationID
            visibilityTask = Task { [weak self, previousVisibilityTask] in
                await FoveaAppKitPresenterVisibilityRunner.apply(
                    visible: visible,
                    previousTask: previousVisibilityTask,
                    handle: handle,
                    liveSession: liveSession,
                    liveHandle: liveHandle,
                    animationDriverHasStarted: animationDriverHasStarted,
                    startedNow: startedNow,
                    startTask: startTask,
                    activateAutomaticPresentation: { [weak self] in
                        guard visible,
                            self?.schedulingControl == .automaticDeadlineLoop
                        else { return }
                        self?.presentationDriver?.setPlaybackActive(true)
                    },
                    isCurrent: { [weak self] in
                        self?.isCurrentPresentation(presentationID) == true
                    },
                    recordFailure: { [weak self] error in
                        self?.recordFailure(error, presentationID: presentationID)
                    }
                )
            }
        }

        private func isCurrentPresentation(_ presentationID: UUID) -> Bool {
            isPresenting && self.presentationID == presentationID
        }

        package func refreshForBackingScaleChange() {
            guard isPresenting else { return }
            if compositor.isActive {
                compositor.updateGeometry()
                return
            }
            guard let lastDecodedImage else { return }
            applyImage(lastDecodedImage)
        }

        package func refreshForLayoutChange() {
            guard isPresenting, compositor.isActive else { return }
            guard compositor.supportsGeometry else {
                removeCompositorPresentation(preserveCurrentImage: true)
                presentationDriver?.setPlaybackActive(true)
                return
            }
            compositor.updateGeometry()
        }

        package func refreshForImageViewGeometryPolicyChange() {
            guard isPresenting else { return }
            compositorUpgradeTask?.cancel()
            compositorUpgradeTask = nil
            if compositor.isActive {
                refreshForLayoutChange()
                return
            }
            guard compositor.supportsGeometry,
                lastEffectiveVisibility == true,
                let handle,
                let presentationDriver
            else { return }
            let presentationID = presentationID
            compositorUpgradeTask = Task { [weak self, weak presentationDriver] in
                guard let self, let presentationDriver else { return }
                _ = await self.attemptCompositorUpgradeIfEligible(
                    handle: handle,
                    presentationDriver: presentationDriver,
                    presentationID: presentationID
                )
                guard self.presentationID == presentationID else { return }
                self.compositorUpgradeTask = nil
            }
        }

        package func cancel(clearImage: Bool) {
            presentationID = UUID()
            isPresenting = false
            lastDecodedImage = nil
            lastEffectiveVisibility = nil
            lastBenchmarkPresentationFrameIndex = nil
            lastFailureDescription = nil
            startTask?.cancel()
            startTask = nil
            visibilityTask?.cancel()
            visibilityTask = nil
            compositorUpgradeTask?.cancel()
            compositorUpgradeTask = nil
            presentationDriver?.invalidate()
            presentationDriver = nil
            removeCompositorPresentation(preserveCurrentImage: !clearImage)
            let handle = self.handle
            let liveSession = self.liveSession
            let liveHandle = self.liveHandle
            self.handle = nil
            animationRuntime = nil
            animationDriverHasStarted = false
            schedulingControl = .platformDefault
            self.liveSession = nil
            self.liveHandle = nil
            if let handle { Task { await handle.cancel() } }
            if let liveSession { Task { await liveSession.cancel() } }
            if let liveHandle { Task { await liveHandle.cancel() } }
            if clearImage { imageView?.image = nil }
        }

        package var effectiveVisibilityForTesting: Bool? {
            lastEffectiveVisibility
        }

        package var presentationDriverPausedForTesting: Bool? {
            presentationDriver?.isPausedForTesting
        }

        package var compositorPresentationActiveForTesting: Bool {
            compositor.isActive
        }

        package var compositorRetainedFrameCountForTesting: Int {
            compositor.retainedFrameCount
        }

        package var compositorLayerAttachedForTesting: Bool {
            compositor.layerAttached
        }

        package var compositorAnimationBeginTimeForTesting: CFTimeInterval? {
            compositor.animationBeginTime
        }

        package var compositorAnimationRepeatCountForTesting: Float? {
            compositor.animationRepeatCount
        }

        package var compositorPresentationFrameIndexForTesting: Int? {
            compositor.presentationFrameIndex
        }

        package var compositorFiniteCompletionDeadlineNanosecondsForTesting: UInt64? {
            compositor.finiteCompletionDeadlineNanoseconds
        }

        package func completeFiniteCompositorForTesting() async
            -> AnimationPlaybackTickDisposition?
        {
            guard let handle,
                let deadline = compositor.finiteCompletionDeadlineNanoseconds
            else { return nil }
            return await handle.driver.tick(atPresentationNanoseconds: deadline)
        }

        package var compositorLayerCurrentTimeForTesting: CFTimeInterval? {
            compositor.layerCurrentTime
        }

        package var compositorLayerFrameForTesting: CGRect? {
            compositor.layerFrame
        }

        package var presentationDiagnostics: FoveaAppKitAnimationPresentationDiagnosticsSnapshot? {
            guard #available(macOS 14.0, *),
                let displayLinkDriver = presentationDriver as? FoveaAnimationDisplayLinkDriver
            else { return nil }
            return FoveaAppKitAnimationPresentationDiagnosticsSnapshot(
                driver: displayLinkDriver,
                effectiveVisibility: lastEffectiveVisibility
            )
        }

        @discardableResult
        private func startAnimationIfNeeded(initiallyVisible: Bool) -> Bool {
            guard !animationDriverHasStarted,
                let handle,
                let runtime = animationRuntime
            else { return false }
            animationDriverHasStarted = true
            let presentationID = presentationID
            let presentationDriver = presentationDriver
            startTask = Task { [weak self, weak presentationDriver] in
                let usesExternalPresentationTicks =
                    self?.schedulingControl.usesExternalPresentationTicks == true
                do {
                    try await FoveaAppKitAnimationStartRunner.run(
                        runtime: runtime,
                        handle: handle,
                        initiallyVisible: initiallyVisible,
                        presentationDriver: presentationDriver,
                        usesExternalPresentationTicks: usesExternalPresentationTicks,
                        output: { [weak self, weak presentationDriver] output in
                            await self?.applyAnimationOutput(
                                output,
                                handle: handle,
                                presentationDriver: presentationDriver,
                                allowsCompositorUpgrade: usesExternalPresentationTicks,
                                presentationID: presentationID
                            )
                        },
                        failure: { [weak self] error in
                            await self?.recordFailure(error, presentationID: presentationID)
                        },
                        externalPresentationState: { [weak self, weak presentationDriver] active in
                            await self?.applyExternalPresentationState(
                                active,
                                presentationDriver: presentationDriver,
                                presentationID: presentationID
                            )
                        },
                        externalPresentationInvalidation: {
                            [weak self, weak presentationDriver] active in
                            await self?.invalidateExternalPresentation(
                                active: active,
                                presentationDriver: presentationDriver,
                                presentationID: presentationID
                            )
                        },
                        externalPresentationRevalidation: {
                            [weak self, weak presentationDriver] active in
                            await self?.applyExternalPresentationState(
                                active,
                                presentationDriver: presentationDriver,
                                presentationID: presentationID
                            )
                        },
                        isCurrent: { [weak self] in
                            self?.isCurrentPresentation(presentationID) == true
                        }
                    )
                } catch is CancellationError {
                    return
                } catch {
                    self?.recordFailure(error, presentationID: presentationID)
                }
            }
            return true
        }

        private func applyAnimationOutput(
            _ output: AnimationPlaybackOutput,
            handle: AnimationPlaybackHandle,
            presentationDriver: (any FoveaAppKitAnimationPresentationDriving)?,
            allowsCompositorUpgrade: Bool,
            presentationID: UUID
        ) async {
            guard let decoded = output.image else { return }
            applyAnimation(
                decoded,
                frameIndex: output.decision.frameIndex,
                presentationID: presentationID
            )
            guard allowsCompositorUpgrade,
                output.automaticWholeTrackHandoffAvailable,
                let presentationDriver
            else { return }
            _ = await attemptCompositorUpgradeIfEligible(
                handle: handle,
                presentationDriver: presentationDriver,
                presentationID: presentationID
            )
        }

        private func applyExternalPresentationState(
            _ active: Bool,
            presentationDriver: (any FoveaAppKitAnimationPresentationDriving)?,
            presentationID: UUID
        ) async {
            guard isCurrentPresentation(presentationID) else { return }
            if compositor.isActive {
                if active {
                    presentationDriver?.setPlaybackActive(false)
                } else {
                    removeCompositorPresentation(preserveCurrentImage: true)
                    presentationDriver?.setPlaybackActive(false)
                }
                return
            }
            guard active,
                let presentationDriver,
                let handle
            else {
                presentationDriver?.setPlaybackActive(active)
                return
            }
            if await attemptCompositorUpgradeIfEligible(
                handle: handle,
                presentationDriver: presentationDriver,
                presentationID: presentationID
            ) {
                return
            }
            presentationDriver.setPlaybackActive(true)
        }

        private func invalidateExternalPresentation(
            active: Bool,
            presentationDriver: (any FoveaAppKitAnimationPresentationDriving)?,
            presentationID: UUID
        ) {
            guard isCurrentPresentation(presentationID), compositor.isActive else { return }
            removeCompositorPresentation(preserveCurrentImage: true)
            presentationDriver?.setPlaybackActive(active)
        }

        private func attemptCompositorUpgradeIfEligible(
            handle: AnimationPlaybackHandle,
            presentationDriver: any FoveaAppKitAnimationPresentationDriving,
            presentationID: UUID
        ) async -> Bool {
            guard isCompositorEligible(presentationID) else { return false }
            return await compositor.attemptUpgrade(
                handle: handle,
                presentationDriver: presentationDriver,
                isEligible: { [weak self] in
                    self?.isCompositorEligible(presentationID) == true
                },
                finiteCompletion: { [weak self, weak presentationDriver] in
                    guard let self, let presentationDriver,
                        self.isCurrentPresentation(presentationID)
                    else { return }
                    self.removeCompositorPresentation(preserveCurrentImage: true)
                    presentationDriver.setPlaybackActive(true)
                }
            )
        }

        private func isCompositorEligible(_ presentationID: UUID) -> Bool {
            schedulingControl == .platformDefault
                && benchmarkPresentationHandler == nil
                && benchmarkRefreshSampleHandler == nil
                && isCurrentPresentation(presentationID)
                && lastEffectiveVisibility == true
                && !compositor.isActive
                && compositor.supportsGeometry
        }

        private func removeCompositorPresentation(preserveCurrentImage: Bool) {
            if let preserved = compositor.removePresentation(
                preserveCurrentImage: preserveCurrentImage
            ) {
                lastDecodedImage = preserved
            }
        }

        private func applyAnimation(
            _ decoded: DecodedImage,
            frameIndex: Int,
            presentationID: UUID
        ) {
            guard isPresenting, self.presentationID == presentationID else { return }
            lastDecodedImage = decoded
            applyImage(decoded)
            guard lastBenchmarkPresentationFrameIndex != frameIndex else { return }
            lastBenchmarkPresentationFrameIndex = frameIndex
            benchmarkPresentationHandler?(
                frameIndex,
                DispatchTime.now().uptimeNanoseconds
            )
        }

        private func apply(
            _ decoded: DecodedImage,
            presentationID: UUID
        ) {
            guard isPresenting, self.presentationID == presentationID else { return }
            lastDecodedImage = decoded
            applyImage(decoded)
        }

        private func recordFailure(
            _ error: any Error,
            presentationID: UUID
        ) {
            guard isPresenting, self.presentationID == presentationID else { return }
            lastFailureDescription = String(describing: error)
        }

        private func applyImage(_ decoded: DecodedImage) {
            guard let imageView else { return }
            let scale = max(
                1,
                imageView.window?.backingScaleFactor
                    ?? NSScreen.main?.backingScaleFactor
                    ?? 1
            )
            imageView.image = NSImage(
                cgImage: decoded.cgImage,
                size: NSSize(
                    width: CGFloat(decoded.pixelWidth) / scale,
                    height: CGFloat(decoded.pixelHeight) / scale
                )
            )
        }
    }
#endif
