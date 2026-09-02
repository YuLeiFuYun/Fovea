import CoreGraphics
import Foundation
import FoveaCore
import FoveaSystem
import ImageCraftCore
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class SystemEncodedAnimationPlaybackTests: XCTestCase {
    func testSystemUsesProductionImageCraftAnimationAdapter_W5_PT_206() async throws {
        let system = try await makeSystem()
        let request = try makeRequest(path: "imagecraft-gif")
        let handle = try await system.makeImageCraftEncodedAnimationHandle(
            for: request,
            zeroDurationReplacementNanoseconds: 10_000_000,
            timingPolicyVersion: 1,
            animationPolicyVersion: 1,
            frameStrategy: .boundedFrameCache,
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
            reduceMotionEnabled: false,
            windowPolicy: AnimationFrameWindowPolicy(normalFrameCount: 2, warningFrameCount: 1),
            clock: SystemEncodedAnimationClock()
        )
        let recorder = SystemEncodedAnimationRecorder()
        try await handle.start { output in
            await recorder.record(output)
        }
        try await waitUntil("production ImageCraft animation publishes") {
            await recorder.count >= 1
        }
        let driverCount = await system.animationRuntime.registeredDriverCount()
        XCTAssertEqual(driverCount, 1)
        await handle.cancel()
        let remainingDriverCount = await system.animationRuntime.registeredDriverCount()
        XCTAssertEqual(remainingDriverCount, 0)
        await system.invalidateAndCancel()
    }

    func testProductionImageCraftAdapterPublishesWindowPeakCost_W5_PT_209() async throws {
        let system = try await makeSystem()
        let request = try makeRequest(path: "imagecraft-owned-gif")
        let preparer = ImageCraftAnimationPlaybackPreparer(
            zeroDurationReplacementNanoseconds: 10_000_000,
            timingPolicyVersion: 1
        )
        let asset = try await system.pipeline.prepareAuthorizedAnimationPlayback(
            for: request,
            using: preparer
        )

        let peakByteCost =
            await asset.provider.frameWindowPredecodePeakByteCostUpperBound(frameCount: 2)
        XCTAssertNotNil(peakByteCost)
        XCTAssertGreaterThan(peakByteCost ?? 0, 0)

        await asset.provider.cancel()
        await system.invalidateAndCancel()
    }

    func testSystemCreatesAuthorizedEncodedAnimationHandle_W5_PT_118() async throws {
        let system = try await makeSystem()
        let request = try makeRequest(path: "success")
        let provider = SystemEncodedAnimationProvider(image: makeSystemEncodedAnimationImage())
        let preparer = SystemEncodedAnimationPreparer(provider: provider)

        let handle = try await makeSystemEncodedAnimationHandle(
            system: system,
            request: request,
            preparer: preparer
        )
        let recorder = SystemEncodedAnimationRecorder()
        try await handle.start { output in
            await recorder.record(output)
        }
        try await waitUntil("system encoded animation publishes") {
            await recorder.count == 1
        }

        let preparedContentID = await preparer.preparedContentID
        let expectedContentID = ContentID(data: SystemEncodedAnimationURLProtocol.body)
        let driverCount = await system.animationRuntime.registeredDriverCount()
        XCTAssertEqual(preparedContentID, expectedContentID)
        XCTAssertEqual(driverCount, 1)

        await handle.cancel()
        let providerCancelCount = await provider.cancelCount
        let remainingDrivers = await system.animationRuntime.registeredDriverCount()
        XCTAssertEqual(providerCancelCount, 1)
        XCTAssertEqual(remainingDrivers, 0)
        await system.invalidateAndCancel()
    }

    func testSystemAutomaticWholeTrackPredecodesWhenUpperBoundFits_W5_PT_166() async throws {
        let system = try await makeSystem()
        let request = try makeRequest(path: "automatic-fit")
        let provider = SystemEncodedAnimationProvider(image: makeSystemEncodedAnimationImage())
        let preparer = SystemEncodedAnimationPreparer(
            provider: provider,
            frameCount: 3,
            wholeTrackDecodedByteCostUpperBound: 192,
            wholeTrackPredecodePeakByteCostUpperBound: 512
        )

        let handle = try await system.makeEncodedAnimationHandle(
            for: request,
            using: preparer,
            animationPolicyVersion: 1,
            frameStrategySelection: .automaticWholeTrack(
                maximumFrameCount: 3,
                maximumPredecodePeakByteCost: 512
            ),
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
            reduceMotionEnabled: false,
            windowPolicy: AnimationFrameWindowPolicy(normalFrameCount: 1, warningFrameCount: 1),
            clock: SystemEncodedAnimationClock()
        )
        try await handle.start(output: { _ in }, schedulingMode: .externalPresentationTicks)

        let ranges = await provider.requestedRanges
        let resident = await system.animationRuntime.currentFrameCount()
        XCTAssertEqual(ranges, [0..<3])
        XCTAssertEqual(resident, 3)

        await handle.cancel()
        await system.invalidateAndCancel()
    }

    func testSystemAutomaticWholeTrackRequiresProviderRetainedBound_W5_PT_190() async throws {
        let system = try await makeSystem()
        let request = try makeRequest(path: "automatic-missing-provider-retained")
        let provider = SystemEncodedAnimationProvider(image: makeSystemEncodedAnimationImage())
        let preparer = SystemEncodedAnimationPreparer(
            provider: provider,
            frameCount: 3,
            wholeTrackDecodedByteCostUpperBound: 192,
            wholeTrackProviderRetainedByteCostUpperBound: nil,
            wholeTrackPredecodePeakByteCostUpperBound: 512
        )

        let handle = try await system.makeEncodedAnimationHandle(
            for: request,
            using: preparer,
            animationPolicyVersion: 1,
            frameStrategySelection: .automaticWholeTrack(
                maximumFrameCount: 3,
                maximumPredecodePeakByteCost: 512
            ),
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
            reduceMotionEnabled: false,
            windowPolicy: AnimationFrameWindowPolicy(normalFrameCount: 1, warningFrameCount: 1),
            clock: SystemEncodedAnimationClock()
        )
        try await handle.start(output: { _ in }, schedulingMode: .externalPresentationTicks)

        let ranges = await provider.requestedRanges
        let retained = await system.animationRuntime.currentProviderRetainedMemoryCostForTesting()
        XCTAssertEqual(ranges, [0..<1])
        XCTAssertEqual(retained, 0)

        await handle.cancel()
        await system.invalidateAndCancel()
    }

    func testSystemAutomaticWholeTrackReservesProviderRetainedBudget_W5_PT_191() async throws {
        let system = try await makeSystem(
            pipelineConfiguration: PipelineConfiguration(
                memoryCostLimit: 1_024,
                maximumDecodeWorkingSetBytes: 4_096
            )
        )
        let request = try makeRequest(path: "automatic-provider-retained-reservation")
        let provider = SystemEncodedAnimationProvider(image: makeSystemEncodedAnimationImage())
        let preparer = SystemEncodedAnimationPreparer(
            provider: provider,
            frameCount: 3,
            wholeTrackDecodedByteCostUpperBound: 192,
            wholeTrackProviderRetainedByteCostUpperBound: 32,
            wholeTrackPredecodePeakByteCostUpperBound: 512
        )

        let handle = try await system.makeEncodedAnimationHandle(
            for: request,
            using: preparer,
            animationPolicyVersion: 1,
            frameStrategySelection: .automaticWholeTrack(
                maximumFrameCount: 3,
                maximumPredecodePeakByteCost: 512
            ),
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
            reduceMotionEnabled: false,
            windowPolicy: AnimationFrameWindowPolicy(normalFrameCount: 1, warningFrameCount: 1),
            clock: SystemEncodedAnimationClock()
        )
        let retainedAfterCreation =
            await system.animationRuntime.currentProviderRetainedMemoryCostForTesting()
        let budgetAfterCreation =
            await system.animationRuntime.currentAnimationResidentBudgetCostForTesting()
        XCTAssertEqual(retainedAfterCreation, 32)
        XCTAssertEqual(budgetAfterCreation, 32)

        try await handle.start(output: { _ in }, schedulingMode: .externalPresentationTicks)
        let ranges = await provider.requestedRanges
        XCTAssertEqual(ranges, [0..<3])

        await handle.cancel()
        let retainedAfterCancel =
            await system.animationRuntime.currentProviderRetainedMemoryCostForTesting()
        XCTAssertEqual(retainedAfterCancel, 0)
        await system.invalidateAndCancel()
    }

    func testSystemAutomaticPeakUsesDecodeWorkingSetBudgetNotFrameCacheBudget_W5_PT_179()
        async throws
    {
        let system = try await makeSystem(
            pipelineConfiguration: PipelineConfiguration(
                memoryCostLimit: 512 * 1024,
                maximumDecodeWorkingSetBytes: 2 * 1024 * 1024
            )
        )
        let request = try makeRequest(path: "automatic-decode-working-set-budget")
        let provider = SystemEncodedAnimationProvider(image: makeSystemEncodedAnimationImage())
        let preparer = SystemEncodedAnimationPreparer(
            provider: provider,
            frameCount: 3,
            wholeTrackDecodedByteCostUpperBound: 192,
            wholeTrackPredecodePeakByteCostUpperBound: 1024 * 1024
        )

        let handle = try await system.makeEncodedAnimationHandle(
            for: request,
            using: preparer,
            animationPolicyVersion: 1,
            frameStrategySelection: .automaticWholeTrack(
                maximumFrameCount: 3,
                maximumPredecodePeakByteCost: 1024 * 1024
            ),
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
            reduceMotionEnabled: false,
            windowPolicy: AnimationFrameWindowPolicy(normalFrameCount: 1, warningFrameCount: 1),
            clock: SystemEncodedAnimationClock()
        )
        try await handle.start(output: { _ in }, schedulingMode: .externalPresentationTicks)
        let requestedRanges = await provider.requestedRanges
        XCTAssertEqual(requestedRanges, [0..<3])

        var snapshot = await handle.driver.fullyResidentFramesSnapshotForCompositor()
        XCTAssertEqual(snapshot?.frames.count, 3)
        snapshot = nil
        await handle.cancel()
        await system.invalidateAndCancel()
    }

    func testSystemStaticDecodeAndAutomaticAnimationShareDecodeWorkingSetPool_W5_PT_180()
        async throws
    {
        let gate = SystemBlockingDecodeGate()
        let system = try await makeSystem(
            pipelineConfiguration: PipelineConfiguration(
                maximumConcurrentDecodes: 2,
                maximumDecodeWorkingSetBytes: 64 * 1024,
                maximumQueuedDecodes: 8
            ),
            codec: SystemBlockingDecodeCodec(gate: gate)
        )
        let animationRequest = try makeRequest(path: "shared-global-animation")
        let provider = SystemEncodedAnimationProvider(image: makeSystemEncodedAnimationImage())
        let preparer = SystemEncodedAnimationPreparer(
            provider: provider,
            frameCount: 2,
            wholeTrackDecodedByteCostUpperBound: 128,
            wholeTrackPredecodePeakByteCostUpperBound: 64 * 1024
        )
        let handle = try await system.makeEncodedAnimationHandle(
            for: animationRequest,
            using: preparer,
            animationPolicyVersion: 1,
            frameStrategySelection: .automaticWholeTrack(
                maximumFrameCount: 2,
                maximumPredecodePeakByteCost: 64 * 1024
            ),
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
            reduceMotionEnabled: false,
            windowPolicy: AnimationFrameWindowPolicy(normalFrameCount: 1, warningFrameCount: 1),
            clock: SystemEncodedAnimationClock()
        )

        let staticRequest = try makeRequest(path: "shared-global-static")
        let staticDecode = Task { try await system.pipeline.image(for: staticRequest) }
        try await waitUntil("system static decode enters blocking codec") {
            gate.hasEntered
        }

        let animationStart = Task {
            try await handle.start(
                output: { _ in },
                schedulingMode: .externalPresentationTicks
            )
        }
        for _ in 0..<50 { await Task.yield() }
        let rangesWhileStaticDecodeRuns = await provider.requestedRanges
        XCTAssertEqual(rangesWhileStaticDecodeRuns, [])

        gate.release()
        _ = try await staticDecode.value
        try await animationStart.value
        let rangesAfterStaticDecodeRelease = await provider.requestedRanges
        XCTAssertEqual(rangesAfterStaticDecodeRelease, [0..<2])

        var snapshot = await handle.driver.fullyResidentFramesSnapshotForCompositor()
        XCTAssertEqual(snapshot?.frames.count, 2)
        snapshot = nil
        await handle.cancel()
        await system.invalidateAndCancel()
    }

    func testSystemAutomaticWholeTrackFallsBackWithoutDecodedCostBound_W5_PT_167() async throws {
        let system = try await makeSystem()
        let request = try makeRequest(path: "automatic-missing-bound")
        let provider = SystemEncodedAnimationProvider(image: makeSystemEncodedAnimationImage())
        let preparer = SystemEncodedAnimationPreparer(
            provider: provider,
            frameCount: 3,
            wholeTrackPredecodePeakByteCostUpperBound: 512
        )

        let handle = try await system.makeEncodedAnimationHandle(
            for: request,
            using: preparer,
            animationPolicyVersion: 1,
            frameStrategySelection: .automaticWholeTrack(
                maximumFrameCount: 3,
                maximumPredecodePeakByteCost: 512
            ),
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
            reduceMotionEnabled: false,
            windowPolicy: AnimationFrameWindowPolicy(normalFrameCount: 1, warningFrameCount: 1),
            clock: SystemEncodedAnimationClock()
        )
        try await handle.start(output: { _ in }, schedulingMode: .externalPresentationTicks)

        let ranges = await provider.requestedRanges
        let resident = await system.animationRuntime.currentFrameCount()
        XCTAssertEqual(ranges, [0..<1])
        XCTAssertEqual(resident, 1)

        await handle.cancel()
        await system.invalidateAndCancel()
    }

    func testSystemAutomaticWholeTrackFallsBackWhenCallerByteCapIsTooSmall_W5_PT_168()
        async throws
    {
        let system = try await makeSystem()
        let request = try makeRequest(path: "automatic-byte-cap")
        let provider = SystemEncodedAnimationProvider(image: makeSystemEncodedAnimationImage())
        let preparer = SystemEncodedAnimationPreparer(
            provider: provider,
            frameCount: 3,
            wholeTrackDecodedByteCostUpperBound: 192,
            wholeTrackPredecodePeakByteCostUpperBound: 512
        )

        let handle = try await system.makeEncodedAnimationHandle(
            for: request,
            using: preparer,
            animationPolicyVersion: 1,
            frameStrategySelection: .automaticWholeTrack(
                maximumFrameCount: 3,
                maximumPredecodePeakByteCost: 512,
                maximumDecodedByteCost: 128
            ),
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
            reduceMotionEnabled: false,
            windowPolicy: AnimationFrameWindowPolicy(normalFrameCount: 1, warningFrameCount: 1),
            clock: SystemEncodedAnimationClock()
        )
        try await handle.start(output: { _ in }, schedulingMode: .externalPresentationTicks)
        let requestedRanges = await provider.requestedRanges
        let residentFrameCount = await system.animationRuntime.currentFrameCount()
        XCTAssertEqual(requestedRanges, [0..<1])
        XCTAssertEqual(residentFrameCount, 1)

        await handle.cancel()
        await system.invalidateAndCancel()
    }

    func testSystemAutomaticFallbackStillReservesKnownProviderRetainedCost_W5_PT_192()
        async throws
    {
        let system = try await makeSystem(
            pipelineConfiguration: PipelineConfiguration(memoryCostLimit: 1_024)
        )
        let request = try makeRequest(path: "automatic-fallback-provider-retained")
        let provider = SystemEncodedAnimationProvider(image: makeSystemEncodedAnimationImage())
        let preparer = SystemEncodedAnimationPreparer(
            provider: provider,
            frameCount: 3,
            wholeTrackDecodedByteCostUpperBound: 192,
            wholeTrackProviderRetainedByteCostUpperBound: 32,
            wholeTrackPredecodePeakByteCostUpperBound: 512
        )

        let handle = try await system.makeEncodedAnimationHandle(
            for: request,
            using: preparer,
            animationPolicyVersion: 1,
            frameStrategySelection: .automaticWholeTrack(
                maximumFrameCount: 3,
                maximumPredecodePeakByteCost: 512,
                maximumDecodedByteCost: 128
            ),
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
            reduceMotionEnabled: false,
            windowPolicy: AnimationFrameWindowPolicy(normalFrameCount: 1, warningFrameCount: 1),
            clock: SystemEncodedAnimationClock()
        )
        let retainedAfterCreation =
            await system.animationRuntime.currentProviderRetainedMemoryCostForTesting()
        XCTAssertEqual(retainedAfterCreation, 32)

        try await handle.start(output: { _ in }, schedulingMode: .externalPresentationTicks)
        let rangesAfterStart = await provider.requestedRanges
        XCTAssertEqual(rangesAfterStart, [0..<1])

        await handle.cancel()
        let retainedAfterCancel =
            await system.animationRuntime.currentProviderRetainedMemoryCostForTesting()
        XCTAssertEqual(retainedAfterCancel, 0)
        await system.invalidateAndCancel()
    }

    func testSystemFixedBoundedHandleReservesProviderRetainedWithoutWholeTrackProof_W5_PT_193()
        async throws
    {
        let system = try await makeSystem(
            pipelineConfiguration: PipelineConfiguration(memoryCostLimit: 1_024)
        )
        let request = try makeRequest(path: "fixed-provider-retained")
        let provider = SystemEncodedAnimationProvider(image: makeSystemEncodedAnimationImage())
        let preparer = SystemEncodedAnimationPreparer(
            provider: provider,
            frameCount: 3,
            wholeTrackDecodedByteCostUpperBound: nil,
            wholeTrackProviderRetainedByteCostUpperBound: 32,
            wholeTrackPredecodePeakByteCostUpperBound: nil
        )

        let handle = try await makeSystemEncodedAnimationHandle(
            system: system,
            request: request,
            preparer: preparer
        )
        let retainedAfterCreation =
            await system.animationRuntime.currentProviderRetainedMemoryCostForTesting()
        XCTAssertEqual(retainedAfterCreation, 32)

        try await handle.start(output: { _ in }, schedulingMode: .externalPresentationTicks)
        let rangesAfterStart = await provider.requestedRanges
        XCTAssertEqual(rangesAfterStart, [0..<1])

        await handle.cancel()
        let retainedAfterCancel =
            await system.animationRuntime.currentProviderRetainedMemoryCostForTesting()
        XCTAssertEqual(retainedAfterCancel, 0)
        await system.invalidateAndCancel()
    }

    func testSystemAutomaticWholeTrackFallsBackWhenPredecodePeakExceedsCap_W5_PT_173()
        async throws
    {
        let system = try await makeSystem()
        let request = try makeRequest(path: "automatic-peak-cap")
        let provider = SystemEncodedAnimationProvider(image: makeSystemEncodedAnimationImage())
        let preparer = SystemEncodedAnimationPreparer(
            provider: provider,
            frameCount: 3,
            wholeTrackDecodedByteCostUpperBound: 192,
            wholeTrackPredecodePeakByteCostUpperBound: 1_024
        )

        let handle = try await system.makeEncodedAnimationHandle(
            for: request,
            using: preparer,
            animationPolicyVersion: 1,
            frameStrategySelection: .automaticWholeTrack(
                maximumFrameCount: 3,
                maximumPredecodePeakByteCost: 512
            ),
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
            reduceMotionEnabled: false,
            windowPolicy: AnimationFrameWindowPolicy(normalFrameCount: 1, warningFrameCount: 1),
            clock: SystemEncodedAnimationClock()
        )
        try await handle.start(output: { _ in }, schedulingMode: .externalPresentationTicks)
        let requestedRanges = await provider.requestedRanges
        let residentFrameCount = await system.animationRuntime.currentFrameCount()
        XCTAssertEqual(requestedRanges, [0..<1])
        XCTAssertEqual(residentFrameCount, 1)

        await handle.cancel()
        await system.invalidateAndCancel()
    }

    func testSystemAutomaticWholeTrackFallsBackForFirstFramePlayback_W5_PT_169() async throws {
        let system = try await makeSystem()
        let request = try makeRequest(path: "automatic-first-frame")
        let provider = SystemEncodedAnimationProvider(image: makeSystemEncodedAnimationImage())
        let preparer = SystemEncodedAnimationPreparer(
            provider: provider,
            frameCount: 3,
            wholeTrackDecodedByteCostUpperBound: 192,
            wholeTrackPredecodePeakByteCostUpperBound: 512
        )

        let handle = try await system.makeEncodedAnimationHandle(
            for: request,
            using: preparer,
            animationPolicyVersion: 1,
            frameStrategySelection: .automaticWholeTrack(
                maximumFrameCount: 3,
                maximumPredecodePeakByteCost: 512
            ),
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .firstFrame),
            reduceMotionEnabled: false,
            windowPolicy: AnimationFrameWindowPolicy(normalFrameCount: 1, warningFrameCount: 1),
            clock: SystemEncodedAnimationClock()
        )
        try await handle.start(output: { _ in }, schedulingMode: .externalPresentationTicks)
        let requestedRanges = await provider.requestedRanges
        let residentFrameCount = await system.animationRuntime.currentFrameCount()
        XCTAssertEqual(requestedRanges, [0..<1])
        XCTAssertEqual(residentFrameCount, 1)

        await handle.cancel()
        await system.invalidateAndCancel()
    }

    func testSystemAutomaticWholeTrackFallsBackUnderWarningPressure_W5_PT_170() async throws {
        let system = try await makeSystem()
        _ = await system.animationRuntime.applyMemoryPressure(.warning)
        let request = try makeRequest(path: "automatic-warning")
        let provider = SystemEncodedAnimationProvider(image: makeSystemEncodedAnimationImage())
        let preparer = SystemEncodedAnimationPreparer(
            provider: provider,
            frameCount: 3,
            wholeTrackDecodedByteCostUpperBound: 192,
            wholeTrackPredecodePeakByteCostUpperBound: 512
        )

        let handle = try await system.makeEncodedAnimationHandle(
            for: request,
            using: preparer,
            animationPolicyVersion: 1,
            frameStrategySelection: .automaticWholeTrack(
                maximumFrameCount: 3,
                maximumPredecodePeakByteCost: 512
            ),
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
            reduceMotionEnabled: false,
            windowPolicy: AnimationFrameWindowPolicy(normalFrameCount: 3, warningFrameCount: 1),
            clock: SystemEncodedAnimationClock()
        )
        try await handle.start(output: { _ in }, schedulingMode: .externalPresentationTicks)
        let requestedRanges = await provider.requestedRanges
        let residentFrameCount = await system.animationRuntime.currentFrameCount()
        XCTAssertEqual(requestedRanges, [0..<1])
        XCTAssertEqual(residentFrameCount, 1)

        await handle.cancel()
        await system.invalidateAndCancel()
    }

    func testSystemAutomaticWholeTrackUsesImageRequestPriority_W5_PT_182() async throws {
        let system = try await makeSystem(
            pipelineConfiguration: PipelineConfiguration(
                maximumConcurrentDecodes: 2,
                maximumDecodeWorkingSetBytes: 4_096,
                maximumQueuedDecodes: 8
            )
        )
        let blockerProvider = SystemSuspendingAnimationProvider(
            image: makeSystemEncodedAnimationImage()
        )
        let lowProvider = SystemSuspendingAnimationProvider(
            image: makeSystemEncodedAnimationImage()
        )
        let highProvider = SystemSuspendingAnimationProvider(
            image: makeSystemEncodedAnimationImage()
        )
        let blocker = try await makeSystemAutomaticHandle(
            system: system,
            request: try makeRequest(path: "priority-blocker", priority: .normal),
            provider: blockerProvider,
            peakByteCost: 4_096
        )
        let low = try await makeSystemAutomaticHandle(
            system: system,
            request: try makeRequest(path: "priority-low", priority: .low),
            provider: lowProvider,
            peakByteCost: 4_096
        )
        let high = try await makeSystemAutomaticHandle(
            system: system,
            request: try makeRequest(path: "priority-high", priority: .userInitiated),
            provider: highProvider,
            peakByteCost: 4_096
        )

        let blockerStart = Task {
            try await blocker.start(
                output: { _ in },
                schedulingMode: .externalPresentationTicks
            )
        }
        try await waitUntil("system priority blocker enters provider") {
            await blockerProvider.callCount() == 1
        }
        let lowStart = Task {
            try await low.start(
                output: { _ in },
                schedulingMode: .externalPresentationTicks
            )
        }
        let highStart = Task {
            try await high.start(
                output: { _ in },
                schedulingMode: .externalPresentationTicks
            )
        }
        try await waitUntil("system priority requests enter shared peak queue") {
            await system.animationRuntime.automaticWholeTrackPredecodePeakQueuedCountForTesting()
                == 2
        }
        let lowCallsWhileBlocked = await lowProvider.callCount()
        let highCallsWhileBlocked = await highProvider.callCount()
        XCTAssertEqual(lowCallsWhileBlocked, 0)
        XCTAssertEqual(highCallsWhileBlocked, 0)

        await blockerProvider.release()
        try await blockerStart.value
        try await waitUntil("system request priority schedules high before low") {
            await highProvider.callCount() == 1
        }
        let lowCallsWhileHighRuns = await lowProvider.callCount()
        XCTAssertEqual(lowCallsWhileHighRuns, 0)

        await highProvider.release()
        try await highStart.value
        try await waitUntil("system low priority follows high") {
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
        await system.invalidateAndCancel()
    }

    func testSystemRejectsGenerationRevokedDuringPreparation_W5_PT_119() async throws {
        let system = try await makeSystem()
        let request = try makeRequest(path: "revoke")
        let provider = SystemEncodedAnimationProvider(image: makeSystemEncodedAnimationImage())
        let preparer = SystemEncodedAnimationPreparer(provider: provider, startsSuspended: true)
        let creation = Task {
            try await makeSystemEncodedAnimationHandle(
                system: system,
                request: request,
                preparer: preparer
            )
        }
        try await waitUntil("encoded animation preparer starts") {
            await preparer.hasStarted
        }

        try await system.pipeline.revoke(namespace: request.namespace)
        await preparer.release()

        do {
            _ = try await creation.value
            XCTFail("preparation 中撤销的 generation 不得创建 handle")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .namespaceRevoked)
            XCTAssertEqual(failure.stage, .revocation)
        }
        let providerCancelCount = await provider.cancelCount
        let driverCount = await system.animationRuntime.registeredDriverCount()
        XCTAssertEqual(providerCancelCount, 1)
        XCTAssertEqual(driverCount, 0)
        await system.invalidateAndCancel()
    }

    func testSystemCancelsProviderWhenRuntimeRejectsPreparedAsset_W5_PT_120() async throws {
        let system = try await makeSystem()
        let request = try makeRequest(path: "invalid-codec")
        let provider = SystemEncodedAnimationProvider(image: makeSystemEncodedAnimationImage())
        let preparer = SystemEncodedAnimationPreparer(
            provider: provider,
            codecFingerprint: ""
        )

        do {
            _ = try await makeSystemEncodedAnimationHandle(
                system: system,
                request: request,
                preparer: preparer
            )
            XCTFail("无效 codec identity 不得创建 handle")
        } catch let error as AnimationPlaybackRuntimeError {
            XCTAssertEqual(error, .invalidAuthorizedAsset)
        }
        let providerCancelCount = await provider.cancelCount
        let driverCount = await system.animationRuntime.registeredDriverCount()
        XCTAssertEqual(providerCancelCount, 1)
        XCTAssertEqual(driverCount, 0)
        await system.invalidateAndCancel()
    }

    func testSystemCancellationDuringPreparationReleasesProvider_W5_PT_121() async throws {
        let system = try await makeSystem()
        let request = try makeRequest(path: "cancel")
        let provider = SystemEncodedAnimationProvider(image: makeSystemEncodedAnimationImage())
        let preparer = SystemEncodedAnimationPreparer(provider: provider, startsSuspended: true)
        let creation = Task {
            try await makeSystemEncodedAnimationHandle(
                system: system,
                request: request,
                preparer: preparer
            )
        }
        try await waitUntil("encoded animation cancellation reaches preparer") {
            await preparer.hasStarted
        }

        creation.cancel()
        await preparer.release()

        do {
            _ = try await creation.value
            XCTFail("取消的 preparation 不得创建 handle")
        } catch is CancellationError {
            // 预期取消。
        }
        let providerCancelCount = await provider.cancelCount
        let driverCount = await system.animationRuntime.registeredDriverCount()
        XCTAssertEqual(providerCancelCount, 1)
        XCTAssertEqual(driverCount, 0)
        await system.invalidateAndCancel()
    }

    private func makeSystem(
        pipelineConfiguration: PipelineConfiguration = PipelineConfiguration(),
        codec: (any ImageCodec)? = nil
    ) async throws -> FoveaSystemPipeline {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SystemEncodedAnimationURLProtocol.self]
        if let codec {
            return try await FoveaSystemPipeline.open(
                cacheRoot: try makeTemporaryDirectory("system-encoded-animation"),
                configuration: pipelineConfiguration,
                profileAccessPolicy: .publicOnly,
                automaticallyPurgesMemoryOnPressure: false,
                sessionConfiguration: sessionConfiguration,
                codec: codec
            )
        }
        return try await FoveaSystemPipeline.open(
            cacheRoot: try makeTemporaryDirectory("system-encoded-animation"),
            configuration: pipelineConfiguration,
            profileAccessPolicy: .publicOnly,
            automaticallyPurgesMemoryOnPressure: false,
            sessionConfiguration: sessionConfiguration
        )
    }

    private func makeRequest(
        path: String,
        priority: ImageRequestPriority = .normal
    ) throws -> ImageRequest {
        try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://system-animation.example.test/\(path)")),
            target: TargetPixels(width: 16, height: 16),
            appID: "system-encoded-animation",
            priority: priority
        )
    }

    private func makeSystemAutomaticHandle<Provider: AnimationFrameProvider>(
        system: FoveaSystemPipeline,
        request: ImageRequest,
        provider: Provider,
        peakByteCost: Int
    ) async throws -> AnimationPlaybackHandle {
        let preparer = SystemEncodedAnimationPreparer(
            provider: provider,
            frameCount: 2,
            wholeTrackDecodedByteCostUpperBound: 128,
            wholeTrackPredecodePeakByteCostUpperBound: peakByteCost
        )
        return try await system.makeEncodedAnimationHandle(
            for: request,
            using: preparer,
            animationPolicyVersion: 1,
            frameStrategySelection: .automaticWholeTrack(
                maximumFrameCount: 2,
                maximumPredecodePeakByteCost: peakByteCost
            ),
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
            reduceMotionEnabled: false,
            windowPolicy: AnimationFrameWindowPolicy(normalFrameCount: 1, warningFrameCount: 1),
            clock: SystemEncodedAnimationClock()
        )
    }
}

private func makeSystemEncodedAnimationHandle(
    system: FoveaSystemPipeline,
    request: ImageRequest,
    preparer: SystemEncodedAnimationPreparer
) async throws -> AnimationPlaybackHandle {
    try await system.makeEncodedAnimationHandle(
        for: request,
        using: preparer,
        animationPolicyVersion: 1,
        frameStrategy: .boundedFrameCache,
        playbackPolicy: AnimationPlaybackPolicy(requestedMode: .firstFrame),
        reduceMotionEnabled: false,
        windowPolicy: AnimationFrameWindowPolicy(
            normalFrameCount: 1,
            warningFrameCount: 1
        ),
        clock: SystemEncodedAnimationClock()
    )
}

private final class SystemBlockingDecodeGate: @unchecked Sendable {
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

private struct SystemBlockingDecodeCodec: TestImageCodec {
    let gate: SystemBlockingDecodeGate

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
        return makeSystemEncodedAnimationImage()
    }
}

private actor SystemEncodedAnimationPreparer: EncodedAnimationPlaybackPreparing {
    private let provider: any AnimationFrameProvider
    private let codecFingerprint: String
    private let startsSuspended: Bool
    private let frameCount: Int
    private let wholeTrackDecodedByteCostUpperBound: Int?
    private let wholeTrackProviderRetainedByteCostUpperBound: Int?
    private let wholeTrackPredecodePeakByteCostUpperBound: Int?
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasStarted = false
    private(set) var preparedContentID: ContentID?

    init(
        provider: any AnimationFrameProvider,
        codecFingerprint: String = "system-encoded-animation-test-v1",
        startsSuspended: Bool = false,
        frameCount: Int = 1,
        wholeTrackDecodedByteCostUpperBound: Int? = nil,
        wholeTrackProviderRetainedByteCostUpperBound: Int? = 0,
        wholeTrackPredecodePeakByteCostUpperBound: Int? = nil
    ) {
        self.provider = provider
        self.codecFingerprint = codecFingerprint
        self.startsSuspended = startsSuspended
        self.frameCount = max(1, frameCount)
        self.wholeTrackDecodedByteCostUpperBound = wholeTrackDecodedByteCostUpperBound
        self.wholeTrackProviderRetainedByteCostUpperBound =
            wholeTrackProviderRetainedByteCostUpperBound
        self.wholeTrackPredecodePeakByteCostUpperBound =
            wholeTrackPredecodePeakByteCostUpperBound
    }

    func prepareAnimation(
        source: AuthorizedEncodedData,
        request _: ImageRequest
    ) async throws -> PreparedAnimationPlaybackAsset {
        hasStarted = true
        preparedContentID = source.contentID
        if startsSuspended {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return PreparedAnimationPlaybackAsset(
            timeline: try AnimationPlaybackTimeline(
                frameDurationsNanoseconds: [UInt64](repeating: 10, count: frameCount),
                additionalRepeatCount: nil,
                zeroDurationReplacementNanoseconds: 1,
                timingPolicyVersion: 1
            ),
            codecFingerprint: codecFingerprint,
            provider: provider,
            wholeTrackDecodedByteCostUpperBound: wholeTrackDecodedByteCostUpperBound,
            wholeTrackProviderRetainedByteCostUpperBound:
                wholeTrackProviderRetainedByteCostUpperBound,
            wholeTrackPredecodePeakByteCostUpperBound:
                wholeTrackPredecodePeakByteCostUpperBound
        )
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SystemSuspendingAnimationProvider: AnimationFrameProvider {
    private let image: DecodedImage
    private var calls = 0
    private var cancellations = 0
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(image: DecodedImage) {
        self.image = image
    }

    func frames(in range: Range<Int>) async throws -> [AnimationProviderFrame] {
        calls += 1
        if !released {
            await withCheckedContinuation { continuation in
                if released {
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
        released = true
        continuation?.resume()
        continuation = nil
    }

    func callCount() -> Int { calls }
    func cancelCount() -> Int { cancellations }
}

private actor SystemEncodedAnimationProvider: AnimationFrameProvider {
    private let image: DecodedImage
    private var cancellations = 0
    private var ranges: [Range<Int>] = []

    init(image: DecodedImage) {
        self.image = image
    }

    func frames(in range: Range<Int>) -> [AnimationProviderFrame] {
        ranges.append(range)
        return range.map { AnimationProviderFrame(index: $0, image: image) }
    }

    func cancel() {
        cancellations += 1
    }

    var cancelCount: Int { cancellations }
    var requestedRanges: [Range<Int>] { ranges }
}

private actor SystemEncodedAnimationRecorder {
    private var outputs: [AnimationPlaybackOutput] = []

    func record(_ output: AnimationPlaybackOutput) {
        outputs.append(output)
    }

    var count: Int { outputs.count }
}

private struct SystemEncodedAnimationClock: AnimationPlaybackClock {
    func nowNanoseconds() async -> UInt64 { 0 }
    func sleep(untilNanoseconds _: UInt64) async throws { throw CancellationError() }
}

private final class SystemEncodedAnimationURLProtocol: URLProtocol {
    static let body = Data("authorized-encoded-animation-body".utf8)
    static let imageCraftGIFBody = Data(
        base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA"
            + "h+QQBAAAAACwAAAAAAQABAAACAUQAOw=="
    )!
    static let imageCraftOwnedGIFBody = makeSystemEncodedOwnedGIF()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "system-animation.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let encodedBody: Data
        let contentType: String
        switch url.path {
        case "/imagecraft-gif":
            encodedBody = Self.imageCraftGIFBody
            contentType = "image/gif"
        case "/imagecraft-owned-gif":
            encodedBody = Self.imageCraftOwnedGIFBody
            contentType = "image/gif"
        default:
            encodedBody = Self.body
            contentType = "image/png"
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": contentType,
                "Content-Length": String(encodedBody.count),
                "Cache-Control": "no-store",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: encodedBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeSystemEncodedAnimationImage() -> DecodedImage {
    let width = 4
    let height = 4
    let bytesPerRow = width * 4
    let data = Data(repeating: 0x6b, count: bytesPerRow * height)
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

private func makeSystemEncodedOwnedGIF() -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        data,
        UTType.gif.identifier as CFString,
        2,
        nil
    )!
    CGImageDestinationSetProperties(
        destination,
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 3]] as CFDictionary
    )
    for (image, delay) in [
        (makeSystemEncodedSolidImage(red: 255, blue: 0), 0.1),
        (makeSystemEncodedSolidImage(red: 0, blue: 255), 0.2),
    ] {
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ]
            ] as CFDictionary
        )
    }
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}

private func makeSystemEncodedSolidImage(red: UInt8, blue: UInt8) -> CGImage {
    let width = 4
    let height = 4
    let bytesPerRow = width * 4
    var bytes: [UInt8] = []
    bytes.reserveCapacity(bytesPerRow * height)
    for _ in 0..<(width * height) {
        bytes.append(contentsOf: [red, 0, blue, 255])
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
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
}
