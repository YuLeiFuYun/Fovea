#if canImport(UIKit)
    import Dispatch
    import FoveaCore
    import ImageCraftCore
    import UIKit

    // Presenter 只拥有 MainActor 像素发布与 presentation generation；解码、时钟、缓存和网络仍由 FoveaCore/System 持有。
    // 静态动画与 live MJPEG 在同一视图上互斥，任何替换都先撤销旧发布身份。
    /// 将一个独立动画 handle 的输出绑定到 UIKit image view，并阻止旧 presentation 迟到覆盖。
    @MainActor
    package final class FoveaAnimatedImageViewPresenter {
        private weak var imageView: UIImageView?
        private var handle: AnimationPlaybackHandle?
        private var liveSession: MultipartJPEGLivePlaybackSession?
        private var liveHandle: MultipartJPEGLivePlaybackHandle?
        private var startTask: Task<Void, Never>?
        private var visibilityTask: Task<Void, Never>?
        private var displayLinkDriver: FoveaAnimationDisplayLinkDriver?
        private var presentationID = UUID()
        private var lastDecodedImage: DecodedImage?
        private var lastEffectiveVisibility: Bool?
        private var lastBenchmarkPresentationFrameIndex: Int?
        package private(set) var isPresenting = false
        package private(set) var lastFailureDescription: String?
        package var benchmarkPresentationHandler: (@MainActor @Sendable (Int, UInt64) -> Void)?

        package init(imageView: UIImageView) {
            self.imageView = imageView
        }

        isolated deinit {
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
            displayCadenceMode: FoveaAnimationDisplayCadenceMode = .maximumRefresh,
            maximumDisplayFramesPerSecond: Int? = nil
        ) {
            cancel(clearImage: false)
            let presentationID = UUID()
            self.presentationID = presentationID
            self.handle = handle
            let preferredFramesPerSecond: Int?
            switch displayCadenceMode {
            case .maximumRefresh:
                preferredFramesPerSecond = nil
            case .timelineAlignedExperiment:
                preferredFramesPerSecond = maximumDisplayFramesPerSecond.flatMap { maximum in
                    handle.presentationCadenceRecommendation?.preferredFramesPerSecond(
                        maximumFramesPerSecond: maximum
                    )
                }
            }
            let displayLinkDriver = FoveaAnimationDisplayLinkDriver(
                driver: handle.driver,
                requestedPreferredFramesPerSecond: preferredFramesPerSecond
            )
            self.displayLinkDriver = displayLinkDriver
            lastEffectiveVisibility = initiallyVisible
            lastBenchmarkPresentationFrameIndex = nil
            isPresenting = true
            lastFailureDescription = nil
            startTask = Task { [weak self, displayLinkDriver] in
                do {
                    try await runtime.start(
                        handle,
                        output: { [weak self] output in
                            guard let decoded = output.image else { return }
                            await self?.applyAnimation(
                                decoded,
                                frameIndex: output.decision.frameIndex,
                                presentationID: presentationID
                            )
                        },
                        failure: { [weak self] error in
                            await self?.recordFailure(error, presentationID: presentationID)
                        },
                        initiallyVisible: initiallyVisible,
                        schedulingMode: .externalPresentationTicks,
                        externalPresentationState: {
                            [weak displayLinkDriver = displayLinkDriver] active in
                            await displayLinkDriver?.setPlaybackActive(active)
                        }
                    )
                    try Task.checkCancellation()
                    guard let self, self.presentationID == presentationID else {
                        displayLinkDriver.invalidate()
                        return
                    }
                    displayLinkDriver.start()
                } catch is CancellationError {
                    return
                } catch {
                    self?.recordFailure(error, presentationID: presentationID)
                }
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
            let handle = handle
            let liveSession = liveSession
            let liveHandle = liveHandle
            let presentationID = presentationID
            if !visible { displayLinkDriver?.setPlaybackActive(false) }
            visibilityTask = Task { [weak self, previousVisibilityTask] in
                await self?.applyVisibility(
                    visible,
                    previousTask: previousVisibilityTask,
                    handle: handle,
                    liveSession: liveSession,
                    liveHandle: liveHandle,
                    presentationID: presentationID
                )
            }
        }

        private func applyVisibility(
            _ visible: Bool,
            previousTask: Task<Void, Never>?,
            handle: AnimationPlaybackHandle?,
            liveSession: MultipartJPEGLivePlaybackSession?,
            liveHandle: MultipartJPEGLivePlaybackHandle?,
            presentationID: UUID
        ) async {
            if let previousTask { await previousTask.value }
            guard isPresenting, self.presentationID == presentationID else { return }
            if let handle {
                do { try await handle.driver.setVisible(visible) }
                catch {
                    guard isPresenting, self.presentationID == presentationID else { return }
                    recordFailure(error, presentationID: presentationID)
                }
            }
            guard isPresenting, self.presentationID == presentationID else { return }
            if let liveSession { await liveSession.setVisible(visible) }
            guard isPresenting, self.presentationID == presentationID else { return }
            if let liveHandle { await liveHandle.setVisible(visible) }
        }

        package func refreshForDisplayScaleChange() {
            guard let lastDecodedImage, isPresenting else { return }
            applyImage(lastDecodedImage)
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
            displayLinkDriver?.invalidate()
            displayLinkDriver = nil
            let handle = self.handle
            let liveSession = self.liveSession
            let liveHandle = self.liveHandle
            self.handle = nil
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

        package var presentationDiagnostics: FoveaAnimationPresentationDiagnosticsSnapshot? {
            guard let displayLinkDriver else { return nil }
            let snapshot = displayLinkDriver.presentationDiagnostics
            return FoveaAnimationPresentationDiagnosticsSnapshot(
                acceptedTargetCount: snapshot.acceptedTargetCount,
                consumedTargetCount: snapshot.consumedTargetCount,
                supersededPendingTargetCount: snapshot.supersededPendingTargetCount,
                rejectedNonmonotonicTargetCount: snapshot.rejectedNonmonotonicTargetCount,
                lifecycleClearedPendingTargetCount: snapshot.lifecycleClearedPendingTargetCount,
                hasPendingTarget: snapshot.hasPendingTarget,
                lastAcceptedTargetNanoseconds: snapshot.lastAcceptedTargetNanoseconds,
                isDisplayLinkPaused: snapshot.isDisplayLinkPaused,
                requestedPreferredFramesPerSecond: snapshot.requestedPreferredFramesPerSecond,
                effectiveVisibility: lastEffectiveVisibility
            )
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
            benchmarkPresentationHandler?(frameIndex, DispatchTime.now().uptimeNanoseconds)
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
            imageView.image = UIImage(
                cgImage: decoded.cgImage,
                scale: max(1, imageView.traitCollection.displayScale),
                orientation: .up
            )
        }
    }
#endif
