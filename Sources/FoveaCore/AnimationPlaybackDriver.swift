import AkashicMemory
import Dispatch
import Foundation

/// 为动画调度提供可替换的单调时钟与绝对 deadline sleep。
package protocol AnimationPlaybackClock: Sendable {
    func nowNanoseconds() async -> UInt64
    func sleep(untilNanoseconds deadline: UInt64) async throws
}

/// 基于系统 uptime 的生产单调时钟；系统时间或时区变化不会改变播放位置。
package struct SystemAnimationPlaybackClock: AnimationPlaybackClock {
    package init() {}

    package func nowNanoseconds() async -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    package func sleep(untilNanoseconds deadline: UInt64) async throws {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else {
            try Task.checkCancellation()
            return
        }
        try await Task<Never, Never>.sleep(nanoseconds: deadline - now)
    }
}

package enum AnimationPlaybackSchedulingMode: Equatable, Sendable {
    case automaticDeadlineLoop
    case externalPresentationTicks
}

package enum AnimationPlaybackTickDisposition: Equatable, Sendable {
    case advanced
    case paused
    case dormant
    case finished
    case unavailable
    case terminal
}

package struct AnimationPlaybackExternalTickResult: Equatable, Sendable {
    package let disposition: AnimationPlaybackTickDisposition
    package let nextTransitionNanoseconds: UInt64?
}

package enum AnimationPlaybackDriverError: Error, Equatable, Sendable {
    case alreadyStarted
    case cancelled
    case deadlineOverflow
}

/// 拥有一个播放协调器的 deadline 驱动循环。
///
/// 每次 tick 的下一 deadline 以“本次采样时刻 + 当前帧剩余时间”计算。解码或 UI 回调耗时
/// 会侵蚀剩余预算；若已经越过 deadline，时钟立即返回并由 cursor 在下一次采样直接丢帧，
/// 避免相对 sleep 造成累计漂移。生命周期变化取消旧循环并推进协调器发布代际。
package actor AnimationPlaybackDriver {
    private enum AutomaticLoopStep {
        case stop
        case sleep(untilNanoseconds: UInt64)
    }

    package typealias OutputHandler = @Sendable (AnimationPlaybackOutput) async -> Void
    package typealias FailureHandler = @Sendable (any Error) async -> Void
    package typealias ExternalPresentationStateHandler = @Sendable (Bool) async -> Void
    package typealias ExternalPresentationInvalidationHandler = @Sendable (Bool) async -> Void
    package typealias ExternalPresentationRevalidationHandler = @Sendable (Bool) async -> Void

    private let coordinator: AnimationPlaybackCoordinator
    private let clock: any AnimationPlaybackClock
    private var outputHandler: OutputHandler?
    private var failureHandler: FailureHandler?
    private var externalPresentationStateHandler: ExternalPresentationStateHandler?
    private var externalPresentationInvalidationHandler: ExternalPresentationInvalidationHandler?
    private var externalPresentationRevalidationHandler: ExternalPresentationRevalidationHandler?
    private var lastReportedExternalPresentationActive: Bool?
    private var lastExternalPresentationNanoseconds: UInt64?
    private var nextExternalTransitionNanoseconds: UInt64?
    private var playbackStartNanoseconds: UInt64?
    private var loopTask: Task<Void, Never>?
    private var loopGeneration: UInt64 = 0
    private var schedulingMode: AnimationPlaybackSchedulingMode = .automaticDeadlineLoop
    private var hasStarted = false
    private var isCancelled = false
    private var hasFinished = false
    private var isSchedulingDormant = false
    private var isVisible = true
    private var isApplicationActive = true
    private var isExplicitlyPaused = false
    private var memoryPressure: AnimationMemoryPressureLevel = .normal

    package init(
        coordinator: AnimationPlaybackCoordinator,
        clock: any AnimationPlaybackClock = SystemAnimationPlaybackClock()
    ) {
        self.coordinator = coordinator
        self.clock = clock
    }

    deinit {
        loopTask?.cancel()
    }

    package func start(
        output: @escaping OutputHandler,
        failure: @escaping FailureHandler = { _ in },
        initiallyVisible: Bool = true,
        initiallyApplicationActive: Bool = true,
        initialMemoryPressure: AnimationMemoryPressureLevel = .normal,
        schedulingMode: AnimationPlaybackSchedulingMode = .automaticDeadlineLoop,
        externalPresentationState: ExternalPresentationStateHandler? = nil,
        externalPresentationInvalidation: ExternalPresentationInvalidationHandler? = nil,
        externalPresentationRevalidation: ExternalPresentationRevalidationHandler? = nil
    ) async throws {
        guard !isCancelled else { throw AnimationPlaybackDriverError.cancelled }
        guard !hasStarted else { throw AnimationPlaybackDriverError.alreadyStarted }
        outputHandler = output
        failureHandler = failure
        self.schedulingMode = schedulingMode
        externalPresentationStateHandler = externalPresentationState
        externalPresentationInvalidationHandler = externalPresentationInvalidation
        externalPresentationRevalidationHandler = externalPresentationRevalidation
        lastReportedExternalPresentationActive = nil
        lastExternalPresentationNanoseconds = nil
        nextExternalTransitionNanoseconds = nil
        isVisible = initiallyVisible
        isApplicationActive = initiallyApplicationActive
        memoryPressure = initialMemoryPressure
        isExplicitlyPaused = false
        hasFinished = false
        isSchedulingDormant = false
        let now = await clock.nowNanoseconds()
        playbackStartNanoseconds = now
        do {
            try await coordinator.start(at: now)
            if !initiallyVisible {
                try await coordinator.setVisible(false, at: now)
            }
            if !initiallyApplicationActive {
                try await coordinator.setApplicationActive(false, at: now)
            }
            if initialMemoryPressure != .normal {
                _ = try await coordinator.applyMemoryPressure(
                    initialMemoryPressure,
                    at: now
                )
            }
            hasStarted = true
            if schedulingMode == .externalPresentationTicks {
                if shouldAdvance { _ = await tick(atPresentationNanoseconds: now) }
                if isCancelled { throw AnimationPlaybackDriverError.cancelled }
                await reportExternalPresentationStateIfNeeded()
            } else {
                restartLoopIfNeeded()
            }
        } catch {
            outputHandler = nil
            failureHandler = nil
            externalPresentationStateHandler = nil
            externalPresentationInvalidationHandler = nil
            externalPresentationRevalidationHandler = nil
            lastReportedExternalPresentationActive = nil
            playbackStartNanoseconds = nil
            throw error
        }
    }

    package func setVisible(_ visible: Bool) async throws {
        try requireActive()
        invalidateLoop()
        let now = await lifecycleTimestampNanoseconds()
        try await coordinator.setVisible(visible, at: now)
        nextExternalTransitionNanoseconds = nil
        isVisible = visible
        if visible { isSchedulingDormant = false }
        restartLoopIfNeeded()
        await reportExternalPresentationStateIfNeeded()
    }

    package func setApplicationActive(_ active: Bool) async throws {
        try requireActive()
        invalidateLoop()
        let now = await lifecycleTimestampNanoseconds()
        try await coordinator.setApplicationActive(active, at: now)
        nextExternalTransitionNanoseconds = nil
        isApplicationActive = active
        if active { isSchedulingDormant = false }
        restartLoopIfNeeded()
        await reportExternalPresentationStateIfNeeded()
    }

    package func setExplicitlyPaused(_ paused: Bool) async throws {
        try requireActive()
        invalidateLoop()
        let now = await lifecycleTimestampNanoseconds()
        try await coordinator.setExplicitlyPaused(paused, at: now)
        nextExternalTransitionNanoseconds = nil
        isExplicitlyPaused = paused
        if !paused { isSchedulingDormant = false }
        restartLoopIfNeeded()
        await reportExternalPresentationStateIfNeeded()
    }

    package func seek(toFrame index: Int) async throws {
        try requireActive()
        invalidateLoop()
        let now = await lifecycleTimestampNanoseconds()
        try await coordinator.seek(toFrame: index, at: now)
        nextExternalTransitionNanoseconds = nil
        hasFinished = false
        isSchedulingDormant = false
        await invalidateExternalPresentationIfNeeded()
        await revalidateExternalPresentationIfStateIsUnchanged()
        restartLoopIfNeeded()
        await reportExternalPresentationStateIfNeeded()
    }

    package func restart() async throws {
        try requireActive()
        invalidateLoop()
        let now = await lifecycleTimestampNanoseconds()
        try await coordinator.restart(at: now)
        nextExternalTransitionNanoseconds = nil
        hasFinished = false
        isSchedulingDormant = false
        await invalidateExternalPresentationIfNeeded()
        await revalidateExternalPresentationIfStateIsUnchanged()
        restartLoopIfNeeded()
        await reportExternalPresentationStateIfNeeded()
    }

    @discardableResult
    package func applyMemoryPressure(
        _ level: AnimationMemoryPressureLevel
    ) async throws -> MemoryCacheRemovalSummary {
        try requireActive()
        invalidateLoop()
        if level != .normal {
            await invalidateExternalPresentationIfNeeded(
                activeOverride: shouldSchedule(under: level)
            )
        }
        let now = await lifecycleTimestampNanoseconds()
        let summary = try await coordinator.applyMemoryPressure(level, at: now)
        nextExternalTransitionNanoseconds = nil
        memoryPressure = level
        if level != .critical { isSchedulingDormant = false }
        await revalidateExternalPresentationIfStateIsUnchanged()
        restartLoopIfNeeded()
        await reportExternalPresentationStateIfNeeded()
        return summary
    }

    package func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        invalidateLoop()
        await reportExternalPresentationStateIfNeeded()
        outputHandler = nil
        failureHandler = nil
        externalPresentationStateHandler = nil
        externalPresentationInvalidationHandler = nil
        externalPresentationRevalidationHandler = nil
        nextExternalTransitionNanoseconds = nil
        await coordinator.cancel()
    }

    package func tick(
        atPresentationNanoseconds monotonicNanoseconds: UInt64
    ) async -> AnimationPlaybackTickDisposition {
        await tick(
            atPresentationNanoseconds: monotonicNanoseconds,
            coalescingUnchangedSourceFrames: false
        )
    }

    package func tickCoalescingUnchangedSourceFrames(
        atPresentationNanoseconds monotonicNanoseconds: UInt64
    ) async -> AnimationPlaybackExternalTickResult {
        let disposition = await tick(
            atPresentationNanoseconds: monotonicNanoseconds,
            coalescingUnchangedSourceFrames: true
        )
        return AnimationPlaybackExternalTickResult(
            disposition: disposition,
            nextTransitionNanoseconds: nextExternalTransitionNanoseconds
        )
    }

    private func tick(
        atPresentationNanoseconds monotonicNanoseconds: UInt64,
        coalescingUnchangedSourceFrames: Bool
    ) async -> AnimationPlaybackTickDisposition {
        if let disposition = externalTickPreflightDisposition() { return disposition }
        recordExternalPresentationTimestamp(monotonicNanoseconds)
        do {
            if shouldCoalesceExternalTick(
                atPresentationNanoseconds: monotonicNanoseconds,
                coalescingUnchangedSourceFrames: coalescingUnchangedSourceFrames
            ) {
                return .advanced
            }
            let playbackOutput = try await coordinator.advance(at: monotonicNanoseconds)
            try Task.checkCancellation()
            guard !isCancelled else { return .unavailable }
            updateExternalTransition(
                from: playbackOutput,
                atPresentationNanoseconds: monotonicNanoseconds
            )
            if let outputHandler { await outputHandler(playbackOutput) }
            return await dispositionAfterExternalPlaybackOutput(playbackOutput)
        } catch is CancellationError {
            return pausedExternalTickDisposition()
        } catch AnimationPlaybackCoordinatorError.publicationRevoked {
            return pausedExternalTickDisposition()
        } catch {
            return await terminalExternalTickDisposition(error)
        }
    }

    private func externalTickPreflightDisposition() -> AnimationPlaybackTickDisposition? {
        guard hasStarted, !isCancelled else { return .unavailable }
        guard schedulingMode == .externalPresentationTicks else { return .unavailable }
        guard !hasFinished else { return .finished }
        guard shouldAdvance else { return .paused }
        guard !isSchedulingDormant else { return .dormant }
        return nil
    }

    private func recordExternalPresentationTimestamp(_ monotonicNanoseconds: UInt64) {
        if let lastExternalPresentationNanoseconds {
            self.lastExternalPresentationNanoseconds = max(
                lastExternalPresentationNanoseconds,
                monotonicNanoseconds
            )
        } else {
            lastExternalPresentationNanoseconds = monotonicNanoseconds
        }
    }

    private func shouldCoalesceExternalTick(
        atPresentationNanoseconds monotonicNanoseconds: UInt64,
        coalescingUnchangedSourceFrames: Bool
    ) -> Bool {
        guard coalescingUnchangedSourceFrames,
            let nextExternalTransitionNanoseconds
        else { return false }
        return monotonicNanoseconds < nextExternalTransitionNanoseconds
    }

    private func updateExternalTransition(
        from playbackOutput: AnimationPlaybackOutput,
        atPresentationNanoseconds monotonicNanoseconds: UInt64
    ) {
        guard let remaining = playbackOutput.decision.nanosecondsUntilNextFrame else {
            nextExternalTransitionNanoseconds = nil
            return
        }
        let boundary = monotonicNanoseconds.addingReportingOverflow(remaining)
        nextExternalTransitionNanoseconds = boundary.overflow ? nil : boundary.partialValue
    }

    private func dispositionAfterExternalPlaybackOutput(
        _ playbackOutput: AnimationPlaybackOutput
    ) async -> AnimationPlaybackTickDisposition {
        if playbackOutput.decision.isFinished {
            hasFinished = true
            isSchedulingDormant = true
            await reportExternalPresentationStateIfNeeded()
            return .finished
        }
        if playbackOutput.decision.nanosecondsUntilNextFrame == nil {
            isSchedulingDormant = true
            await reportExternalPresentationStateIfNeeded()
            return .dormant
        }
        return .advanced
    }

    private func pausedExternalTickDisposition() -> AnimationPlaybackTickDisposition {
        nextExternalTransitionNanoseconds = nil
        return .paused
    }

    private func terminalExternalTickDisposition(
        _ error: any Error
    ) async -> AnimationPlaybackTickDisposition {
        hasFinished = true
        isSchedulingDormant = true
        if let failureHandler { await failureHandler(error) }
        await reportExternalPresentationStateIfNeeded()
        return .terminal
    }

    package func isRunningForTesting() -> Bool {
        loopTask != nil && !(loopTask?.isCancelled ?? true)
    }

    package func schedulingModeForTesting() -> AnimationPlaybackSchedulingMode {
        schedulingMode
    }

    /// Returns the already-resident whole-track pixels without triggering provider work.
    /// Platform presenters may use this only as an optional presentation optimization.
    package func fullyResidentFramesSnapshotForCompositor() async
        -> AnimationPlaybackResidentFramesSnapshot?
    {
        guard hasStarted, !isCancelled, !hasFinished else { return nil }
        return await coordinator.fullyResidentFramesSnapshotForCompositor()
    }

    /// Returns an effective playback anchor in the production uptime clock used by Core Animation.
    /// The anchor is shifted across pauses/seeks so Core Animation never catches up paused wall time.
    package func systemPlaybackStartNanosecondsForPresentation() async -> UInt64? {
        guard clock is SystemAnimationPlaybackClock, hasStarted, !isCancelled, !hasFinished else {
            return nil
        }
        let now = await lifecycleTimestampNanoseconds()
        return await coordinator.effectivePlaybackStartNanosecondsForPresentation(at: now)
    }

    package func playbackStartNanosecondsForTesting() -> UInt64? {
        playbackStartNanoseconds
    }

    private func lifecycleTimestampNanoseconds() async -> UInt64 {
        let now = await clock.nowNanoseconds()
        guard schedulingMode == .externalPresentationTicks,
            let lastExternalPresentationNanoseconds
        else { return now }
        return max(now, lastExternalPresentationNanoseconds)
    }

    private var shouldAdvance: Bool {
        isVisible
            && isApplicationActive
            && !isExplicitlyPaused
            && memoryPressure != .critical
    }

    private var shouldSchedule: Bool {
        shouldSchedule(under: memoryPressure)
    }

    private func shouldSchedule(under pressure: AnimationMemoryPressureLevel) -> Bool {
        !hasFinished
            && !isSchedulingDormant
            && isVisible
            && isApplicationActive
            && !isExplicitlyPaused
            && pressure != .critical
    }

    private func invalidateExternalPresentationIfNeeded(
        activeOverride: Bool? = nil
    ) async {
        guard schedulingMode == .externalPresentationTicks,
            let externalPresentationInvalidationHandler
        else { return }
        let active = activeOverride ?? (hasStarted && !isCancelled && shouldSchedule)
        await externalPresentationInvalidationHandler(active)
    }

    private func revalidateExternalPresentationIfStateIsUnchanged() async {
        guard schedulingMode == .externalPresentationTicks,
            let externalPresentationRevalidationHandler
        else { return }
        let active = hasStarted && !isCancelled && shouldSchedule
        guard lastReportedExternalPresentationActive == active else { return }
        await externalPresentationRevalidationHandler(active)
    }

    private func reportExternalPresentationStateIfNeeded() async {
        guard schedulingMode == .externalPresentationTicks,
            let externalPresentationStateHandler
        else { return }
        let active = hasStarted && !isCancelled && shouldSchedule
        guard lastReportedExternalPresentationActive != active else { return }
        lastReportedExternalPresentationActive = active
        await externalPresentationStateHandler(active)
    }

    private func requireActive() throws {
        guard !isCancelled else { throw AnimationPlaybackDriverError.cancelled }
        guard hasStarted else { throw AnimationPlaybackCursorError.notStarted }
    }

    private func restartLoopIfNeeded() {
        guard schedulingMode == .automaticDeadlineLoop,
            hasStarted,
            !isCancelled,
            shouldSchedule
        else { return }
        invalidateLoop()
        let generation = loopGeneration
        loopTask = Task { [weak self] in
            await self?.runLoop(generation: generation)
        }
    }

    private func invalidateLoop() {
        loopTask?.cancel()
        loopTask = nil
        loopGeneration = loopGeneration == .max ? 0 : loopGeneration + 1
    }

    private func runLoop(generation: UInt64) async {
        while !Task.isCancelled {
            guard generation == loopGeneration, !isCancelled else { return }
            do {
                switch try await nextAutomaticLoopStep(generation: generation) {
                case .stop:
                    return
                case let .sleep(deadline):
                    try await clock.sleep(untilNanoseconds: deadline)
                }
            } catch is CancellationError {
                return
            } catch AnimationPlaybackCoordinatorError.publicationRevoked {
                return
            } catch {
                await finishAutomaticLoopAfterFailure(error, generation: generation)
                return
            }
        }
    }

    private func nextAutomaticLoopStep(
        generation: UInt64
    ) async throws -> AutomaticLoopStep {
        let sampledAt = await clock.nowNanoseconds()
        let playbackOutput = try await coordinator.advance(at: sampledAt)
        guard generation == loopGeneration, !Task.isCancelled, !isCancelled else {
            return .stop
        }
        if let outputHandler { await outputHandler(playbackOutput) }
        if playbackOutput.decision.isFinished {
            finishLoopIfCurrent(generation, finished: true, dormant: true)
            return .stop
        }
        guard let remaining = playbackOutput.decision.nanosecondsUntilNextFrame else {
            finishLoopIfCurrent(generation, dormant: true)
            return .stop
        }
        let deadline = sampledAt.addingReportingOverflow(remaining)
        guard !deadline.overflow else {
            throw AnimationPlaybackDriverError.deadlineOverflow
        }
        return .sleep(untilNanoseconds: deadline.partialValue)
    }

    private func finishAutomaticLoopAfterFailure(
        _ error: any Error,
        generation: UInt64
    ) async {
        guard generation == loopGeneration, !isCancelled else { return }
        if let failureHandler { await failureHandler(error) }
        finishLoopIfCurrent(generation, finished: true, dormant: true)
    }

    private func finishLoopIfCurrent(
        _ generation: UInt64,
        finished: Bool = false,
        dormant: Bool = false
    ) {
        guard generation == loopGeneration else { return }
        loopTask = nil
        if finished { hasFinished = true }
        if dormant { isSchedulingDormant = true }
    }
}
