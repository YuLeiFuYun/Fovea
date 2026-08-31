#if canImport(UIKit)
    import FoveaCore
    import UIKit

    package enum FoveaAnimationDisplayCadenceMode: Sendable {
        case maximumRefresh
        case timelineAlignedExperiment
    }

    /// Converts UIKit display refresh callbacks into newest-only Fovea presentation ticks.
    ///
    /// `CADisplayLink` can continue firing while decoding or publication is suspended. The adapter retains
    /// only the newest target timestamp, so a slow frame provider cannot create an unbounded callback queue.
    @MainActor
    package final class FoveaAnimationDisplayLinkDriver {
        @MainActor
        private final class Proxy: NSObject {
            weak var owner: FoveaAnimationDisplayLinkDriver?

            @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
                owner?.receive(displayLink)
            }
        }

        private let driver: AnimationPlaybackDriver
        private let requestedPreferredFramesPerSecond: Int?
        private let proxy = Proxy()
        private var displayLink: CADisplayLink?
        private var drainTask: Task<Void, Never>?
        private var targetBuffer = AnimationPresentationTargetBuffer()
        private var isPlaybackActive = false
        private var isTerminal = false

        package init(
            driver: AnimationPlaybackDriver,
            requestedPreferredFramesPerSecond: Int? = nil
        ) {
            self.driver = driver
            self.requestedPreferredFramesPerSecond = requestedPreferredFramesPerSecond
            proxy.owner = self
        }

        isolated deinit {
            displayLink?.invalidate()
            drainTask?.cancel()
        }

        package func start() {
            guard displayLink == nil, !isTerminal else { return }
            let link = CADisplayLink(
                target: proxy,
                selector: #selector(Proxy.displayLinkDidFire(_:))
            )
            link.isPaused = !isPlaybackActive
            if let requestedPreferredFramesPerSecond {
                link.preferredFramesPerSecond = requestedPreferredFramesPerSecond
            }
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        package func setPlaybackActive(_ active: Bool) {
            guard !isTerminal else { return }
            isPlaybackActive = active
            if !active {
                targetBuffer.clearPending()
                drainTask?.cancel()
                drainTask = nil
            }
            displayLink?.isPaused = !active
        }

        package func invalidate() {
            isTerminal = true
            targetBuffer.clearPending()
            drainTask?.cancel()
            drainTask = nil
            displayLink?.invalidate()
            displayLink = nil
        }

        package var isPausedForTesting: Bool {
            displayLink?.isPaused ?? true
        }

        package var presentationDiagnostics: FoveaAnimationPresentationDiagnosticsSnapshot {
            let snapshot = targetBuffer.snapshot
            return FoveaAnimationPresentationDiagnosticsSnapshot(
                acceptedTargetCount: snapshot.acceptedTargetCount,
                consumedTargetCount: snapshot.consumedTargetCount,
                supersededPendingTargetCount: snapshot.supersededPendingTargetCount,
                rejectedNonmonotonicTargetCount: snapshot.rejectedNonmonotonicTargetCount,
                lifecycleClearedPendingTargetCount: snapshot.lifecycleClearedPendingTargetCount,
                hasPendingTarget: snapshot.hasPending,
                lastAcceptedTargetNanoseconds: snapshot.lastAcceptedTarget,
                isDisplayLinkPaused: isPausedForTesting,
                requestedPreferredFramesPerSecond: requestedPreferredFramesPerSecond,
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
            startDrainIfNeeded()
        }

        private func startDrainIfNeeded() {
            guard drainTask == nil, targetBuffer.hasPending, !isTerminal else { return }
            drainTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled, let target = self.targetBuffer.takeNewest() {
                    let disposition = await self.driver.tick(
                        atPresentationNanoseconds: target
                    )
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
