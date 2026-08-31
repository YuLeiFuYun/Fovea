#if canImport(AppKit)
    import AppKit
    import Dispatch
    import FoveaCore
    import ImageCraftCore
    import QuartzCore

    package enum FoveaAppKitAnimationSchedulingControl: Sendable {
        case platformDefault
        case externalEveryRefreshControl
        case automaticDeadlineLoop

        var usesExternalPresentationTicks: Bool {
            switch self {
            case .platformDefault, .externalEveryRefreshControl: true
            case .automaticDeadlineLoop: false
            }
        }

        var coalescesUnchangedSourceFrames: Bool {
            self == .platformDefault
        }
    }

    package typealias FoveaAppKitAnimationBenchmarkPresentationHandler =
        @MainActor @Sendable (Int, UInt64) -> Void

    package struct FoveaAppKitAnimationPresentationDiagnosticsSnapshot: Equatable, Sendable {
        package let acceptedTargetCount: UInt64
        package let consumedTargetCount: UInt64
        package let supersededPendingTargetCount: UInt64
        package let rejectedNonmonotonicTargetCount: UInt64
        package let lifecycleClearedPendingTargetCount: UInt64
        package let hasPendingTarget: Bool
        package let lastAcceptedTargetNanoseconds: UInt64?
        package let isDisplayLinkPaused: Bool
        package let effectiveVisibility: Bool?

        init(
            acceptedTargetCount: UInt64,
            consumedTargetCount: UInt64,
            supersededPendingTargetCount: UInt64,
            rejectedNonmonotonicTargetCount: UInt64,
            lifecycleClearedPendingTargetCount: UInt64,
            hasPendingTarget: Bool,
            lastAcceptedTargetNanoseconds: UInt64?,
            isDisplayLinkPaused: Bool,
            effectiveVisibility: Bool?
        ) {
            self.acceptedTargetCount = acceptedTargetCount
            self.consumedTargetCount = consumedTargetCount
            self.supersededPendingTargetCount = supersededPendingTargetCount
            self.rejectedNonmonotonicTargetCount = rejectedNonmonotonicTargetCount
            self.lifecycleClearedPendingTargetCount = lifecycleClearedPendingTargetCount
            self.hasPendingTarget = hasPendingTarget
            self.lastAcceptedTargetNanoseconds = lastAcceptedTargetNanoseconds
            self.isDisplayLinkPaused = isDisplayLinkPaused
            self.effectiveVisibility = effectiveVisibility
        }

        @available(macOS 14.0, *)
        @MainActor
        init(
            driver: FoveaAnimationDisplayLinkDriver,
            effectiveVisibility: Bool?
        ) {
            let snapshot = driver.presentationDiagnostics
            self.init(
                acceptedTargetCount: snapshot.acceptedTargetCount,
                consumedTargetCount: snapshot.consumedTargetCount,
                supersededPendingTargetCount: snapshot.supersededPendingTargetCount,
                rejectedNonmonotonicTargetCount: snapshot.rejectedNonmonotonicTargetCount,
                lifecycleClearedPendingTargetCount: snapshot.lifecycleClearedPendingTargetCount,
                hasPendingTarget: snapshot.hasPendingTarget,
                lastAcceptedTargetNanoseconds: snapshot.lastAcceptedTargetNanoseconds,
                isDisplayLinkPaused: snapshot.isDisplayLinkPaused,
                effectiveVisibility: effectiveVisibility
            )
        }
    }

    package typealias FoveaAppKitAnimationRefreshFrameProvider =
        @MainActor @Sendable () -> Int?
    package typealias FoveaAppKitAnimationRefreshSampleHandler =
        @MainActor @Sendable (Int, UInt64) -> Void

    @MainActor
    package protocol FoveaAppKitAnimationPresentationDriving: AnyObject, Sendable {
        func start()
        func setPlaybackActive(_ active: Bool)
        func invalidate()
        var isPausedForTesting: Bool { get }
    }

    @MainActor
    enum FoveaAppKitPresenterVisibilityRunner {
        static func apply(
            visible: Bool,
            previousTask: Task<Void, Never>?,
            handle: AnimationPlaybackHandle?,
            liveSession: MultipartJPEGLivePlaybackSession?,
            liveHandle: MultipartJPEGLivePlaybackHandle?,
            animationDriverHasStarted: Bool,
            startedNow: Bool,
            startTask: Task<Void, Never>?,
            activateAutomaticPresentation: () -> Void,
            isCurrent: () -> Bool,
            recordFailure: (any Error) -> Void
        ) async {
            if let previousTask { await previousTask.value }
            guard isCurrent() else { return }
            guard
                await applyAnimationVisibility(
                    visible: visible,
                    handle: handle,
                    animationDriverHasStarted: animationDriverHasStarted,
                    startedNow: startedNow,
                    startTask: startTask,
                    isCurrent: isCurrent,
                    recordFailure: recordFailure
                )
            else { return }
            guard isCurrent() else { return }
            activateAutomaticPresentation()
            if let liveSession { await liveSession.setVisible(visible) }
            guard isCurrent() else { return }
            if let liveHandle { await liveHandle.setVisible(visible) }
        }

        private static func applyAnimationVisibility(
            visible: Bool,
            handle: AnimationPlaybackHandle?,
            animationDriverHasStarted: Bool,
            startedNow: Bool,
            startTask: Task<Void, Never>?,
            isCurrent: () -> Bool,
            recordFailure: (any Error) -> Void
        ) async -> Bool {
            guard let handle, animationDriverHasStarted, !startedNow else { return true }
            if let startTask { await startTask.value }
            guard isCurrent() else { return false }
            do {
                try await handle.driver.setVisible(visible)
            } catch {
                guard isCurrent() else { return false }
                recordFailure(error)
            }
            return true
        }
    }

    @MainActor
    final class FoveaAppKitCompositorController {
        private weak var imageView: NSImageView?
        private var layer: CALayer?
        private var snapshot: AnimationPlaybackResidentFramesSnapshot?
        private var completionGeneration: UInt64 = 0
        private(set) var finiteCompletionDeadlineNanoseconds: UInt64?

        init(imageView: NSImageView?) {
            self.imageView = imageView
        }

        var isActive: Bool { layer != nil }
        var retainedFrameCount: Int { snapshot?.frames.count ?? 0 }
        var layerAttached: Bool {
            guard let layer, let imageView else { return false }
            return layer.superlayer === imageView.layer
        }
        var animationBeginTime: CFTimeInterval? {
            layer?.animation(forKey: "fovea.predecode.contents")?.beginTime
        }
        var animationRepeatCount: Float? {
            layer?.animation(forKey: "fovea.predecode.contents")?.repeatCount
        }
        var layerCurrentTime: CFTimeInterval? {
            layer?.convertTime(CACurrentMediaTime(), from: nil)
        }
        var layerFrame: CGRect? { layer?.frame }

        var presentationFrameIndex: Int? {
            guard let layer, let contents = layer.presentation()?.contents ?? layer.contents else {
                return nil
            }
            let image = contents as! CGImage
            let pointer = Unmanaged.passUnretained(image).toOpaque()
            return snapshot?.frames.firstIndex { frame in
                Unmanaged.passUnretained(frame.cgImage).toOpaque() == pointer
            }
        }

        var supportsGeometry: Bool {
            guard let imageView else { return false }
            return imageView.imageScaling == .scaleProportionallyDown
                && imageView.imageAlignment == .alignCenter
                && imageView.imageFrameStyle == .none
        }

        func attemptUpgrade(
            handle: AnimationPlaybackHandle,
            presentationDriver: any FoveaAppKitAnimationPresentationDriving,
            isEligible: @MainActor () -> Bool,
            finiteCompletion: @escaping @MainActor @Sendable () -> Void
        ) async -> Bool {
            guard isEligible(), !isActive, supportsGeometry else { return false }
            guard let resident = await handle.driver.fullyResidentFramesSnapshotForCompositor(),
                let playbackStart = await handle.driver
                    .systemPlaybackStartNanosecondsForPresentation()
            else { return false }
            try? Task.checkCancellation()
            guard !Task.isCancelled, isEligible(), !isActive, supportsGeometry,
                let imageView, let first = resident.frames.first,
                hasUniformGeometry(resident, first: first)
            else { return false }
            guard resident.timeline.totalDurationNanoseconds > 0 else { return false }

            guard let compositorLayer = attachLayer(to: imageView, first: first) else {
                return false
            }
            layer = compositorLayer
            snapshot = resident
            updateGeometry()
            let animation = makeAnimation(
                snapshot: resident,
                playbackStartNanoseconds: playbackStart,
                layer: compositorLayer
            )
            guard
                configurePlayback(
                    animation,
                    snapshot: resident,
                    playbackStartNanoseconds: playbackStart,
                    layer: compositorLayer,
                    finiteCompletion: finiteCompletion
                )
            else {
                _ = removePresentation(preserveCurrentImage: true)
                return false
            }
            presentationDriver.setPlaybackActive(false)
            return true
        }

        func updateGeometry() {
            guard let imageView, let layer, let first = snapshot?.frames.first else { return }
            let scale = max(
                1,
                imageView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            )
            let intrinsic = NSSize(
                width: CGFloat(first.pixelWidth) / scale,
                height: CGFloat(first.pixelHeight) / scale
            )
            guard intrinsic.width > 0, intrinsic.height > 0 else { return }
            let bounds = imageView.bounds
            let fit = min(1, min(bounds.width / intrinsic.width, bounds.height / intrinsic.height))
            let size = NSSize(width: intrinsic.width * fit, height: intrinsic.height * fit)
            layer.frame = NSRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            layer.contentsScale = scale
        }

        @discardableResult
        func removePresentation(preserveCurrentImage: Bool) -> DecodedImage? {
            completionGeneration &+= 1
            finiteCompletionDeadlineNanoseconds = nil
            guard let layer else {
                snapshot = nil
                return nil
            }
            let preserved = preserveCurrentImage ? preserveCurrentFrame(from: layer) : nil
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
            self.layer = nil
            snapshot = nil
            return preserved
        }

        private func hasUniformGeometry(
            _ snapshot: AnimationPlaybackResidentFramesSnapshot,
            first: DecodedImage
        ) -> Bool {
            snapshot.frames.allSatisfy {
                $0.pixelWidth == first.pixelWidth && $0.pixelHeight == first.pixelHeight
            }
        }

        private func attachLayer(to imageView: NSImageView, first: DecodedImage) -> CALayer? {
            let layer = CALayer()
            layer.contentsGravity = .resize
            layer.zPosition = 1
            layer.actions = ["contents": NSNull()]
            layer.masksToBounds = true
            layer.contents = first.cgImage
            imageView.wantsLayer = true
            guard let hostLayer = imageView.layer else { return nil }
            hostLayer.addSublayer(layer)
            return layer
        }

        private func makeAnimation(
            snapshot: AnimationPlaybackResidentFramesSnapshot,
            playbackStartNanoseconds: UInt64,
            layer: CALayer
        ) -> CAKeyframeAnimation {
            let total = snapshot.timeline.totalDurationNanoseconds
            var elapsed: UInt64 = 0
            var keyTimes: [NSNumber] = []
            keyTimes.reserveCapacity(snapshot.frames.count + 1)
            for duration in snapshot.timeline.frameDurationsNanoseconds {
                keyTimes.append(NSNumber(value: Double(elapsed) / Double(total)))
                elapsed += duration
            }
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.keyTimes = keyTimes + [1.0]
            animation.duration = Double(total) / 1_000_000_000
            animation.calculationMode = .discrete
            animation.isRemovedOnCompletion = false
            animation.beginTime = layer.convertTime(
                Double(playbackStartNanoseconds) / 1_000_000_000,
                from: nil
            )
            return animation
        }

        private func configurePlayback(
            _ animation: CAKeyframeAnimation,
            snapshot: AnimationPlaybackResidentFramesSnapshot,
            playbackStartNanoseconds: UInt64,
            layer: CALayer,
            finiteCompletion: @escaping @MainActor @Sendable () -> Void
        ) -> Bool {
            guard let additionalRepeatCount = snapshot.timeline.additionalRepeatCount else {
                guard let first = snapshot.frames.first else { return false }
                animation.values = snapshot.frames.map(\.cgImage) + [first.cgImage]
                animation.repeatCount = .greatestFiniteMagnitude
                layer.add(animation, forKey: "fovea.predecode.contents")
                return true
            }
            let playCount = UInt64(additionalRepeatCount) + 1
            guard playCount <= 16_777_216, let last = snapshot.frames.last,
                let deadline = finitePlaybackEndNanoseconds(
                    timeline: snapshot.timeline,
                    playbackStartNanoseconds: playbackStartNanoseconds
                )
            else { return false }
            animation.values = snapshot.frames.map(\.cgImage) + [last.cgImage]
            animation.repeatCount = Float(playCount)
            animation.fillMode = .forwards
            layer.add(animation, forKey: "fovea.predecode.contents")
            scheduleFiniteCompletion(deadlineNanoseconds: deadline, completion: finiteCompletion)
            return true
        }

        private func finitePlaybackEndNanoseconds(
            timeline: AnimationPlaybackTimeline,
            playbackStartNanoseconds: UInt64
        ) -> UInt64? {
            guard let additionalRepeatCount = timeline.additionalRepeatCount else { return nil }
            let playCount = UInt64(additionalRepeatCount) + 1
            let finiteDuration = timeline.totalDurationNanoseconds.multipliedReportingOverflow(
                by: playCount)
            guard !finiteDuration.overflow else { return nil }
            let deadline = playbackStartNanoseconds.addingReportingOverflow(
                finiteDuration.partialValue)
            return deadline.overflow ? nil : deadline.partialValue
        }

        private func scheduleFiniteCompletion(
            deadlineNanoseconds: UInt64,
            completion: @escaping @MainActor @Sendable () -> Void
        ) {
            completionGeneration &+= 1
            let generation = completionGeneration
            finiteCompletionDeadlineNanoseconds = deadlineNanoseconds
            DispatchQueue.main.asyncAfter(
                deadline: DispatchTime(uptimeNanoseconds: deadlineNanoseconds)
            ) {
                guard self.isActive,
                    self.completionGeneration == generation,
                    self.finiteCompletionDeadlineNanoseconds == deadlineNanoseconds
                else { return }
                completion()
            }
        }

        private func preserveCurrentFrame(from layer: CALayer) -> DecodedImage? {
            guard let imageView, let contents = layer.presentation()?.contents ?? layer.contents
            else {
                return nil
            }
            let image = contents as! CGImage
            let pointer = Unmanaged.passUnretained(image).toOpaque()
            let resident = snapshot?.frames.first {
                Unmanaged.passUnretained($0.cgImage).toOpaque() == pointer
            }
            let scale = max(
                1,
                imageView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            )
            imageView.image = NSImage(
                cgImage: image,
                size: NSSize(
                    width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            )
            return resident
        }
    }

    /// Uses AppKit's view-bound display link when the platform can track the view's current screen.
    ///
    /// macOS 14 introduced `NSView.displayLink(target:selector:)`. It follows the view across displays and
    /// suppresses callbacks while the view is hidden or detached, so Fovea can use the same target-timestamp
    /// scheduling contract as UIKit without adopting the deprecated worker-thread `CVDisplayLink` API.
    @available(macOS 14.0, *)
    @MainActor
    package final class FoveaAnimationDisplayLinkDriver: FoveaAppKitAnimationPresentationDriving {
        @MainActor
        private final class Proxy: NSObject {
            weak var owner: FoveaAnimationDisplayLinkDriver?

            @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
                owner?.receive(displayLink)
            }
        }

        private weak var view: NSView?
        private let driver: AnimationPlaybackDriver
        private let drivesPlayback: Bool
        private let coalescesUnchangedSourceFrames: Bool
        private let requestedPreferredFramesPerSecond: Int?
        private let refreshFrameProvider: FoveaAppKitAnimationRefreshFrameProvider?
        private let refreshSampleHandler: FoveaAppKitAnimationRefreshSampleHandler?
        private let proxy = Proxy()
        private var displayLink: CADisplayLink?
        private var drainTask: Task<Void, Never>?
        private var nextCoreTickNanoseconds: UInt64?
        private var targetBuffer = AnimationPresentationTargetBuffer()
        private var isPlaybackActive = false
        private var isTerminal = false

        package init(
            view: NSView,
            driver: AnimationPlaybackDriver,
            drivesPlayback: Bool = true,
            coalescesUnchangedSourceFrames: Bool = true,
            requestedPreferredFramesPerSecond: Int? = nil,
            refreshFrameProvider: FoveaAppKitAnimationRefreshFrameProvider? = nil,
            refreshSampleHandler: FoveaAppKitAnimationRefreshSampleHandler? = nil
        ) {
            self.view = view
            self.driver = driver
            self.drivesPlayback = drivesPlayback
            self.coalescesUnchangedSourceFrames = coalescesUnchangedSourceFrames
            self.requestedPreferredFramesPerSecond = requestedPreferredFramesPerSecond
            self.refreshFrameProvider = refreshFrameProvider
            self.refreshSampleHandler = refreshSampleHandler
            proxy.owner = self
        }

        isolated deinit {
            displayLink?.invalidate()
            drainTask?.cancel()
        }

        package func start() {
            guard displayLink == nil, !isTerminal, let view else { return }
            let link = view.displayLink(
                target: proxy,
                selector: #selector(Proxy.displayLinkDidFire(_:))
            )
            if let requestedPreferredFramesPerSecond {
                let fps = Float(requestedPreferredFramesPerSecond)
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: fps,
                    maximum: fps,
                    preferred: fps
                )
            }
            link.isPaused = !isPlaybackActive
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        package func setPlaybackActive(_ active: Bool) {
            guard !isTerminal else { return }
            isPlaybackActive = active
            if !active {
                targetBuffer.clearPending()
                nextCoreTickNanoseconds = nil
                drainTask?.cancel()
                drainTask = nil
            }
            displayLink?.isPaused = !active
        }

        package func invalidate() {
            guard !isTerminal else { return }
            isTerminal = true
            targetBuffer.clearPending()
            nextCoreTickNanoseconds = nil
            drainTask?.cancel()
            drainTask = nil
            displayLink?.invalidate()
            displayLink = nil
        }

        package var isPausedForTesting: Bool {
            displayLink?.isPaused ?? true
        }

        package var drivesPlaybackForTesting: Bool { drivesPlayback }

        package var presentationDiagnostics: FoveaAppKitAnimationPresentationDiagnosticsSnapshot {
            let snapshot = targetBuffer.snapshot
            return FoveaAppKitAnimationPresentationDiagnosticsSnapshot(
                acceptedTargetCount: snapshot.acceptedTargetCount,
                consumedTargetCount: snapshot.consumedTargetCount,
                supersededPendingTargetCount: snapshot.supersededPendingTargetCount,
                rejectedNonmonotonicTargetCount: snapshot.rejectedNonmonotonicTargetCount,
                lifecycleClearedPendingTargetCount: snapshot.lifecycleClearedPendingTargetCount,
                hasPendingTarget: snapshot.hasPending,
                lastAcceptedTargetNanoseconds: snapshot.lastAcceptedTarget,
                isDisplayLinkPaused: isPausedForTesting,
                effectiveVisibility: nil
            )
        }

        package static func nanoseconds(
            fromPresentationTimestamp timestamp: TimeInterval
        ) -> UInt64? {
            guard timestamp.isFinite, timestamp >= 0 else { return nil }
            let nanoseconds = timestamp * 1_000_000_000
            let rounded = nanoseconds.rounded(.toNearestOrEven)
            guard rounded.isFinite,
                rounded < 18_446_744_073_709_551_616.0
            else { return nil }
            return UInt64(rounded)
        }

        private func receive(_ displayLink: CADisplayLink) {
            guard !isTerminal, !displayLink.isPaused else { return }
            if let refreshFrameProvider,
                let refreshSampleHandler,
                let frameIndex = refreshFrameProvider(),
                let refreshNanoseconds = Self.nanoseconds(
                    fromPresentationTimestamp: displayLink.timestamp
                )
            {
                refreshSampleHandler(frameIndex, refreshNanoseconds)
            }
            guard drivesPlayback else { return }
            let target =
                displayLink.targetTimestamp > 0
                ? displayLink.targetTimestamp
                : displayLink.timestamp
            guard
                let targetNanoseconds = Self.nanoseconds(
                    fromPresentationTimestamp: target
                )
            else { return }
            guard targetBuffer.offer(targetNanoseconds) else { return }
            if coalescesUnchangedSourceFrames,
                let nextCoreTickNanoseconds,
                targetNanoseconds < nextCoreTickNanoseconds,
                drainTask == nil
            {
                return
            }
            startDrainIfNeeded()
        }

        private func startDrainIfNeeded() {
            guard drainTask == nil, targetBuffer.hasPending, !isTerminal else { return }
            drainTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled, let target = self.targetBuffer.takeNewest() {
                    let disposition: AnimationPlaybackTickDisposition
                    if self.coalescesUnchangedSourceFrames {
                        let tick = await self.driver.tickCoalescingUnchangedSourceFrames(
                            atPresentationNanoseconds: target
                        )
                        self.nextCoreTickNanoseconds = tick.nextTransitionNanoseconds
                        disposition = tick.disposition
                    } else {
                        self.nextCoreTickNanoseconds = nil
                        disposition = await self.driver.tick(
                            atPresentationNanoseconds: target
                        )
                    }
                    switch disposition {
                    case .advanced, .paused, .dormant:
                        continue
                    case .finished, .terminal, .unavailable:
                        self.invalidate()
                        return
                    }
                }
                self.drainTask = nil
                if self.targetBuffer.hasPending { self.startDrainIfNeeded() }
            }
        }
    }
#endif
