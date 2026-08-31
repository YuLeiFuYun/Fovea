import CoreGraphics
import Foundation
import FoveaCore
import ImageCraftCore
import XCTest

final class AnimationPlaybackSessionTests: XCTestCase {
    func testSessionPlansOnlyMissingFramesInsideBoundedWindow_W5_PT_024() async throws {
        let fixture = try makeFixture(frameCount: 6)
        let session = fixture.session
        await session.start(at: 0)

        let initial = try await session.work(at: 0)
        XCTAssertEqual(initial.decodePlan.ranges, [0..<4])
        try await session.storeFrame(makeImage(), at: 0)
        try await session.storeFrame(makeImage(), at: 2)

        let missing = try await session.work(at: 0)
        XCTAssertEqual(missing.decodePlan.ranges, [1..<2, 3..<4])
        XCTAssertEqual(missing.decodePlan.frameCount, 2)
    }

    func testObservedFrameBytesClampUpcomingWindowToCacheCapacity_W5_PT_133() async throws {
        let memory = AnimationFrameMemory(costLimit: 128)
        let decodeKey = try XCTUnwrap(makeDecodeKey())
        let session = makeSession(
            memory: memory,
            decodeKey: decodeKey,
            timeline: try makeTimeline(frameCount: 6)
        )
        await session.start(at: 0)

        let initial = try await session.work(at: 0)
        XCTAssertEqual(initial.decodePlan.frameCount, 4)
        let image = makeImage()
        XCTAssertEqual(image.estimatedByteCost, 64)
        try await session.storeFrame(image, at: 0)
        try await session.seek(toFrame: 1, at: 0)

        let learned = try await session.work(at: 0)
        XCTAssertEqual(learned.decodePlan.ranges, [1..<3])
        XCTAssertEqual(learned.decodePlan.frameCount, 2)
    }

    func testOffscreenAndBackgroundOverlapWithoutClockCatchUp_W5_PT_025() async throws {
        let fixture = try makeFixture(frameCount: 4)
        let session = fixture.session
        await session.start(at: 100)
        try await session.setVisible(false, at: 105)
        try await session.setApplicationActive(false, at: 110)

        let frozen = try await session.work(at: 1_000)
        XCTAssertEqual(frozen.decision.frameIndex, 0)
        XCTAssertTrue(frozen.decodePlan.ranges.isEmpty)
        XCTAssertEqual(
            frozen.decision.pauseReasons,
            [.offscreen, .applicationBackground]
        )

        try await session.setVisible(true, at: 1_010)
        let stillBackgrounded = try await session.work(at: 2_000)
        XCTAssertTrue(stillBackgrounded.decodePlan.ranges.isEmpty)
        try await session.setApplicationActive(true, at: 2_000)
        let resumed = try await session.work(at: 2_005)
        XCTAssertEqual(resumed.decision.frameIndex, 1)
        XCTAssertEqual(resumed.decision.droppedFrameCount, 0)
        XCTAssertFalse(resumed.decodePlan.ranges.isEmpty)
    }

    func testMemoryPressureShrinksPurgesFreezesAndResumes_W5_PT_026() async throws {
        let fixture = try makeFixture(frameCount: 6)
        let session = fixture.session
        await session.start(at: 0)
        try await session.storeFrame(makeImage(), at: 0)
        try await session.storeFrame(makeImage(), at: 1)

        let warningRemoval = try await session.applyMemoryPressure(.warning, at: 0)
        XCTAssertEqual(warningRemoval.itemCount, 0)
        let fullyCachedWarningWindow = try await session.work(at: 0)
        XCTAssertEqual(fullyCachedWarningWindow.decodePlan.frameCount, 0)
        try await session.storeFrame(makeImage(), at: 2)
        let warningWork = try await session.work(at: 0)
        XCTAssertEqual(warningWork.decodePlan.ranges, [])

        let criticalRemoval = try await session.applyMemoryPressure(.critical, at: 1)
        XCTAssertEqual(criticalRemoval.itemCount, 3)
        XCTAssertEqual(criticalRemoval.costBytes, 3 * makeImage().estimatedByteCost)
        let frozen = try await session.work(at: 100)
        XCTAssertTrue(frozen.decodePlan.ranges.isEmpty)
        XCTAssertEqual(frozen.decision.pauseReasons, [.memoryPressure])

        _ = try await session.applyMemoryPressure(.normal, at: 100)
        let resumed = try await session.work(at: 109)
        XCTAssertEqual(resumed.decision.frameIndex, 1)
        XCTAssertEqual(resumed.decodePlan.frameCount, 4)
    }

    func testSessionsShareFramesButKeepIndependentPlaybackClocks_W5_PT_027() async throws {
        let memory = AnimationFrameMemory(costLimit: 4_096)
        let decodeKey = try XCTUnwrap(makeDecodeKey())
        let timeline = try makeTimeline(frameCount: 4)
        let first = makeSession(
            memory: memory,
            decodeKey: decodeKey,
            timeline: timeline
        )
        let second = makeSession(
            memory: memory,
            decodeKey: decodeKey,
            timeline: timeline
        )
        await first.start(at: 0)
        await second.start(at: 1_000)
        let image = makeImage()
        try await first.storeFrame(image, at: 1)

        let sharedFrame = try await second.cachedFrame(at: 1)
        let firstDecision = try await first.work(at: 25)
        let secondDecision = try await second.work(at: 1_005)
        XCTAssertNotNil(sharedFrame)
        XCTAssertEqual(firstDecision.decision.frameIndex, 2)
        XCTAssertEqual(secondDecision.decision.frameIndex, 0)
    }

    func testPredecodeAllRequiresExplicitWholeTrackAdmission_W5_PT_028() async throws {
        let memory = AnimationFrameMemory(costLimit: 4_096)
        let decodeKey = try XCTUnwrap(makeDecodeKey(strategy: .predecodeAll))
        let timeline = try makeTimeline(frameCount: 6)
        let denied = makeSession(
            memory: memory,
            decodeKey: decodeKey,
            timeline: timeline,
            maximumPredecodeAllFrameCount: 0
        )
        let admitted = makeSession(
            memory: memory,
            decodeKey: decodeKey,
            timeline: timeline,
            maximumPredecodeAllFrameCount: 6
        )
        await denied.start(at: 0)
        await admitted.start(at: 0)

        let deniedWork = try await denied.work(at: 0)
        let admittedWork = try await admitted.work(at: 0)
        XCTAssertEqual(deniedWork.decodePlan.frameCount, 4)
        XCTAssertEqual(admittedWork.decodePlan.frameCount, 6)
    }

    func testWholeTrackCompositorSnapshotRequiresFullyResidentAdmittedPredecodeAll_W5_PT_152()
        async throws
    {
        let memory = AnimationFrameMemory(costLimit: 4_096)
        let decodeKey = try XCTUnwrap(makeDecodeKey(strategy: .predecodeAll))
        let timeline = try makeTimeline(frameCount: 4)
        let session = makeSession(
            memory: memory,
            decodeKey: decodeKey,
            timeline: timeline,
            maximumPredecodeAllFrameCount: 4
        )
        await session.start(at: 0)

        let initiallyMissing = await session.fullyResidentFramesSnapshotForCompositor()
        XCTAssertNil(initiallyMissing)
        for index in 0..<4 {
            try await session.storeFrame(makeImage(), at: index)
        }
        let resident = await session.fullyResidentFramesSnapshotForCompositor()
        let snapshot = try XCTUnwrap(resident)
        XCTAssertEqual(snapshot.frames.count, 4)
        XCTAssertEqual(snapshot.timeline, timeline)
        XCTAssertEqual(snapshot.mode, .normal)

        _ = try await session.applyMemoryPressure(.warning, at: 0)
        let warningSnapshot = await session.fullyResidentFramesSnapshotForCompositor()
        XCTAssertNil(warningSnapshot)
    }

    func testExplicitPauseDecodesOnlyCurrentFrame_W5_PT_029() async throws {
        let fixture = try makeFixture(frameCount: 6)
        let session = fixture.session
        await session.start(at: 0)
        try await session.setExplicitlyPaused(true, at: 15)

        let work = try await session.work(at: 1_000)
        XCTAssertEqual(work.decision.frameIndex, 1)
        XCTAssertEqual(work.decodePlan.ranges, [1..<2])
        try await session.storeFrame(makeImage(), at: 1)
        let cachedPausedWork = try await session.work(at: 2_000)
        XCTAssertTrue(cachedPausedWork.decodePlan.ranges.isEmpty)
    }

    func testCancelIsIdempotentAndDoesNotDeleteSharedFrames_W5_PT_030() async throws {
        let fixture = try makeFixture(frameCount: 4)
        let session = fixture.session
        await session.start(at: 0)
        try await session.storeFrame(makeImage(), at: 0)
        await session.cancel()
        await session.cancel()

        do {
            _ = try await session.work(at: 1)
            XCTFail("Cancelled animation session produced playback work")
        } catch {
            XCTAssertEqual(error as? AnimationPlaybackCursorError, .cancelled)
        }
        let retainedFrame = try await session.cachedFrame(at: 0)
        XCTAssertNotNil(retainedFrame)
    }

    func testSessionRejectsFrameOutsideTimeline_W5_PT_031() async throws {
        let fixture = try makeFixture(frameCount: 2)
        do {
            _ = try await fixture.session.cachedFrame(at: 2)
            XCTFail("Out-of-range frame unexpectedly reached memory cache")
        } catch {
            XCTAssertEqual(error as? AnimationPlaybackSessionError, .invalidFrameIndex)
        }
        do {
            _ = try await fixture.session.storeFrame(makeImage(), at: -1)
            XCTFail("Negative frame unexpectedly reached memory cache")
        } catch {
            XCTAssertEqual(error as? AnimationPlaybackSessionError, .invalidFrameIndex)
        }
    }

    private func makeFixture(frameCount: Int) throws -> (
        session: AnimationPlaybackSession,
        memory: AnimationFrameMemory
    ) {
        let memory = AnimationFrameMemory(costLimit: 4_096)
        let decodeKey = try XCTUnwrap(makeDecodeKey())
        return (
            makeSession(
                memory: memory,
                decodeKey: decodeKey,
                timeline: try makeTimeline(frameCount: frameCount)
            ),
            memory
        )
    }

    private func makeSession(
        memory: AnimationFrameMemory,
        decodeKey: AnimationDecodeKey,
        timeline: AnimationPlaybackTimeline,
        maximumPredecodeAllFrameCount: Int = 0
    ) -> AnimationPlaybackSession {
        AnimationPlaybackSession(
            namespace: SecurityNamespaceID("account-a"),
            generation: NamespaceGeneration(1),
            decodeKey: decodeKey,
            timeline: timeline,
            mode: .normal,
            frameMemory: memory,
            windowPolicy: AnimationFrameWindowPolicy(
                normalFrameCount: 4,
                warningFrameCount: 2
            ),
            maximumPredecodeAllFrameCount: maximumPredecodeAllFrameCount
        )
    }

    private func makeDecodeKey(
        strategy: AnimationFrameStrategy = .boundedFrameCache
    ) -> AnimationDecodeKey? {
        AnimationDecodeKey(
            contentID: ContentID(data: Data("shared-animation".utf8)),
            target: try! TargetPixels(width: 32, height: 32),
            contentMode: .fit,
            colorPolicy: .convertToSRGB,
            codecFingerprint: "codec-v1",
            animationPolicyVersion: 1,
            timingPolicyVersion: 1,
            frameStrategy: strategy
        )
    }

    private func makeTimeline(frameCount: Int) throws -> AnimationPlaybackTimeline {
        try AnimationPlaybackTimeline(
            frameDurationsNanoseconds: [UInt64](repeating: 10, count: frameCount),
            additionalRepeatCount: nil,
            zeroDurationReplacementNanoseconds: 1,
            timingPolicyVersion: 1
        )
    }

    private func makeImage() -> DecodedImage {
        let width = 4
        let height = 4
        let bytesPerRow = width * 4
        let data = Data(repeating: 0x55, count: bytesPerRow * height)
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
}
