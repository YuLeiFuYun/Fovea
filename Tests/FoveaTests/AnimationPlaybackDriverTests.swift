import CoreGraphics
import Foundation
import FoveaCore
import ImageCraftCore
import XCTest

final class AnimationPlaybackDriverTests: XCTestCase {
    func testReduceMotionPolicyResolvesWithoutBroadeningRequestedMode_W5_PT_040() {
        XCTAssertEqual(
            AnimationPlaybackPolicy(
                requestedMode: .normal,
                reduceMotionBehavior: .firstFrame
            ).resolvedMode(reduceMotionEnabled: true),
            .firstFrame
        )
        XCTAssertEqual(
            AnimationPlaybackPolicy(
                requestedMode: .normal,
                reduceMotionBehavior: .playOnce
            ).resolvedMode(reduceMotionEnabled: true),
            .playOnce
        )
        XCTAssertEqual(
            AnimationPlaybackPolicy(
                requestedMode: .firstFrame,
                reduceMotionBehavior: .playOnce
            ).resolvedMode(reduceMotionEnabled: true),
            .firstFrame
        )
        XCTAssertEqual(
            AnimationPlaybackPolicy(
                requestedMode: .playOnce,
                reduceMotionBehavior: .preserveRequestedMode
            ).resolvedMode(reduceMotionEnabled: true),
            .playOnce
        )
        XCTAssertEqual(
            AnimationPlaybackPolicy(requestedMode: .normal)
                .resolvedMode(reduceMotionEnabled: false),
            .normal
        )
    }

    func testDriverUsesAbsoluteDeadlinesAndCompletesFinitePlayback_W5_PT_041() async throws {
        let clock = ControllableAnimationClock(now: 0, automaticallyAdvances: true)
        let recorder = AnimationDriverRecorder()
        let fixture = try makeFixture(clock: clock, mode: .playOnce, frameCount: 3)

        try await fixture.driver.start { output in
            await recorder.record(output)
        } failure: { error in
            await recorder.recordFailure(error)
        }
        try await waitUntil("finite animation driver outputs final frame") {
            await recorder.outputCount() == 4
        }

        let outputs = await recorder.outputs()
        XCTAssertEqual(outputs.map(\.frameIndex), [0, 1, 2, 2])
        XCTAssertEqual(outputs.map(\.isFinished), [false, false, false, true])
        let deadlines = await clock.recordedDeadlines()
        let failures = await recorder.failures()
        let isRunning = await fixture.driver.isRunningForTesting()
        XCTAssertEqual(deadlines, [10, 20, 30])
        XCTAssertTrue(failures.isEmpty)
        XCTAssertFalse(isRunning)
        await fixture.driver.cancel()
    }

    func testSlowOutputCallbackConsumesBudgetAndDropsInsteadOfDrifting_W5_PT_042() async throws {
        let clock = ControllableAnimationClock(now: 0, automaticallyAdvances: true)
        let recorder = AnimationDriverRecorder()
        let fixture = try makeFixture(clock: clock, mode: .playOnce, frameCount: 3)

        try await fixture.driver.start { output in
            let ordinal = await recorder.record(output)
            if ordinal == 1 { await clock.advance(by: 25) }
        } failure: { error in
            await recorder.recordFailure(error)
        }
        try await waitUntil("late callback animation finishes") {
            await recorder.outputs().last?.isFinished == true
        }

        let outputs = await recorder.outputs()
        XCTAssertEqual(outputs.map(\.frameIndex), [0, 2, 2])
        XCTAssertEqual(outputs[1].droppedFrameCount, 1)
        let deadlines = await clock.recordedDeadlines()
        let failures = await recorder.failures()
        XCTAssertEqual(deadlines, [10, 30])
        XCTAssertTrue(failures.isEmpty)
        await fixture.driver.cancel()
    }

    func testOffscreenFreezesClockAndResumeDoesNotCatchUp_W5_PT_043() async throws {
        let clock = ControllableAnimationClock(now: 0, automaticallyAdvances: false)
        let recorder = AnimationDriverRecorder()
        let fixture = try makeFixture(clock: clock, mode: .normal, frameCount: 3)

        try await fixture.driver.start { output in
            await recorder.record(output)
        }
        try await waitUntil("initial animation output") {
            let outputCount = await recorder.outputCount()
            let pendingSleepCount = await clock.pendingSleepCount()
            return outputCount == 1 && pendingSleepCount == 1
        }
        try await fixture.driver.setVisible(false)
        try await waitUntil("offscreen cancels pending deadline") {
            await clock.pendingSleepCount() == 0
        }

        await clock.advance(to: 100)
        try await fixture.driver.setVisible(true)
        try await waitUntil("visible resume publishes frozen frame") {
            await recorder.outputCount() == 2
        }
        var outputs = await recorder.outputs()
        XCTAssertEqual(outputs.map(\.frameIndex), [0, 0])

        await clock.advance(to: 110)
        try await waitUntil("visible playback advances after active duration") {
            await recorder.outputCount() == 3
        }
        outputs = await recorder.outputs()
        XCTAssertEqual(outputs.map(\.frameIndex), [0, 0, 1])
        XCTAssertEqual(outputs.last?.droppedFrameCount, 0)
        await fixture.driver.cancel()
    }

    func testDriverCancelInterruptsSleepAndCancelsProviderOnce_W5_PT_044() async throws {
        let clock = ControllableAnimationClock(now: 0, automaticallyAdvances: false)
        let recorder = AnimationDriverRecorder()
        let fixture = try makeFixture(clock: clock, mode: .normal, frameCount: 2)

        try await fixture.driver.start { output in
            await recorder.record(output)
        }
        try await waitUntil("animation driver enters sleep") {
            await clock.pendingSleepCount() == 1
        }
        await fixture.driver.cancel()
        await fixture.driver.cancel()
        try await waitUntil("cancelled animation sleep drains") {
            await clock.pendingSleepCount() == 0
        }

        let cancelCount = await fixture.provider.cancelCount()
        let isRunning = await fixture.driver.isRunningForTesting()
        let failures = await recorder.failures()
        XCTAssertEqual(cancelCount, 1)
        XCTAssertFalse(isRunning)
        XCTAssertTrue(failures.isEmpty)
        do {
            try await fixture.driver.setVisible(true)
            XCTFail("Cancelled driver accepted lifecycle work")
        } catch {
            XCTAssertEqual(error as? AnimationPlaybackDriverError, .cancelled)
        }
    }

    func testDeadlineOverflowFailsClosedWithoutAdditionalTick_W5_PT_045() async throws {
        let clock = ControllableAnimationClock(
            now: UInt64.max - 5,
            automaticallyAdvances: false
        )
        let recorder = AnimationDriverRecorder()
        let fixture = try makeFixture(clock: clock, mode: .normal, frameCount: 2)

        try await fixture.driver.start { output in
            await recorder.record(output)
        } failure: { error in
            await recorder.recordFailure(error)
        }
        try await waitUntil("deadline overflow reported") {
            await recorder.failures().count == 1
        }

        let outputCount = await recorder.outputCount()
        let failures = await recorder.failures()
        let deadlines = await clock.recordedDeadlines()
        let isRunning = await fixture.driver.isRunningForTesting()
        XCTAssertEqual(outputCount, 1)
        XCTAssertEqual(failures, ["deadline-overflow"])
        XCTAssertTrue(deadlines.isEmpty)
        XCTAssertFalse(isRunning)
        await fixture.driver.cancel()
    }

    func testDriverRejectsDuplicateStartAndUseBeforeStart_W5_PT_046() async throws {
        let clock = ControllableAnimationClock(now: 0, automaticallyAdvances: false)
        let fixture = try makeFixture(clock: clock, mode: .normal, frameCount: 2)

        do {
            try await fixture.driver.setVisible(true)
            XCTFail("Unstarted driver accepted visibility")
        } catch {
            XCTAssertEqual(error as? AnimationPlaybackCursorError, .notStarted)
        }

        try await fixture.driver.start { _ in }
        do {
            try await fixture.driver.start { _ in }
            XCTFail("Driver accepted duplicate start")
        } catch {
            XCTAssertEqual(error as? AnimationPlaybackDriverError, .alreadyStarted)
        }
        await fixture.driver.cancel()
    }

    func testExternalPresentationTicksUseTargetTimestampWithoutDeadlineSleeps_W5_PT_127()
        async throws
    {
        let clock = ControllableAnimationClock(now: 0, automaticallyAdvances: false)
        let recorder = AnimationDriverRecorder()
        let fixture = try makeFixture(clock: clock, mode: .playOnce, frameCount: 3)

        try await fixture.driver.start(
            output: { output in await recorder.record(output) },
            failure: { error in await recorder.recordFailure(error) },
            schedulingMode: .externalPresentationTicks
        )
        let schedulingMode = await fixture.driver.schedulingModeForTesting()
        let isRunning = await fixture.driver.isRunningForTesting()
        XCTAssertEqual(schedulingMode, .externalPresentationTicks)
        XCTAssertFalse(isRunning)

        let first = await fixture.driver.tick(atPresentationNanoseconds: 25)
        let final = await fixture.driver.tick(atPresentationNanoseconds: 30)
        let outputs = await recorder.outputs()
        let deadlines = await clock.recordedDeadlines()

        XCTAssertEqual(first, .advanced)
        XCTAssertEqual(final, .finished)
        XCTAssertEqual(outputs.map(\.frameIndex), [0, 2, 2])
        XCTAssertEqual(outputs.map(\.isFinished), [false, false, true])
        XCTAssertEqual(deadlines, [])
        await fixture.driver.cancel()
    }

    func testExternalPresentationTicksRemainFrozenAcrossVisibilityPause_W5_PT_128() async throws {
        let clock = ControllableAnimationClock(now: 0, automaticallyAdvances: false)
        let recorder = AnimationDriverRecorder()
        let fixture = try makeFixture(clock: clock, mode: .normal, frameCount: 3)

        try await fixture.driver.start(
            output: { output in await recorder.record(output) },
            initiallyVisible: false,
            schedulingMode: .externalPresentationTicks
        )
        let pausedDisposition = await fixture.driver.tick(atPresentationNanoseconds: 50)
        let pausedOutputCount = await recorder.outputCount()
        XCTAssertEqual(pausedDisposition, .paused)
        XCTAssertEqual(pausedOutputCount, 0)

        await clock.advance(to: 50)
        try await fixture.driver.setVisible(true)
        let resumedDisposition = await fixture.driver.tick(atPresentationNanoseconds: 50)
        let resumedOutputs = await recorder.outputs()
        XCTAssertEqual(resumedDisposition, .advanced)
        XCTAssertEqual(resumedOutputs.map(\.frameIndex), [0])

        let nextDisposition = await fixture.driver.tick(atPresentationNanoseconds: 60)
        let nextOutputs = await recorder.outputs()
        let deadlines = await clock.recordedDeadlines()
        XCTAssertEqual(nextDisposition, .advanced)
        XCTAssertEqual(nextOutputs.map(\.frameIndex), [0, 1])
        XCTAssertEqual(deadlines, [])
        await fixture.driver.cancel()
    }

    func testExternalPresentationStateStopsTicksAcrossLifecycleGates_W5_PT_130() async throws {
        let clock = ControllableAnimationClock(now: 0, automaticallyAdvances: false)
        let recorder = AnimationDriverRecorder()
        let stateRecorder = AnimationExternalStateRecorder()
        let fixture = try makeFixture(clock: clock, mode: .normal, frameCount: 3)

        try await fixture.driver.start(
            output: { output in await recorder.record(output) },
            schedulingMode: .externalPresentationTicks,
            externalPresentationState: { active in
                await stateRecorder.record(active)
            }
        )
        let startedStates = await stateRecorder.snapshot()
        XCTAssertEqual(startedStates, [true])

        try await fixture.driver.setApplicationActive(false)
        let inactiveTick = await fixture.driver.tick(atPresentationNanoseconds: 10)
        let inactiveStates = await stateRecorder.snapshot()
        XCTAssertEqual(inactiveTick, .paused)
        XCTAssertEqual(inactiveStates, [true, false])

        try await fixture.driver.setApplicationActive(true)
        let resumedStates = await stateRecorder.snapshot()
        XCTAssertEqual(resumedStates, [true, false, true])

        _ = try await fixture.driver.applyMemoryPressure(.critical)
        let criticalStates = await stateRecorder.snapshot()
        XCTAssertEqual(criticalStates, [true, false, true, false])

        _ = try await fixture.driver.applyMemoryPressure(.normal)
        let normalStates = await stateRecorder.snapshot()
        XCTAssertEqual(normalStates, [true, false, true, false, true])

        await fixture.driver.cancel()
        let cancelledStates = await stateRecorder.snapshot()
        XCTAssertEqual(cancelledStates, [true, false, true, false, true, false])
    }

    func
        testExternalPresentationInvalidationReportsActiveStateForTimelineAndMemoryChanges_W5_PT_156()
        async throws
    {
        let clock = ControllableAnimationClock(now: 0, automaticallyAdvances: false)
        let stateRecorder = AnimationExternalStateRecorder()
        let invalidationRecorder = AnimationExternalStateRecorder()
        let fixture = try makeFixture(clock: clock, mode: .normal, frameCount: 3)

        try await fixture.driver.start(
            output: { _ in },
            schedulingMode: .externalPresentationTicks,
            externalPresentationState: { active in await stateRecorder.record(active) },
            externalPresentationInvalidation: { active in
                await invalidationRecorder.record(active)
            }
        )
        var states = await stateRecorder.snapshot()
        var invalidations = await invalidationRecorder.snapshot()
        XCTAssertEqual(states, [true])
        XCTAssertEqual(invalidations, [])

        try await fixture.driver.restart()
        states = await stateRecorder.snapshot()
        invalidations = await invalidationRecorder.snapshot()
        XCTAssertEqual(invalidations, [true])
        XCTAssertEqual(states, [true])

        try await fixture.driver.seek(toFrame: 1)
        states = await stateRecorder.snapshot()
        invalidations = await invalidationRecorder.snapshot()
        XCTAssertEqual(invalidations, [true, true])
        XCTAssertEqual(states, [true])

        _ = try await fixture.driver.applyMemoryPressure(.warning)
        states = await stateRecorder.snapshot()
        invalidations = await invalidationRecorder.snapshot()
        XCTAssertEqual(invalidations, [true, true, true])
        XCTAssertEqual(states, [true])

        _ = try await fixture.driver.applyMemoryPressure(.critical)
        states = await stateRecorder.snapshot()
        invalidations = await invalidationRecorder.snapshot()
        XCTAssertEqual(invalidations, [true, true, true, false])
        XCTAssertEqual(states, [true, false])

        _ = try await fixture.driver.applyMemoryPressure(.normal)
        states = await stateRecorder.snapshot()
        invalidations = await invalidationRecorder.snapshot()
        XCTAssertEqual(invalidations, [true, true, true, false])
        XCTAssertEqual(states, [true, false, true])
        await fixture.driver.cancel()
    }

    func testExternalLifecycleClampsToFuturePresentationTarget_W5_PT_144() async throws {
        let clock = ControllableAnimationClock(now: 0, automaticallyAdvances: false)
        let recorder = AnimationDriverRecorder()
        let stateRecorder = AnimationExternalStateRecorder()
        let fixture = try makeFixture(clock: clock, mode: .normal, frameCount: 3)

        try await fixture.driver.start(
            output: { output in await recorder.record(output) },
            schedulingMode: .externalPresentationTicks,
            externalPresentationState: { active in await stateRecorder.record(active) }
        )
        let futureTick = await fixture.driver.tick(atPresentationNanoseconds: 100)
        XCTAssertEqual(futureTick, .advanced)

        // CADisplayLink.targetTimestamp predicts a future presentation instant. Lifecycle events may
        // therefore arrive while the monotonic clock is still behind the last sampled target.
        try await fixture.driver.setVisible(false)
        try await fixture.driver.setVisible(true)
        let states = await stateRecorder.snapshot()
        XCTAssertEqual(states, [true, false, true])

        let resumed = await fixture.driver.tick(atPresentationNanoseconds: 100)
        XCTAssertEqual(resumed, .advanced)
        let outputs = await recorder.outputs()
        XCTAssertEqual(outputs.map(\.frameIndex), [0, 1, 1])
        XCTAssertEqual(outputs.last?.droppedFrameCount, 0)
        let failures = await recorder.failures()
        XCTAssertTrue(failures.isEmpty)
        await fixture.driver.cancel()
    }

    func testPlaybackStartTimestampBindsDriverClockAnchor_W5_PT_148() async throws {
        let clock = ControllableAnimationClock(now: 42, automaticallyAdvances: false)
        let fixture = try makeFixture(clock: clock, mode: .normal, frameCount: 3)
        let initialStart = await fixture.driver.playbackStartNanosecondsForTesting()
        XCTAssertNil(initialStart)

        try await fixture.driver.start(
            output: { _ in },
            initiallyVisible: false,
            schedulingMode: .externalPresentationTicks
        )
        let start = await fixture.driver.playbackStartNanosecondsForTesting()
        XCTAssertEqual(start, 42)
        await fixture.driver.cancel()
    }

    func testExternalTicksBypassFullAdvanceBeforeKnownBoundary_W5_PT_149() async throws {
        let clock = ControllableAnimationClock(now: 0, automaticallyAdvances: false)
        let recorder = AnimationDriverRecorder()
        let fixture = try makeFixture(clock: clock, mode: .normal, frameCount: 3)

        try await fixture.driver.start(
            output: { output in await recorder.record(output) },
            schedulingMode: .externalPresentationTicks
        )

        let sameFrame = await fixture.driver.tickCoalescingUnchangedSourceFrames(
            atPresentationNanoseconds: 5
        )
        XCTAssertEqual(sameFrame.disposition, .advanced)
        XCTAssertEqual(sameFrame.nextTransitionNanoseconds, 10)
        let beforeBoundary = await recorder.outputs()
        XCTAssertEqual(beforeBoundary.map(\.frameIndex), [0])

        let transition = await fixture.driver.tickCoalescingUnchangedSourceFrames(
            atPresentationNanoseconds: 10
        )
        XCTAssertEqual(transition.disposition, .advanced)
        XCTAssertEqual(transition.nextTransitionNanoseconds, 20)
        let afterBoundary = await recorder.outputs()
        XCTAssertEqual(afterBoundary.map(\.frameIndex), [0, 1])

        try await fixture.driver.setVisible(false)
        try await fixture.driver.setVisible(true)
        let resumed = await fixture.driver.tickCoalescingUnchangedSourceFrames(
            atPresentationNanoseconds: 10
        )
        XCTAssertEqual(resumed.disposition, .advanced)
        XCTAssertEqual(resumed.nextTransitionNanoseconds, 20)
        let afterResume = await recorder.outputs()
        XCTAssertEqual(afterResume.map(\.frameIndex), [0, 1, 1])

        await fixture.driver.cancel()
    }

    func testExternalFirstFrameBecomesDormantAndCanRecoverAfterPressure_W5_PT_132() async throws {
        let clock = ControllableAnimationClock(now: 0, automaticallyAdvances: false)
        let recorder = AnimationDriverRecorder()
        let stateRecorder = AnimationExternalStateRecorder()
        let fixture = try makeFixture(clock: clock, mode: .firstFrame, frameCount: 3)

        try await fixture.driver.start(
            output: { output in await recorder.record(output) },
            schedulingMode: .externalPresentationTicks,
            externalPresentationState: { active in await stateRecorder.record(active) }
        )
        let initialOutputs = await recorder.outputs()
        let initialStates = await stateRecorder.snapshot()
        XCTAssertEqual(initialOutputs.map(\.frameIndex), [0])
        XCTAssertEqual(initialStates, [false])
        let initialDormantTick = await fixture.driver.tick(
            atPresentationNanoseconds: 10
        )
        XCTAssertEqual(initialDormantTick, .dormant)

        _ = try await fixture.driver.applyMemoryPressure(.critical)
        _ = try await fixture.driver.applyMemoryPressure(.normal)
        let recoveryStates = await stateRecorder.snapshot()
        XCTAssertEqual(recoveryStates, [false, true])

        let recoveredDormantTick = await fixture.driver.tick(
            atPresentationNanoseconds: 20
        )
        XCTAssertEqual(recoveredDormantTick, .dormant)
        let recoveredOutputs = await recorder.outputs()
        let dormantStates = await stateRecorder.snapshot()
        XCTAssertEqual(recoveredOutputs.map(\.frameIndex), [0, 0])
        XCTAssertEqual(dormantStates, [false, true, false])
        await fixture.driver.cancel()
    }

    private func makeFixture(
        clock: ControllableAnimationClock,
        mode: AnimationPlaybackMode,
        frameCount: Int
    ) throws -> (
        driver: AnimationPlaybackDriver,
        provider: DriverTestAnimationProvider
    ) {
        let provider = DriverTestAnimationProvider(image: makeDriverImage())
        let decodeKey = try XCTUnwrap(
            AnimationDecodeKey(
                contentID: ContentID(data: Data("driver-animation".utf8)),
                target: TargetPixels(width: 16, height: 16),
                contentMode: .fit,
                colorPolicy: .convertToSRGB,
                codecFingerprint: "driver-provider-v1",
                animationPolicyVersion: 1,
                timingPolicyVersion: 1,
                frameStrategy: .boundedFrameCache
            )
        )
        let timeline = try AnimationPlaybackTimeline(
            frameDurationsNanoseconds: [UInt64](repeating: 10, count: frameCount),
            additionalRepeatCount: mode == .playOnce ? 0 : nil,
            zeroDurationReplacementNanoseconds: 1,
            timingPolicyVersion: 1
        )
        let session = AnimationPlaybackSession(
            namespace: SecurityNamespaceID("driver-account"),
            generation: NamespaceGeneration(1),
            decodeKey: decodeKey,
            timeline: timeline,
            mode: mode,
            frameMemory: AnimationFrameMemory(costLimit: 16 * 16 * 4 * frameCount),
            windowPolicy: AnimationFrameWindowPolicy(
                normalFrameCount: frameCount,
                warningFrameCount: 1
            )
        )
        let coordinator = AnimationPlaybackCoordinator(session: session, provider: provider)
        return (
            AnimationPlaybackDriver(coordinator: coordinator, clock: clock),
            provider
        )
    }
}

private actor ControllableAnimationClock: AnimationPlaybackClock {
    private struct Waiter {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var now: UInt64
    private let automaticallyAdvances: Bool
    private var deadlines: [UInt64] = []
    private var waiters: [UUID: Waiter] = [:]

    init(now: UInt64, automaticallyAdvances: Bool) {
        self.now = now
        self.automaticallyAdvances = automaticallyAdvances
    }

    func nowNanoseconds() -> UInt64 { now }

    func sleep(untilNanoseconds deadline: UInt64) async throws {
        try Task.checkCancellation()
        deadlines.append(deadline)
        guard deadline > now else { return }
        if automaticallyAdvances {
            now = deadline
            await Task.yield()
            return
        }

        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if deadline <= now {
                    continuation.resume()
                } else {
                    waiters[identifier] = Waiter(
                        deadline: deadline,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(identifier) }
        }
    }

    func advance(to value: UInt64) {
        precondition(value >= now)
        now = value
        resumeEligibleWaiters()
    }

    func advance(by delta: UInt64) {
        let next = now.addingReportingOverflow(delta)
        precondition(!next.overflow)
        now = next.partialValue
        resumeEligibleWaiters()
    }

    func pendingSleepCount() -> Int { waiters.count }
    func recordedDeadlines() -> [UInt64] { deadlines }

    private func resumeEligibleWaiters() {
        let ready = waiters.filter { $0.value.deadline <= now }
        for (identifier, waiter) in ready {
            waiters.removeValue(forKey: identifier)
            waiter.continuation.resume()
        }
    }

    private func cancelWaiter(_ identifier: UUID) {
        guard let waiter = waiters.removeValue(forKey: identifier) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private actor AnimationExternalStateRecorder {
    private var states: [Bool] = []

    func record(_ active: Bool) {
        states.append(active)
    }

    func snapshot() -> [Bool] { states }
}

private actor AnimationDriverRecorder {
    struct Output: Sendable {
        let frameIndex: Int
        let droppedFrameCount: UInt64
        let isFinished: Bool
    }

    private var storedOutputs: [Output] = []
    private var storedFailures: [String] = []

    @discardableResult
    func record(_ output: AnimationPlaybackOutput) -> Int {
        storedOutputs.append(
            Output(
                frameIndex: output.decision.frameIndex,
                droppedFrameCount: output.decision.droppedFrameCount,
                isFinished: output.decision.isFinished
            )
        )
        return storedOutputs.count
    }

    func recordFailure(_ error: any Error) {
        if error as? AnimationPlaybackDriverError == .deadlineOverflow {
            storedFailures.append("deadline-overflow")
        } else {
            storedFailures.append(String(describing: error))
        }
    }

    func outputs() -> [Output] { storedOutputs }
    func outputCount() -> Int { storedOutputs.count }
    func failures() -> [String] { storedFailures }
}

private actor DriverTestAnimationProvider: AnimationFrameProvider {
    private let image: DecodedImage
    private var cancellations = 0

    init(image: DecodedImage) {
        self.image = image
    }

    func frames(in range: Range<Int>) -> [AnimationProviderFrame] {
        range.map { AnimationProviderFrame(index: $0, image: image) }
    }

    func cancel() {
        cancellations += 1
    }

    func cancelCount() -> Int { cancellations }
}

private func makeDriverImage() -> DecodedImage {
    let width = 4
    let height = 4
    let bytesPerRow = width * 4
    let data = Data(repeating: 0x7f, count: bytesPerRow * height)
    let provider = CGDataProvider(data: data as CFData)!
    let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
    return DecodedImage(cgImage: image)
}
