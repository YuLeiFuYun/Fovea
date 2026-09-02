import FoveaCore
import XCTest

final class AnimationPlaybackCursorTests: XCTestCase {
    func testTimelineNormalizesOnlyZeroDurationsAndUsesExactBoundaries_W5_PT_008() throws {
        let timeline = try makeTimeline(
            durations: [0, 20, 30],
            zeroReplacement: 10
        )

        XCTAssertEqual(timeline.frameDurationsNanoseconds, [10, 20, 30])
        XCTAssertEqual(timeline.frameEndOffsetsNanoseconds, [10, 30, 60])
        XCTAssertEqual(timeline.totalDurationNanoseconds, 60)
        XCTAssertEqual(timeline.frameIndex(atLoopOffsetNanoseconds: 0), 0)
        XCTAssertEqual(timeline.frameIndex(atLoopOffsetNanoseconds: 9), 0)
        XCTAssertEqual(timeline.frameIndex(atLoopOffsetNanoseconds: 10), 1)
        XCTAssertEqual(timeline.frameIndex(atLoopOffsetNanoseconds: 29), 1)
        XCTAssertEqual(timeline.frameIndex(atLoopOffsetNanoseconds: 30), 2)
        XCTAssertEqual(try timeline.frameStartOffsetNanoseconds(at: 2), 30)
        XCTAssertEqual(try timeline.frameEndOffsetNanoseconds(at: 2), 60)
    }

    func testCursorAdvancesByTimelineAndReportsSkippedFrames_W5_PT_009() throws {
        var cursor = AnimationPlaybackCursor(
            timeline: try makeTimeline(durations: [10, 10, 10, 10]),
            mode: .normal
        )
        cursor.start(at: 1_000)

        XCTAssertEqual(try cursor.sample(at: 1_000).frameIndex, 0)
        let jumped = try cursor.sample(at: 1_035)
        XCTAssertEqual(jumped.frameIndex, 3)
        XCTAssertEqual(jumped.loopIndex, 0)
        XCTAssertEqual(jumped.droppedFrameCount, 2)
        XCTAssertEqual(jumped.nanosecondsUntilNextFrame, 5)

        let wrapped = try cursor.sample(at: 1_045)
        XCTAssertEqual(wrapped.frameIndex, 0)
        XCTAssertEqual(wrapped.loopIndex, 1)
        XCTAssertEqual(wrapped.droppedFrameCount, 0)
    }

    func testFiniteLoopStopsOnLastFrameWithoutCatchUp_W5_PT_010() throws {
        var cursor = AnimationPlaybackCursor(
            timeline: try makeTimeline(
                durations: [10, 20],
                additionalRepeatCount: 1
            ),
            mode: .normal
        )
        cursor.start(at: 100)
        _ = try cursor.sample(at: 100)

        let finished = try cursor.sample(at: 160)
        XCTAssertEqual(finished.frameIndex, 1)
        XCTAssertEqual(finished.loopIndex, 1)
        XCTAssertEqual(finished.droppedFrameCount, 2)
        XCTAssertTrue(finished.isFinished)
        XCTAssertNil(finished.nanosecondsUntilNextFrame)

        let stillFinished = try cursor.sample(at: 10_000)
        XCTAssertEqual(stillFinished.frameIndex, 1)
        XCTAssertTrue(stillFinished.isFinished)
        XCTAssertEqual(stillFinished.droppedFrameCount, 0)
    }

    func testPlayOnceOverridesInfiniteContainerLoop_W5_PT_011() throws {
        var cursor = AnimationPlaybackCursor(
            timeline: try makeTimeline(
                durations: [10, 20],
                additionalRepeatCount: nil
            ),
            mode: .playOnce
        )
        cursor.start(at: 0)
        let finished = try cursor.sample(at: 30)

        XCTAssertTrue(finished.isFinished)
        XCTAssertEqual(finished.loopIndex, 0)
        XCTAssertEqual(finished.frameIndex, 1)
    }

    func testFirstFrameModeNeverSchedulesOrFinishes_W5_PT_012() throws {
        var cursor = AnimationPlaybackCursor(
            timeline: try makeTimeline(durations: [10, 20]),
            mode: .firstFrame
        )
        cursor.start(at: 5)

        let decision = try cursor.sample(at: UInt64.max)
        XCTAssertEqual(decision.frameIndex, 0)
        XCTAssertEqual(decision.loopIndex, 0)
        XCTAssertFalse(decision.isFinished)
        XCTAssertNil(decision.nanosecondsUntilNextFrame)
    }

    func testOverlappingPauseReasonsFreezeUntilLastReasonClears_W5_PT_013() throws {
        var cursor = AnimationPlaybackCursor(
            timeline: try makeTimeline(durations: [10, 10, 10]),
            mode: .normal
        )
        cursor.start(at: 100)
        try cursor.setPaused(true, reason: .offscreen, at: 105)
        try cursor.setPaused(true, reason: .applicationBackground, at: 110)

        let frozen = try cursor.sample(at: 1_000)
        XCTAssertEqual(frozen.frameIndex, 0)
        XCTAssertEqual(
            frozen.pauseReasons,
            [.offscreen, .applicationBackground]
        )
        XCTAssertNil(frozen.nanosecondsUntilNextFrame)

        try cursor.setPaused(false, reason: .offscreen, at: 1_010)
        XCTAssertEqual(try cursor.sample(at: 2_000).frameIndex, 0)
        try cursor.setPaused(false, reason: .applicationBackground, at: 2_010)
        XCTAssertEqual(try cursor.sample(at: 2_015).frameIndex, 1)
    }

    func testEffectivePresentationAnchorExcludesPausedWallTime_W5_PT_184() throws {
        var cursor = AnimationPlaybackCursor(
            timeline: try makeTimeline(durations: [100, 100]),
            mode: .normal
        )
        cursor.start(at: 1_000)
        XCTAssertEqual(
            try cursor.effectivePlaybackStartNanosecondsForPresentation(at: 1_050),
            1_000
        )

        try cursor.setPaused(true, reason: .offscreen, at: 1_060)
        XCTAssertEqual(
            try cursor.effectivePlaybackStartNanosecondsForPresentation(at: 1_560),
            1_500
        )
        try cursor.setPaused(false, reason: .offscreen, at: 1_560)
        XCTAssertEqual(
            try cursor.effectivePlaybackStartNanosecondsForPresentation(at: 1_600),
            1_500
        )

        try cursor.seek(toFrame: 1, at: 1_600)
        XCTAssertEqual(
            try cursor.effectivePlaybackStartNanosecondsForPresentation(at: 1_620),
            1_500
        )
        try cursor.restart(at: 1_700)
        XCTAssertEqual(
            try cursor.effectivePlaybackStartNanosecondsForPresentation(at: 1_725),
            1_700
        )
    }

    func testSeekResetsDropAccountingAndPreservesPauseState_W5_PT_014() throws {
        var cursor = AnimationPlaybackCursor(
            timeline: try makeTimeline(durations: [10, 10, 10]),
            mode: .normal
        )
        cursor.start(at: 100)
        _ = try cursor.sample(at: 125)
        try cursor.setPaused(true, reason: .explicit, at: 125)
        try cursor.seek(toFrame: 1, at: 125)

        let paused = try cursor.sample(at: 1_000)
        XCTAssertEqual(paused.frameIndex, 1)
        XCTAssertEqual(paused.droppedFrameCount, 0)
        XCTAssertEqual(paused.pauseReasons, [.explicit])

        try cursor.setPaused(false, reason: .explicit, at: 1_000)
        XCTAssertEqual(try cursor.sample(at: 1_010).frameIndex, 2)
    }

    func testNonMonotonicClockAndCancellationFailClosed_W5_PT_015() throws {
        var cursor = AnimationPlaybackCursor(
            timeline: try makeTimeline(durations: [10, 10]),
            mode: .normal
        )
        cursor.start(at: 100)
        _ = try cursor.sample(at: 110)
        XCTAssertThrowsError(try cursor.sample(at: 109)) { error in
            XCTAssertEqual(error as? AnimationPlaybackCursorError, .nonMonotonicClock)
        }

        cursor.cancel()
        cursor.cancel()
        XCTAssertThrowsError(try cursor.sample(at: 111)) { error in
            XCTAssertEqual(error as? AnimationPlaybackCursorError, .cancelled)
        }
        XCTAssertThrowsError(
            try cursor.setPaused(true, reason: .explicit, at: 111)
        ) { error in
            XCTAssertEqual(error as? AnimationPlaybackCursorError, .cancelled)
        }
    }

    func testTimelineRejectsEmptyZeroReplacementAndOverflow_W5_PT_016() {
        XCTAssertThrowsError(
            try makeTimeline(durations: [])
        ) { error in
            XCTAssertEqual(error as? AnimationPlaybackTimelineError, .emptyTimeline)
        }
        XCTAssertThrowsError(
            try makeTimeline(durations: [0], zeroReplacement: 0)
        ) { error in
            XCTAssertEqual(
                error as? AnimationPlaybackTimelineError,
                .invalidZeroDurationReplacement
            )
        }
        XCTAssertThrowsError(
            try makeTimeline(durations: [UInt64.max, 1])
        ) { error in
            XCTAssertEqual(error as? AnimationPlaybackTimelineError, .durationOverflow)
        }
    }

    private func makeTimeline(
        durations: [UInt64],
        additionalRepeatCount: UInt32? = nil,
        zeroReplacement: UInt64 = 1
    ) throws -> AnimationPlaybackTimeline {
        try AnimationPlaybackTimeline(
            frameDurationsNanoseconds: durations,
            additionalRepeatCount: additionalRepeatCount,
            zeroDurationReplacementNanoseconds: zeroReplacement,
            timingPolicyVersion: 1
        )
    }
}
