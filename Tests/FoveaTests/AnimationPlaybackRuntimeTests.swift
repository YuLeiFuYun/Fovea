import CoreGraphics
import Foundation
import FoveaCore
import FoveaHTTP
import ImageCraftCore
import XCTest

final class AnimationPlaybackRuntimeTests: XCTestCase {
    func testRuntimeSharesFramesButNotProvidersAcrossHandles_W5_PT_047() async throws {
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 4_096)
        let firstProvider = RuntimeTestAnimationProvider(image: makeRuntimeImage())
        let secondProvider = RuntimeTestAnimationProvider(image: makeRuntimeImage())
        let firstRecorder = RuntimeAnimationRecorder()
        let secondRecorder = RuntimeAnimationRecorder()
        let first = try await makeHandle(runtime: runtime, provider: firstProvider, label: "shared")
        let second = try await makeHandle(
            runtime: runtime, provider: secondProvider, label: "shared")

        try await runtime.start(first) { output in
            await firstRecorder.record(output)
        }
        try await waitUntil("first runtime handle frame") {
            await firstRecorder.count() == 1
        }
        try await runtime.start(second) { output in
            await secondRecorder.record(output)
        }
        try await waitUntil("second runtime handle shared frame") {
            await secondRecorder.count() == 1
        }

        let firstCalls = await firstProvider.callCount()
        let secondCalls = await secondProvider.callCount()
        let firstImage = await firstRecorder.hasImage()
        let secondImage = await secondRecorder.hasImage()
        XCTAssertEqual(firstCalls, 1)
        XCTAssertEqual(secondCalls, 0)
        XCTAssertTrue(firstImage)
        XCTAssertTrue(secondImage)
        let frameCount = await runtime.currentFrameCount()
        let driverCount = await runtime.registeredDriverCount()
        XCTAssertEqual(frameCount, 1)
        XCTAssertEqual(driverCount, 2)
        await runtime.cancelAll()
    }

    func testAutomaticWholeTrackAdmissionRespectsExistingPinnedBytes_W5_PT_171() async throws {
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 192)
        let provider = RuntimeTestAnimationProvider(image: makeRuntimeImage())
        let pinned = try await makePredecodeLoopingHandle(
            runtime: runtime,
            provider: provider,
            label: "automatic-pinned-budget"
        )
        try await runtime.start(
            pinned,
            output: { _ in },
            schedulingMode: .externalPresentationTicks
        )
        let snapshotCandidate =
            await pinned.driver.fullyResidentFramesSnapshotForCompositor()
        let snapshot = try XCTUnwrap(snapshotCandidate)
        XCTAssertEqual(snapshot.frames.count, 2)
        let pinnedCost = await runtime.currentPinnedFrameMemoryCostForTesting()
        XCTAssertEqual(pinnedCost, 128)

        let candidateTimeline = try AnimationPlaybackTimeline(
            frameDurationsNanoseconds: [10, 10],
            additionalRepeatCount: nil,
            zeroDurationReplacementNanoseconds: 1,
            timingPolicyVersion: 1
        )
        let rejected = await runtime.resolveFrameStrategySelection(
            .automaticWholeTrack(
                maximumFrameCount: 2,
                maximumPredecodePeakByteCost: 256
            ),
            timeline: candidateTimeline,
            resolvedMode: .normal,
            wholeTrackDecodedByteCostUpperBound: 128,
            wholeTrackProviderRetainedByteCostUpperBound: 0,
            wholeTrackPredecodePeakByteCostUpperBound: 256,
            explicitMaximumPredecodeAllFrameCount: 0
        )
        XCTAssertEqual(rejected.strategy, .boundedFrameCache)
        XCTAssertEqual(rejected.maximumPredecodeFrames, 0)

        let accepted = await runtime.resolveFrameStrategySelection(
            .automaticWholeTrack(
                maximumFrameCount: 2,
                maximumPredecodePeakByteCost: 256
            ),
            timeline: candidateTimeline,
            resolvedMode: .normal,
            wholeTrackDecodedByteCostUpperBound: 64,
            wholeTrackProviderRetainedByteCostUpperBound: 0,
            wholeTrackPredecodePeakByteCostUpperBound: 160,
            explicitMaximumPredecodeAllFrameCount: 0
        )
        XCTAssertEqual(accepted.strategy, .predecodeAll)
        XCTAssertEqual(accepted.maximumPredecodeFrames, 2)

        _ = snapshot
        await runtime.cancelAll()
    }

    func testAutomaticWholeTrackFiniteTimelineUsesPredecodeAfterPhysicalAdoption_W5_PT_200()
        async throws
    {
        let runtime = AnimationPlaybackRuntime(
            frameMemoryCostLimit: 512,
            automaticWholeTrackPredecodePeakCostLimit: 1_024
        )
        let timeline = try AnimationPlaybackTimeline(
            frameDurationsNanoseconds: [100, 100],
            additionalRepeatCount: 1,
            zeroDurationReplacementNanoseconds: 1,
            timingPolicyVersion: 1
        )
        let resolved = await runtime.resolveFrameStrategySelection(
            .automaticWholeTrack(
                maximumFrameCount: 2,
                maximumPredecodePeakByteCost: 1_024,
                maximumDecodedByteCost: 256
            ),
            timeline: timeline,
            resolvedMode: .normal,
            wholeTrackDecodedByteCostUpperBound: 128,
            wholeTrackProviderRetainedByteCostUpperBound: 32,
            wholeTrackPredecodePeakByteCostUpperBound: 256,
            explicitMaximumPredecodeAllFrameCount: 0
        )
        XCTAssertEqual(resolved.strategy, .predecodeAll)
        XCTAssertEqual(resolved.maximumPredecodeFrames, 2)
    }

    func testAutomaticWholeTrackProviderRetainedReservationBlocksSecondAdmission_W5_PT_189()
        async throws
    {
        let runtime = AnimationPlaybackRuntime(
            frameMemoryCostLimit: 256,
            automaticWholeTrackPredecodePeakCostLimit: 512
        )
        let provider = RuntimeTestAnimationProvider(image: makeRuntimeImage())
        let first = try await makePredecodeLoopingHandle(
            runtime: runtime,
            provider: provider,
            label: "provider-retained-first",
            automaticWholeTrackDecodedByteCostUpperBound: 128,
            providerRetainedByteCost: 80,
            automaticWholeTrackPredecodePeakByteCost: 208
        )
        let retainedAfterFirst = await runtime.currentProviderRetainedMemoryCostForTesting()
        let residentBudgetAfterFirst = await runtime.currentAnimationResidentBudgetCostForTesting()
        XCTAssertEqual(retainedAfterFirst, 80)
        XCTAssertEqual(residentBudgetAfterFirst, 80)

        let timeline = try AnimationPlaybackTimeline(
            frameDurationsNanoseconds: [10, 10],
            additionalRepeatCount: nil,
            zeroDurationReplacementNanoseconds: 1,
            timingPolicyVersion: 1
        )
        let blocked = await runtime.resolveFrameStrategySelection(
            .automaticWholeTrack(
                maximumFrameCount: 2,
                maximumPredecodePeakByteCost: 512
            ),
            timeline: timeline,
            resolvedMode: .normal,
            wholeTrackDecodedByteCostUpperBound: 128,
            wholeTrackProviderRetainedByteCostUpperBound: 64,
            wholeTrackPredecodePeakByteCostUpperBound: 192,
            explicitMaximumPredecodeAllFrameCount: 0
        )
        XCTAssertEqual(blocked.strategy, .boundedFrameCache)
        XCTAssertEqual(blocked.maximumPredecodeFrames, 0)

        await first.cancel()
        let retainedAfterCancel = await runtime.currentProviderRetainedMemoryCostForTesting()
        XCTAssertEqual(retainedAfterCancel, 0)
        let admittedAfterRelease = await runtime.resolveFrameStrategySelection(
            .automaticWholeTrack(
                maximumFrameCount: 2,
                maximumPredecodePeakByteCost: 512
            ),
            timeline: timeline,
            resolvedMode: .normal,
            wholeTrackDecodedByteCostUpperBound: 128,
            wholeTrackProviderRetainedByteCostUpperBound: 64,
            wholeTrackPredecodePeakByteCostUpperBound: 192,
            explicitMaximumPredecodeAllFrameCount: 0
        )
        XCTAssertEqual(admittedAfterRelease.strategy, .predecodeAll)
        XCTAssertEqual(admittedAfterRelease.maximumPredecodeFrames, 2)
    }

    func testAutomaticWholeTrackPeakPermitsSerializeConcurrentPredecode_W5_PT_174()
        async throws
    {
        let runtime = AnimationPlaybackRuntime(
            frameMemoryCostLimit: 512,
            automaticWholeTrackPredecodePeakCostLimit: 192
        )
        let firstProvider = RuntimeSuspendingAnimationProvider(image: makeRuntimeImage())
        let secondProvider = RuntimeSuspendingAnimationProvider(image: makeRuntimeImage())
        let first = try await makePredecodeLoopingHandle(
            runtime: runtime,
            provider: firstProvider,
            label: "peak-serialize-first",
            automaticWholeTrackDecodedByteCostUpperBound: 128,
            providerRetainedByteCost: 0,
            automaticWholeTrackPredecodePeakByteCost: 128
        )
        let second = try await makePredecodeLoopingHandle(
            runtime: runtime,
            provider: secondProvider,
            label: "peak-serialize-second",
            automaticWholeTrackDecodedByteCostUpperBound: 128,
            providerRetainedByteCost: 0,
            automaticWholeTrackPredecodePeakByteCost: 128
        )

        let firstStart = Task {
            try await runtime.start(
                first,
                output: { _ in },
                schedulingMode: .externalPresentationTicks
            )
        }
        try await waitUntil("first automatic predecode enters provider") {
            await firstProvider.callCount() == 1
        }
        let usedByFirst =
            await runtime.automaticWholeTrackPredecodePeakUsedUnitsForTesting()
        XCTAssertEqual(usedByFirst, 128)

        let secondStart = Task {
            try await runtime.start(
                second,
                output: { _ in },
                schedulingMode: .externalPresentationTicks
            )
        }
        for _ in 0..<20 { await Task.yield() }
        let secondCallsWhileQueued = await secondProvider.callCount()
        let usedWhileSecondQueued =
            await runtime.automaticWholeTrackPredecodePeakUsedUnitsForTesting()
        XCTAssertEqual(secondCallsWhileQueued, 0)
        XCTAssertEqual(usedWhileSecondQueued, 128)

        await firstProvider.release()
        try await firstStart.value
        try await waitUntil("second automatic predecode enters after first release") {
            await secondProvider.callCount() == 1
        }
        let usedBySecond =
            await runtime.automaticWholeTrackPredecodePeakUsedUnitsForTesting()
        XCTAssertEqual(usedBySecond, 128)
        await secondProvider.release()
        try await secondStart.value
        let usedAfterBothComplete =
            await runtime.automaticWholeTrackPredecodePeakUsedUnitsForTesting()
        XCTAssertEqual(usedAfterBothComplete, 0)
        await runtime.cancelAll()
    }

    func testQueuedAutomaticWholeTrackPeakPermitCancelsBeforeProvider_W5_PT_175()
        async throws
    {
        let runtime = AnimationPlaybackRuntime(
            frameMemoryCostLimit: 512,
            automaticWholeTrackPredecodePeakCostLimit: 192
        )
        let firstProvider = RuntimeSuspendingAnimationProvider(image: makeRuntimeImage())
        let secondProvider = RuntimeSuspendingAnimationProvider(image: makeRuntimeImage())
        let first = try await makePredecodeLoopingHandle(
            runtime: runtime,
            provider: firstProvider,
            label: "peak-cancel-first",
            automaticWholeTrackDecodedByteCostUpperBound: 128,
            providerRetainedByteCost: 0,
            automaticWholeTrackPredecodePeakByteCost: 128
        )
        let second = try await makePredecodeLoopingHandle(
            runtime: runtime,
            provider: secondProvider,
            label: "peak-cancel-second",
            automaticWholeTrackDecodedByteCostUpperBound: 128,
            providerRetainedByteCost: 0,
            automaticWholeTrackPredecodePeakByteCost: 128
        )

        let firstStart = Task {
            try await runtime.start(
                first,
                output: { _ in },
                schedulingMode: .externalPresentationTicks
            )
        }
        try await waitUntil("first automatic predecode holds global peak permit") {
            await firstProvider.callCount() == 1
        }

        let secondStart = Task {
            try await runtime.start(
                second,
                output: { _ in },
                schedulingMode: .externalPresentationTicks
            )
        }
        try await waitUntil("second automatic predecode queues for global peak permit") {
            await runtime.automaticWholeTrackPredecodePeakQueuedCountForTesting() == 1
        }
        let secondCallsBeforeCancel = await secondProvider.callCount()
        let usedWhileSecondQueued =
            await runtime.automaticWholeTrackPredecodePeakUsedUnitsForTesting()
        XCTAssertEqual(secondCallsBeforeCancel, 0)
        XCTAssertEqual(usedWhileSecondQueued, 128)

        await second.cancel()
        do {
            try await secondStart.value
            XCTFail("Queued automatic predecode completed after its handle was cancelled")
        } catch is CancellationError {
            // 预期路径：coordinator 取消会同时取消排队中的 weighted permit request。
        } catch let error as AnimationPlaybackCoordinatorError {
            XCTAssertEqual(error, .cancelled)
        } catch let error as AnimationPlaybackDriverError {
            XCTAssertEqual(error, .cancelled)
        }
        let secondCallsAfterCancel = await secondProvider.callCount()
        let secondCancels = await secondProvider.cancelCount()
        let usedAfterQueuedCancel =
            await runtime.automaticWholeTrackPredecodePeakUsedUnitsForTesting()
        XCTAssertEqual(secondCallsAfterCancel, 0)
        XCTAssertEqual(secondCancels, 1)
        XCTAssertEqual(usedAfterQueuedCancel, 128)

        await firstProvider.release()
        try await firstStart.value
        let usedAfterFirstCompletes =
            await runtime.automaticWholeTrackPredecodePeakUsedUnitsForTesting()
        XCTAssertEqual(usedAfterFirstCompletes, 0)
        await runtime.cancelAll()
    }

    func testCancellationRaceCannotSpawnAutomaticPredecodeAfterInvalidation_W5_PT_205()
        async throws
    {
        for delay in 0..<64 {
            let runtime = AnimationPlaybackRuntime(
                frameMemoryCostLimit: 512,
                automaticWholeTrackPredecodePeakCostLimit: 192
            )
            let firstProvider = RuntimeSuspendingAnimationProvider(image: makeRuntimeImage())
            let secondProvider = RuntimeSuspendingAnimationProvider(image: makeRuntimeImage())
            let first = try await makePredecodeLoopingHandle(
                runtime: runtime,
                provider: firstProvider,
                label: "cancel-race-first-\(delay)",
                automaticWholeTrackDecodedByteCostUpperBound: 128,
                providerRetainedByteCost: 0,
                automaticWholeTrackPredecodePeakByteCost: 128
            )
            let second = try await makePredecodeLoopingHandle(
                runtime: runtime,
                provider: secondProvider,
                label: "cancel-race-second-\(delay)",
                automaticWholeTrackDecodedByteCostUpperBound: 128,
                providerRetainedByteCost: 0,
                automaticWholeTrackPredecodePeakByteCost: 128
            )
            let firstStart = Task {
                try await runtime.start(
                    first, output: { _ in }, schedulingMode: .externalPresentationTicks
                )
            }
            try await waitUntil("race blocker enters provider") {
                await firstProvider.callCount() == 1
            }
            let secondStart = Task {
                try await runtime.start(
                    second, output: { _ in }, schedulingMode: .externalPresentationTicks
                )
            }
            for _ in 0..<delay { await Task.yield() }

            await second.cancel()
            await firstProvider.release()
            try await firstStart.value
            _ = try? await secondStart.value

            let secondCalls = await secondProvider.callCount()
            let secondCancels = await secondProvider.cancelCount()
            let used = await runtime.automaticWholeTrackPredecodePeakUsedUnitsForTesting()
            let queued = await runtime.automaticWholeTrackPredecodePeakQueuedCountForTesting()
            XCTAssertEqual(secondCalls, 0, "delay=\(delay)")
            XCTAssertEqual(secondCancels, 1, "delay=\(delay)")
            XCTAssertEqual(used, 0, "delay=\(delay)")
            XCTAssertEqual(queued, 0, "delay=\(delay)")
            await runtime.cancelAll()
        }
    }

    func testAutomaticWholeTrackHandoffPinsBeforeNextAdmissionAndSecondFallsBack_W5_PT_176()
        async throws
    {
        let runtime = AnimationPlaybackRuntime(
            frameMemoryCostLimit: 192,
            automaticWholeTrackPredecodePeakCostLimit: 256
        )
        let firstProvider = RuntimeTestAnimationProvider(image: makeRuntimeImage())
        let secondProvider = RuntimeTestAnimationProvider(image: makeRuntimeImage())
        let first = try await makePredecodeLoopingHandle(
            runtime: runtime,
            provider: firstProvider,
            label: "handoff-first",
            automaticWholeTrackDecodedByteCostUpperBound: 128,
            providerRetainedByteCost: 0,
            automaticWholeTrackPredecodePeakByteCost: 128
        )
        let second = try await makePredecodeLoopingHandle(
            runtime: runtime,
            provider: secondProvider,
            label: "handoff-second",
            automaticWholeTrackDecodedByteCostUpperBound: 128,
            providerRetainedByteCost: 0,
            automaticWholeTrackPredecodePeakByteCost: 128
        )

        try await runtime.start(
            first,
            output: { _ in },
            schedulingMode: .externalPresentationTicks
        )
        let firstRanges = await firstProvider.requestedRanges()
        let pinnedAfterFirstStart = await runtime.currentPinnedFrameMemoryCostForTesting()
        XCTAssertEqual(firstRanges, [0..<2])
        XCTAssertEqual(pinnedAfterFirstStart, 128)

        try await runtime.start(
            second,
            output: { _ in },
            schedulingMode: .externalPresentationTicks
        )
        let secondRanges = await secondProvider.requestedRanges()
        let pinnedAfterSecondStart = await runtime.currentPinnedFrameMemoryCostForTesting()
        XCTAssertEqual(secondRanges, [0..<1])
        XCTAssertEqual(pinnedAfterSecondStart, 128)

        var firstSnapshot = await first.driver.fullyResidentFramesSnapshotForCompositor()
        let secondSnapshot = await second.driver.fullyResidentFramesSnapshotForCompositor()
        XCTAssertEqual(firstSnapshot?.frames.count, 2)
        XCTAssertNil(secondSnapshot)

        firstSnapshot = nil
        let pinnedAfterHandoffRelease = await runtime.currentPinnedFrameMemoryCostForTesting()
        XCTAssertEqual(pinnedAfterHandoffRelease, 0)
        await runtime.cancelAll()
    }

    func testAutomaticWholeTrackPeakQueueUsesRequestPriority_W5_PT_181() async throws {
        let runtime = AnimationPlaybackRuntime(
            frameMemoryCostLimit: 512,
            automaticWholeTrackPredecodePeakCostLimit: 128
        )
        let blockerProvider = RuntimeSuspendingAnimationProvider(image: makeRuntimeImage())
        let lowProvider = RuntimeSuspendingAnimationProvider(image: makeRuntimeImage())
        let highProvider = RuntimeSuspendingAnimationProvider(image: makeRuntimeImage())
        let blocker = try await makePredecodeLoopingHandle(
            runtime: runtime,
            provider: blockerProvider,
            label: "priority-blocker",
            automaticWholeTrackDecodedByteCostUpperBound: 128,
            providerRetainedByteCost: 0,
            automaticWholeTrackPredecodePeakByteCost: 128,
            decodePriority: .normal
        )
        let low = try await makePredecodeLoopingHandle(
            runtime: runtime,
            provider: lowProvider,
            label: "priority-low",
            automaticWholeTrackDecodedByteCostUpperBound: 128,
            providerRetainedByteCost: 0,
            automaticWholeTrackPredecodePeakByteCost: 128,
            decodePriority: .low
        )
        let high = try await makePredecodeLoopingHandle(
            runtime: runtime,
            provider: highProvider,
            label: "priority-high",
            automaticWholeTrackDecodedByteCostUpperBound: 128,
            providerRetainedByteCost: 0,
            automaticWholeTrackPredecodePeakByteCost: 128,
            decodePriority: .userInitiated
        )

        let blockerStart = Task {
            try await runtime.start(
                blocker,
                output: { _ in },
                schedulingMode: .externalPresentationTicks
            )
        }
        try await waitUntil("priority blocker holds automatic peak permit") {
            await blockerProvider.callCount() == 1
        }

        let lowStart = Task {
            try await runtime.start(
                low,
                output: { _ in },
                schedulingMode: .externalPresentationTicks
            )
        }
        try await waitUntil("low-priority automatic request queues") {
            await runtime.automaticWholeTrackPredecodePeakQueuedCountForTesting() == 1
        }
        let highStart = Task {
            try await runtime.start(
                high,
                output: { _ in },
                schedulingMode: .externalPresentationTicks
            )
        }
        try await waitUntil("high-priority automatic request queues") {
            await runtime.automaticWholeTrackPredecodePeakQueuedCountForTesting() == 2
        }

        await blockerProvider.release()
        try await blockerStart.value
        try await waitUntil("high priority bypasses queued low priority") {
            await highProvider.callCount() == 1
        }
        let lowCallsWhileHighRuns = await lowProvider.callCount()
        XCTAssertEqual(lowCallsWhileHighRuns, 0)

        await highProvider.release()
        try await highStart.value
        try await waitUntil("low priority runs after high completes") {
            await lowProvider.callCount() == 1
        }
        await lowProvider.release()
        try await lowStart.value

        var blockerSnapshot = await blocker.driver.fullyResidentFramesSnapshotForCompositor()
        var highSnapshot = await high.driver.fullyResidentFramesSnapshotForCompositor()
        var lowSnapshot = await low.driver.fullyResidentFramesSnapshotForCompositor()
        XCTAssertEqual(blockerSnapshot?.frames.count, 2)
        XCTAssertEqual(highSnapshot?.frames.count, 2)
        XCTAssertEqual(lowSnapshot?.frames.count, 2)
        blockerSnapshot = nil
        highSnapshot = nil
        lowSnapshot = nil
        await runtime.cancelAll()
    }

    func testStaticDecodeAndAutomaticAnimationShareGlobalWorkingSet_W5_PT_177() async throws {
        let globalWorkingSet = AsyncPermitPool(limit: 4_096, queueLimit: 16)
        let globalDecode = AsyncPermitPool(limit: 2, queueLimit: 16)
        let gate = RuntimeBlockingDecodeGate()
        let stage = DecodeStage(
            codec: RuntimeBlockingDecodeCodec(gate: gate),
            limits: .coreV1,
            diagnostics: NullDiagnosticsSink(),
            maximumConcurrentDecodes: 1,
            maximumDecodeWorkingSetBytes: 4_096,
            maximumQueuedDecodes: 8,
            globalDecodePermits: globalDecode,
            globalWorkingSetPermits: globalWorkingSet
        )
        let staticTask = try startBlockingStaticDecode(stage: stage, path: "shared-working-set")
        try await waitUntil("static decode holds global working-set permit") {
            gate.hasEntered
        }
        let staticUsedUnits = await globalWorkingSet.usedUnits
        XCTAssertGreaterThan(staticUsedUnits, 0)

        let runtime = AnimationPlaybackRuntime(
            frameMemoryCostLimit: 512,
            automaticWholeTrackPredecodePeakCostLimit: 4_096,
            sharedDecodeWorkingSetPermits: globalWorkingSet,
            sharedDecodePermits: globalDecode
        )
        let provider = RuntimeTestAnimationProvider(image: makeRuntimeImage())
        let handle = try await makePredecodeLoopingHandle(
            runtime: runtime,
            provider: provider,
            label: "shared-working-set-animation",
            automaticWholeTrackDecodedByteCostUpperBound: 128,
            providerRetainedByteCost: 0,
            automaticWholeTrackPredecodePeakByteCost: 4_096
        )
        let animationStart = Task {
            try await runtime.start(
                handle,
                output: { _ in },
                schedulingMode: .externalPresentationTicks
            )
        }
        try await waitUntil("animation waits on shared working-set pool") {
            await globalWorkingSet.queuedCount() == 1
        }
        let providerCallsWhileStaticDecodeRuns = await provider.callCount()
        XCTAssertEqual(providerCallsWhileStaticDecodeRuns, 0)

        gate.release()
        _ = try await staticTask.value
        try await animationStart.value
        let providerCallsAfterRelease = await provider.callCount()
        XCTAssertEqual(providerCallsAfterRelease, 1)
        var snapshot = await handle.driver.fullyResidentFramesSnapshotForCompositor()
        XCTAssertEqual(snapshot?.frames.count, 2)
        snapshot = nil
        await runtime.cancelAll()
    }

    func testStaticDecodeAndAutomaticAnimationShareGlobalDecodeConcurrency_W5_PT_178()
        async throws
    {
        let globalWorkingSet = AsyncPermitPool(limit: 16_384, queueLimit: 16)
        let globalDecode = AsyncPermitPool(limit: 1, queueLimit: 16)
        let gate = RuntimeBlockingDecodeGate()
        let stage = DecodeStage(
            codec: RuntimeBlockingDecodeCodec(gate: gate),
            limits: .coreV1,
            diagnostics: NullDiagnosticsSink(),
            maximumConcurrentDecodes: 1,
            maximumDecodeWorkingSetBytes: 16_384,
            maximumQueuedDecodes: 8,
            globalDecodePermits: globalDecode,
            globalWorkingSetPermits: globalWorkingSet
        )
        let staticTask = try startBlockingStaticDecode(stage: stage, path: "shared-concurrency")
        try await waitUntil("static decode holds global decode-count permit") {
            gate.hasEntered
        }
        let globalDecodeUsedByStatic = await globalDecode.usedUnits
        XCTAssertEqual(globalDecodeUsedByStatic, 1)

        let runtime = AnimationPlaybackRuntime(
            frameMemoryCostLimit: 512,
            automaticWholeTrackPredecodePeakCostLimit: 4_096,
            sharedDecodeWorkingSetPermits: globalWorkingSet,
            sharedDecodePermits: globalDecode
        )
        let provider = RuntimeTestAnimationProvider(image: makeRuntimeImage())
        let handle = try await makePredecodeLoopingHandle(
            runtime: runtime,
            provider: provider,
            label: "shared-concurrency-animation",
            automaticWholeTrackDecodedByteCostUpperBound: 128,
            providerRetainedByteCost: 0,
            automaticWholeTrackPredecodePeakByteCost: 4_096
        )
        let animationStart = Task {
            try await runtime.start(
                handle,
                output: { _ in },
                schedulingMode: .externalPresentationTicks
            )
        }
        try await waitUntil("animation waits on shared decode-count pool") {
            await globalDecode.queuedCount() == 1
        }
        let providerCallsWhileStaticDecodeRuns = await provider.callCount()
        let workingSetUsedWhileQueued = await globalWorkingSet.usedUnits
        XCTAssertEqual(providerCallsWhileStaticDecodeRuns, 0)
        XCTAssertGreaterThan(workingSetUsedWhileQueued, 4_096)

        gate.release()
        _ = try await staticTask.value
        try await animationStart.value
        let providerCallsAfterRelease = await provider.callCount()
        XCTAssertEqual(providerCallsAfterRelease, 1)
        var snapshot = await handle.driver.fullyResidentFramesSnapshotForCompositor()
        XCTAssertEqual(snapshot?.frames.count, 2)
        snapshot = nil
        await runtime.cancelAll()
    }

    func testNewHandleCreatedWhileInactiveDoesNoFrameWorkUntilActivation_W5_PT_048() async throws {
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 4_096)
        let inactiveReport = await runtime.setApplicationActive(false)
        XCTAssertEqual(inactiveReport.registeredDriverCount, 0)

        let provider = RuntimeTestAnimationProvider(image: makeRuntimeImage())
        let recorder = RuntimeAnimationRecorder()
        let handle = try await makeHandle(runtime: runtime, provider: provider, label: "inactive")
        try await runtime.start(handle) { output in
            await recorder.record(output)
        }
        for _ in 0..<10 { await Task.yield() }
        let inactiveProviderCalls = await provider.callCount()
        let inactiveOutputCount = await recorder.count()
        XCTAssertEqual(inactiveProviderCalls, 0)
        XCTAssertEqual(inactiveOutputCount, 0)

        let activeReport = await runtime.setApplicationActive(true)
        try await waitUntil("inactive runtime handle activates") {
            await recorder.count() == 1
        }
        XCTAssertEqual(activeReport.affectedDriverCount, 1)
        XCTAssertEqual(activeReport.failedDriverCount, 0)
        let activeProviderCalls = await provider.callCount()
        XCTAssertEqual(activeProviderCalls, 1)
        await runtime.cancelAll()
    }

    func testCriticalPressurePausesAndPurgesAllRuntimeFrames_W5_PT_049() async throws {
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 8_192)
        let firstProvider = RuntimeTestAnimationProvider(image: makeRuntimeImage())
        let secondProvider = RuntimeTestAnimationProvider(image: makeRuntimeImage())
        let firstRecorder = RuntimeAnimationRecorder()
        let secondRecorder = RuntimeAnimationRecorder()
        let first = try await makeHandle(runtime: runtime, provider: firstProvider, label: "first")
        let second = try await makeHandle(
            runtime: runtime, provider: secondProvider, label: "second")

        try await runtime.start(first) { output in await firstRecorder.record(output) }
        try await runtime.start(second) { output in await secondRecorder.record(output) }
        try await waitUntil("runtime frames populated") {
            await runtime.currentFrameCount() == 2
        }

        let report = await runtime.applyMemoryPressure(.critical)
        XCTAssertEqual(report.registeredDriverCount, 2)
        XCTAssertEqual(report.affectedDriverCount, 2)
        XCTAssertEqual(report.failedDriverCount, 0)
        XCTAssertEqual(report.removedFrames.itemCount, 2)
        XCTAssertGreaterThan(report.removedFrames.costBytes, 0)
        let purgedFrameCount = await runtime.currentFrameCount()
        let purgedFrameCost = await runtime.currentFrameMemoryCost()
        XCTAssertEqual(purgedFrameCount, 0)
        XCTAssertEqual(purgedFrameCost, 0)

        let recovery = await runtime.applyMemoryPressure(.normal)
        XCTAssertEqual(recovery.affectedDriverCount, 2)
        try await waitUntil("runtime frames repopulated after pressure") {
            await runtime.currentFrameCount() == 2
        }
        let firstCallCount = await firstProvider.callCount()
        let secondCallCount = await secondProvider.callCount()
        XCTAssertEqual(firstCallCount, 2)
        XCTAssertEqual(secondCallCount, 2)
        await runtime.cancelAll()
    }

    func testHandleCancelIsIdempotentAndRemovesRegistration_W5_PT_050() async throws {
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 4_096)
        let provider = RuntimeTestAnimationProvider(image: makeRuntimeImage())
        let handle = try await makeHandle(runtime: runtime, provider: provider, label: "cancel")
        try await runtime.start(handle) { _ in }
        try await waitUntil("runtime handle starts") {
            await provider.callCount() == 1
        }

        await handle.cancel()
        await handle.cancel()
        let registeredCount = await runtime.registeredDriverCount()
        let cancelCount = await provider.cancelCount()
        XCTAssertEqual(registeredCount, 0)
        XCTAssertEqual(cancelCount, 1)
    }

    func testRuntimeCapacityAndForeignHandleFailClosed_W5_PT_051() async throws {
        let firstRuntime = AnimationPlaybackRuntime(
            frameMemoryCostLimit: 4_096,
            maximumDriverCount: 1
        )
        let secondRuntime = AnimationPlaybackRuntime(frameMemoryCostLimit: 4_096)
        let first = try await makeHandle(
            runtime: firstRuntime,
            provider: RuntimeTestAnimationProvider(image: makeRuntimeImage()),
            label: "capacity"
        )
        do {
            _ = try await makeHandle(
                runtime: firstRuntime,
                provider: RuntimeTestAnimationProvider(image: makeRuntimeImage()),
                label: "overflow"
            )
            XCTFail("Runtime accepted a handle beyond its hard capacity")
        } catch {
            XCTAssertEqual(error as? AnimationPlaybackRuntimeError, .capacityExceeded)
        }

        do {
            try await secondRuntime.start(first) { _ in }
            XCTFail("Foreign runtime accepted another runtime's handle")
        } catch {
            XCTAssertEqual(error as? AnimationPlaybackRuntimeError, .invalidRegistration)
        }
        await firstRuntime.cancelAll()
        await secondRuntime.cancelAll()
    }

    func testLiveSessionCreatedWhileInactiveDefersDecodeUntilActivation_W5_PT_086() async throws {
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 4_096)
        let inactive = await runtime.setApplicationActive(false)
        XCTAssertEqual(inactive.registeredLiveSessionCount, 0)

        let source = RuntimeLiveSource()
        let decoder = RuntimeLiveDecoder()
        let recorder = RuntimeLiveRecorder()
        let session = MultipartJPEGLivePlaybackSession(
            stream: source.stream,
            decoder: decoder,
            policy: MultipartJPEGLivePlaybackPolicy(minimumFrameIntervalNanoseconds: 1),
            clock: RuntimeConstantClock()
        )
        let handle = try await runtime.registerLiveSession(session)
        try await runtime.startLive(handle) { output in
            await recorder.record(output)
        }
        source.yield(RuntimeLiveSource.part(index: 0))
        for _ in 0..<20 { await Task.yield() }
        let inactiveDecodeCount = await decoder.count()
        let inactiveOutputCount = await recorder.count()
        XCTAssertEqual(inactiveDecodeCount, 0)
        XCTAssertEqual(inactiveOutputCount, 0)

        let active = await runtime.setApplicationActive(true)
        XCTAssertEqual(active.registeredLiveSessionCount, 1)
        XCTAssertEqual(active.affectedLiveSessionCount, 1)
        XCTAssertEqual(active.failedLiveSessionCount, 0)
        try await waitUntil("inactive live runtime session activates") {
            await recorder.count() == 1
        }
        let decoded = await decoder.indices()
        XCTAssertEqual(decoded, [0])
        await runtime.cancelAll()
    }

    func testCriticalPressureDefersLiveDecodeAndNormalResumesLatest_W5_PT_087() async throws {
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 4_096)
        let source = RuntimeLiveSource()
        let decoder = RuntimeLiveDecoder()
        let recorder = RuntimeLiveRecorder()
        let session = MultipartJPEGLivePlaybackSession(
            stream: source.stream,
            decoder: decoder,
            policy: MultipartJPEGLivePlaybackPolicy(minimumFrameIntervalNanoseconds: 1),
            clock: RuntimeConstantClock()
        )
        let handle = try await runtime.registerLiveSession(session)
        try await runtime.startLive(handle) { output in
            await recorder.record(output)
        }

        let critical = await runtime.applyMemoryPressure(.critical)
        XCTAssertEqual(critical.registeredLiveSessionCount, 1)
        XCTAssertEqual(critical.affectedLiveSessionCount, 1)
        source.yield(RuntimeLiveSource.part(index: 0))
        source.yield(RuntimeLiveSource.part(index: 1))
        try await waitUntil("critical live runtime consumes dropped frames") {
            let state = await session.snapshotForTesting()
            return state.pendingPartIndex == nil
                && state.droppedEncodedFrameCount == 2
        }
        let criticalDecodeCount = await decoder.count()
        XCTAssertEqual(criticalDecodeCount, 0)

        let criticalState = await session.snapshotForTesting()
        XCTAssertNil(criticalState.pendingPartIndex)
        XCTAssertEqual(criticalState.droppedEncodedFrameCount, 2)

        let normal = await runtime.applyMemoryPressure(.normal)
        XCTAssertEqual(normal.affectedLiveSessionCount, 1)
        for _ in 0..<20 { await Task.yield() }
        let outputCountBeforeFreshFrame = await recorder.count()
        XCTAssertEqual(outputCountBeforeFreshFrame, 0)
        source.yield(RuntimeLiveSource.part(index: 2))
        try await waitUntil("critical live runtime session accepts fresh frame") {
            await recorder.count() == 1
        }
        let decoded = await decoder.indices()
        let outputs = await recorder.outputs()
        XCTAssertEqual(decoded, [2])
        XCTAssertEqual(outputs.map(\.sourcePartIndex), [2])
        XCTAssertEqual(outputs.map(\.droppedEncodedFrameCount), [2])
        await runtime.cancelAll()
    }

    func testRuntimeCapacityIsSharedAcrossStaticAndLiveRegistrations_W5_PT_088() async throws {
        let firstRuntime = AnimationPlaybackRuntime(
            frameMemoryCostLimit: 4_096,
            maximumDriverCount: 1
        )
        let secondRuntime = AnimationPlaybackRuntime(frameMemoryCostLimit: 4_096)
        let source = RuntimeLiveSource()
        let session = MultipartJPEGLivePlaybackSession(
            stream: source.stream,
            decoder: RuntimeLiveDecoder(),
            clock: RuntimeConstantClock()
        )
        let live = try await firstRuntime.registerLiveSession(session)

        do {
            _ = try await makeHandle(
                runtime: firstRuntime,
                provider: RuntimeTestAnimationProvider(image: makeRuntimeImage()),
                label: "live-capacity"
            )
            XCTFail("Runtime allowed static animation beyond shared registration capacity")
        } catch {
            XCTAssertEqual(error as? AnimationPlaybackRuntimeError, .capacityExceeded)
        }
        do {
            try await secondRuntime.startLive(live) { _ in }
            XCTFail("Foreign runtime accepted another runtime's live handle")
        } catch {
            XCTAssertEqual(error as? AnimationPlaybackRuntimeError, .invalidRegistration)
        }
        await firstRuntime.cancelAll()
        await secondRuntime.cancelAll()
    }

    func testRuntimeCancelAllCancelsLiveSessionsAndClearsRegistration_W5_PT_089() async throws {
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 4_096)
        let source = RuntimeLiveSource()
        let session = MultipartJPEGLivePlaybackSession(
            stream: source.stream,
            decoder: RuntimeLiveDecoder(),
            clock: RuntimeConstantClock()
        )
        let handle = try await runtime.registerLiveSession(session)
        try await runtime.startLive(handle) { _ in }

        await runtime.cancelAll()
        await runtime.cancelAll()
        let count = await runtime.registeredLiveSessionCount()
        let snapshot = await session.snapshotForTesting()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(snapshot.isCancelled)
    }

    func testNamespaceCancellationRemovesOnlyMatchingStaticAndLiveSessions_W5_PT_098()
        async throws
    {
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 16 * 1024)
        let namespaceA = SecurityNamespaceID("runtime-namespace-a")
        let namespaceB = SecurityNamespaceID("runtime-namespace-b")
        let providerA = RuntimeTestAnimationProvider(image: makeRuntimeImage())
        let providerB = RuntimeTestAnimationProvider(image: makeRuntimeImage())
        let staticA = try await makeHandle(
            runtime: runtime,
            provider: providerA,
            label: "namespace-a",
            namespace: namespaceA
        )
        let staticB = try await makeHandle(
            runtime: runtime,
            provider: providerB,
            label: "namespace-b",
            namespace: namespaceB
        )
        try await runtime.start(staticA) { _ in }
        try await runtime.start(staticB) { _ in }
        try await waitUntil("namespace static frames populate") {
            await runtime.currentFrameCount() == 2
        }

        let liveSourceA = RuntimeLiveSource()
        let liveSourceB = RuntimeLiveSource()
        let liveSessionA = MultipartJPEGLivePlaybackSession(
            stream: liveSourceA.stream,
            decoder: RuntimeLiveDecoder(),
            clock: RuntimeConstantClock()
        )
        let liveSessionB = MultipartJPEGLivePlaybackSession(
            stream: liveSourceB.stream,
            decoder: RuntimeLiveDecoder(),
            clock: RuntimeConstantClock()
        )
        let liveA = try await runtime.registerLiveSession(
            liveSessionA,
            namespace: namespaceA,
            generation: NamespaceGeneration(1)
        )
        let liveB = try await runtime.registerLiveSession(
            liveSessionB,
            namespace: namespaceB,
            generation: NamespaceGeneration(1)
        )
        try await runtime.startLive(liveA) { _ in }
        try await runtime.startLive(liveB) { _ in }

        await runtime.cancelAll(namespace: namespaceA)

        let driverCount = await runtime.registeredDriverCount()
        let liveCount = await runtime.registeredLiveSessionCount()
        let frameCount = await runtime.currentFrameCount()
        let providerACancels = await providerA.cancelCount()
        let providerBCancels = await providerB.cancelCount()
        let liveAState = await liveSessionA.snapshotForTesting()
        let liveBState = await liveSessionB.snapshotForTesting()
        XCTAssertEqual(driverCount, 1)
        XCTAssertEqual(liveCount, 1)
        XCTAssertEqual(frameCount, 1)
        XCTAssertEqual(providerACancels, 1)
        XCTAssertEqual(providerBCancels, 0)
        XCTAssertTrue(liveAState.isCancelled)
        XCTAssertFalse(liveBState.isCancelled)

        liveSourceB.yield(RuntimeLiveSource.part(index: 0))
        try await waitUntil("unrelated namespace live session remains usable") {
            await liveSessionB.snapshotForTesting().decodedFrameCount == 1
        }
        await runtime.cancelAll()
    }

    func testNamespaceRevocationDoesNotResurrectExternallyHeldPinnedFrames_W5_PT_172()
        async throws
    {
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 192)
        let namespace = SecurityNamespaceID("runtime-revoke-pinned")
        let provider = RuntimeTestAnimationProvider(image: makeRuntimeImage())
        let handle = try await makePredecodeLoopingHandle(
            runtime: runtime,
            provider: provider,
            label: "revoke-pinned",
            namespace: namespace
        )
        try await runtime.start(
            handle,
            output: { _ in },
            schedulingMode: .externalPresentationTicks
        )
        var heldSnapshot = await handle.driver.fullyResidentFramesSnapshotForCompositor()
        XCTAssertEqual(heldSnapshot?.frames.count, 2)
        let pinnedBeforeRevoke = await runtime.currentPinnedFrameMemoryCostForTesting()
        XCTAssertEqual(pinnedBeforeRevoke, 128)

        await runtime.namespaceWillRevoke(
            namespace,
            minimumActiveGeneration: NamespaceGeneration(2)
        )
        let driversAfterRevoke = await runtime.registeredDriverCount()
        let pinnedWhileExternallyHeld = await runtime.currentPinnedFrameMemoryCostForTesting()
        XCTAssertEqual(driversAfterRevoke, 0)
        XCTAssertEqual(pinnedWhileExternallyHeld, 128)

        heldSnapshot = nil
        let pinnedAfterRelease = await runtime.currentPinnedFrameMemoryCostForTesting()
        let costAfterRelease = await runtime.currentFrameMemoryCost()
        let framesAfterRelease = await runtime.currentFrameCount()
        XCTAssertEqual(pinnedAfterRelease, 0)
        XCTAssertEqual(costAfterRelease, 0)
        XCTAssertEqual(framesAfterRelease, 0)
    }

    func testNamespaceRevocationReleasesOnlyMatchingProviderRetainedReservation_W5_PT_194()
        async throws
    {
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 256)
        let namespaceA = SecurityNamespaceID("runtime-retained-revoke-a")
        let namespaceB = SecurityNamespaceID("runtime-retained-revoke-b")
        let providerA = RuntimeTestAnimationProvider(image: makeRuntimeImage())
        let providerB = RuntimeTestAnimationProvider(image: makeRuntimeImage())
        let handleA = try await makeHandle(
            runtime: runtime,
            provider: providerA,
            label: "retained-revoke-a",
            namespace: namespaceA,
            providerRetainedByteCost: 32
        )
        let handleB = try await makeHandle(
            runtime: runtime,
            provider: providerB,
            label: "retained-revoke-b",
            namespace: namespaceB,
            providerRetainedByteCost: 48
        )
        let retainedBeforeRevoke = await runtime.currentProviderRetainedMemoryCostForTesting()
        XCTAssertEqual(retainedBeforeRevoke, 80)

        await runtime.namespaceWillRevoke(
            namespaceA,
            minimumActiveGeneration: NamespaceGeneration(2)
        )
        let retainedAfterARevoke = await runtime.currentProviderRetainedMemoryCostForTesting()
        let driversAfterARevoke = await runtime.registeredDriverCount()
        let providerACancelCount = await providerA.cancelCount()
        let providerBCancelCount = await providerB.cancelCount()
        XCTAssertEqual(retainedAfterARevoke, 48)
        XCTAssertEqual(driversAfterARevoke, 1)
        XCTAssertEqual(providerACancelCount, 1)
        XCTAssertEqual(providerBCancelCount, 0)

        try await runtime.start(
            handleB,
            output: { _ in },
            schedulingMode: .externalPresentationTicks
        )
        await runtime.cancelAll()
        let retainedAfterCancelAll = await runtime.currentProviderRetainedMemoryCostForTesting()
        let providerBCancelCountAfterAll = await providerB.cancelCount()
        XCTAssertEqual(retainedAfterCancelAll, 0)
        XCTAssertEqual(providerBCancelCountAfterAll, 1)
        _ = handleA
    }

    func testRevocationGenerationFloorRejectsStaleStaticRegistration_W5_PT_122()
        async throws
    {
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 4_096)
        let namespace = SecurityNamespaceID("runtime-generation-floor-static")
        await runtime.namespaceWillRevoke(
            namespace,
            minimumActiveGeneration: NamespaceGeneration(2)
        )
        let staleProvider = RuntimeTestAnimationProvider(image: makeRuntimeImage())

        do {
            _ = try await makeHandle(
                runtime: runtime,
                provider: staleProvider,
                label: "stale-static",
                namespace: namespace,
                generation: NamespaceGeneration(1)
            )
            XCTFail("旧 generation 静态动画不得在撤销后注册")
        } catch let error as AnimationPlaybackRuntimeError {
            XCTAssertEqual(error, .generationRevoked)
        }

        let activeProvider = RuntimeTestAnimationProvider(image: makeRuntimeImage())
        let active = try await makeHandle(
            runtime: runtime,
            provider: activeProvider,
            label: "active-static",
            namespace: namespace,
            generation: NamespaceGeneration(2)
        )
        let driverCount = await runtime.registeredDriverCount()
        XCTAssertEqual(driverCount, 1)
        await active.cancel()
    }

    func testRevocationGenerationFloorRejectsStaleLiveRegistration_W5_PT_123()
        async throws
    {
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 4_096)
        let namespace = SecurityNamespaceID("runtime-generation-floor-live")
        await runtime.namespaceWillRevoke(
            namespace,
            minimumActiveGeneration: NamespaceGeneration(3)
        )
        let incompleteSource = RuntimeLiveSource()
        let incompleteSession = MultipartJPEGLivePlaybackSession(
            stream: incompleteSource.stream,
            decoder: RuntimeLiveDecoder(),
            clock: RuntimeConstantClock()
        )
        do {
            _ = try await runtime.registerLiveSession(
                incompleteSession,
                namespace: namespace
            )
            XCTFail("namespace-bound live 注册必须携带 generation")
        } catch let error as AnimationPlaybackRuntimeError {
            XCTAssertEqual(error, .invalidRegistration)
        }

        let staleSource = RuntimeLiveSource()
        let staleSession = MultipartJPEGLivePlaybackSession(
            stream: staleSource.stream,
            decoder: RuntimeLiveDecoder(),
            clock: RuntimeConstantClock()
        )

        do {
            _ = try await runtime.registerLiveSession(
                staleSession,
                namespace: namespace,
                generation: NamespaceGeneration(2)
            )
            XCTFail("旧 generation live 动画不得在撤销后注册")
        } catch let error as AnimationPlaybackRuntimeError {
            XCTAssertEqual(error, .generationRevoked)
        }

        let activeSource = RuntimeLiveSource()
        let activeSession = MultipartJPEGLivePlaybackSession(
            stream: activeSource.stream,
            decoder: RuntimeLiveDecoder(),
            clock: RuntimeConstantClock()
        )
        let active = try await runtime.registerLiveSession(
            activeSession,
            namespace: namespace,
            generation: NamespaceGeneration(3)
        )
        let liveCount = await runtime.registeredLiveSessionCount()
        XCTAssertEqual(liveCount, 1)
        await active.cancel()
    }

    private func startBlockingStaticDecode(
        stage: DecodeStage,
        path: String
    ) throws -> Task<DecodedImage, any Error> {
        let data = try makePNG(width: 4, height: 4)
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://runtime.example.test/\(path).png")),
            target: TargetPixels(width: 4, height: 4),
            appID: "runtime-shared-decode-admission"
        )
        return Task {
            try await stage.image(
                from: data,
                contentID: ContentID(data: data),
                request: request,
                generation: NamespaceGeneration(0),
                keyDigest: String(repeating: "d", count: 64)
            )
        }
    }

    private func makePredecodeLoopingHandle<Provider: AnimationFrameProvider>(
        runtime: AnimationPlaybackRuntime,
        provider: Provider,
        label: String,
        namespace: SecurityNamespaceID = SecurityNamespaceID("runtime-account"),
        automaticWholeTrackDecodedByteCostUpperBound: Int? = nil,
        providerRetainedByteCost: Int? = nil,
        automaticWholeTrackPredecodePeakByteCost: Int? = nil,
        decodePriority: ImageRequestPriority = .normal
    ) async throws -> AnimationPlaybackHandle {
        let decodeKey = try XCTUnwrap(
            AnimationDecodeKey(
                contentID: ContentID(data: Data("runtime-predecode-\(label)".utf8)),
                target: TargetPixels(width: 16, height: 16),
                contentMode: .fit,
                colorPolicy: .convertToSRGB,
                codecFingerprint: "runtime-provider-v1",
                animationPolicyVersion: 1,
                timingPolicyVersion: 1,
                frameStrategy: .predecodeAll
            )
        )
        let timeline = try AnimationPlaybackTimeline(
            frameDurationsNanoseconds: [10, 10],
            additionalRepeatCount: nil,
            zeroDurationReplacementNanoseconds: 1,
            timingPolicyVersion: 1
        )
        return try await runtime.makeHandle(
            namespace: namespace,
            generation: NamespaceGeneration(1),
            decodeKey: decodeKey,
            timeline: timeline,
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
            reduceMotionEnabled: false,
            provider: provider,
            windowPolicy: AnimationFrameWindowPolicy(normalFrameCount: 1, warningFrameCount: 1),
            maximumPredecodeAllFrameCount: 2,
            automaticWholeTrackDecodedByteCostUpperBound:
                automaticWholeTrackDecodedByteCostUpperBound,
            providerRetainedByteCost:
                providerRetainedByteCost,
            automaticWholeTrackPredecodePeakByteCost:
                automaticWholeTrackPredecodePeakByteCost,
            decodePriority:
                decodePriority,
            clock: RuntimeConstantClock()
        )
    }

    private func makeHandle(
        runtime: AnimationPlaybackRuntime,
        provider: RuntimeTestAnimationProvider,
        label: String,
        namespace: SecurityNamespaceID = SecurityNamespaceID("runtime-account"),
        generation: NamespaceGeneration = NamespaceGeneration(1),
        providerRetainedByteCost: Int? = nil
    ) async throws -> AnimationPlaybackHandle {
        let decodeKey = try XCTUnwrap(
            AnimationDecodeKey(
                contentID: ContentID(data: Data("runtime-\(label)".utf8)),
                target: TargetPixels(width: 16, height: 16),
                contentMode: .fit,
                colorPolicy: .convertToSRGB,
                codecFingerprint: "runtime-provider-v1",
                animationPolicyVersion: 1,
                timingPolicyVersion: 1,
                frameStrategy: .boundedFrameCache
            )
        )
        let timeline = try AnimationPlaybackTimeline(
            frameDurationsNanoseconds: [10],
            additionalRepeatCount: nil,
            zeroDurationReplacementNanoseconds: 1,
            timingPolicyVersion: 1
        )
        return try await runtime.makeHandle(
            namespace: namespace,
            generation: generation,
            decodeKey: decodeKey,
            timeline: timeline,
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .firstFrame),
            reduceMotionEnabled: false,
            provider: provider,
            windowPolicy: AnimationFrameWindowPolicy(
                normalFrameCount: 1,
                warningFrameCount: 1
            ),
            providerRetainedByteCost: providerRetainedByteCost,
            clock: RuntimeConstantClock()
        )
    }
}

private struct RuntimeConstantClock: AnimationPlaybackClock {
    func nowNanoseconds() async -> UInt64 { 0 }
    func sleep(untilNanoseconds _: UInt64) async throws {
        throw CancellationError()
    }
}

private final class RuntimeBlockingDecodeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    var hasEntered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    func enterAndWait() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private struct RuntimeBlockingDecodeCodec: TestImageCodec {
    let gate: RuntimeBlockingDecodeGate

    func probe(data _: Data, limits _: DecodeLimits) throws -> ImageProbe {
        try ImageProbe(pixelWidth: 4, pixelHeight: 4, frameCount: 1, format: .png)
    }

    func decode(
        data _: Data,
        probe _: ImageProbe,
        request _: ImageDecodeRequest,
        limits _: DecodeLimits
    ) throws -> DecodedImage {
        gate.enterAndWait()
        return makeRuntimeImage()
    }
}

private actor RuntimeSuspendingAnimationProvider: AnimationFrameProvider {
    private let image: DecodedImage
    private var calls = 0
    private var cancellations = 0
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(image: DecodedImage) {
        self.image = image
    }

    func frames(in range: Range<Int>) async throws -> [AnimationProviderFrame] {
        calls += 1
        if !isReleased {
            await withCheckedContinuation { continuation in
                if isReleased {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        }
        try Task.checkCancellation()
        return range.map { AnimationProviderFrame(index: $0, image: image) }
    }

    func cancel() {
        cancellations += 1
        release()
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }

    func callCount() -> Int { calls }
    func cancelCount() -> Int { cancellations }
}

private actor RuntimeTestAnimationProvider: AnimationFrameProvider {
    private let image: DecodedImage
    private var calls = 0
    private var cancellations = 0
    private var ranges: [Range<Int>] = []

    init(image: DecodedImage) {
        self.image = image
    }

    func frames(in range: Range<Int>) -> [AnimationProviderFrame] {
        calls += 1
        ranges.append(range)
        return range.map { AnimationProviderFrame(index: $0, image: image) }
    }

    func cancel() {
        cancellations += 1
    }

    func callCount() -> Int { calls }
    func cancelCount() -> Int { cancellations }
    func requestedRanges() -> [Range<Int>] { ranges }
}

private actor RuntimeAnimationRecorder {
    private var outputs: [AnimationPlaybackOutput] = []

    func record(_ output: AnimationPlaybackOutput) {
        outputs.append(output)
    }

    func count() -> Int { outputs.count }
    func hasImage() -> Bool { outputs.last?.image != nil }
}

private func makeRuntimeImage() -> DecodedImage {
    let width = 4
    let height = 4
    let bytesPerRow = width * 4
    let data = Data(repeating: 0x4f, count: bytesPerRow * height)
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

private struct RuntimeLiveSource: Sendable {
    let stream: AsyncThrowingStream<MultipartJPEGPart, any Error>
    private let continuation: AsyncThrowingStream<MultipartJPEGPart, any Error>.Continuation

    init() {
        let pair = AsyncThrowingStream<MultipartJPEGPart, any Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func yield(_ part: MultipartJPEGPart) {
        continuation.yield(part)
    }

    static func part(index: Int) -> MultipartJPEGPart {
        MultipartJPEGPart(
            index: index,
            data: Data([0xff, 0xd8, UInt8(index & 0xff), 0xff, 0xd9])
        )
    }
}

private actor RuntimeLiveDecoder: MultipartJPEGFrameDecoding {
    private var decodedIndices: [Int] = []

    func decode(_ part: MultipartJPEGPart) -> DecodedImage {
        decodedIndices.append(part.index)
        return makeRuntimeImage()
    }

    func count() -> Int { decodedIndices.count }
    func indices() -> [Int] { decodedIndices }
}

private actor RuntimeLiveRecorder {
    private var stored: [MultipartJPEGLiveFrameOutput] = []

    func record(_ output: MultipartJPEGLiveFrameOutput) {
        stored.append(output)
    }

    func count() -> Int { stored.count }
    func outputs() -> [MultipartJPEGLiveFrameOutput] { stored }
}
