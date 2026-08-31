import Foundation
import ImageCraftCore
import XCTest

@testable import FoveaCore

final class T100LocalMechanismAdoptionTests: XCTestCase {
    func testAnimationPlaybackTimelineNormalizesExactBoundariesAndRejectsOverflow_T100_AUTH_PT_003()
        throws
    {
        let timeline = try AnimationPlaybackTimeline(
            frameDurationsNanoseconds: [10, 0, 20],
            additionalRepeatCount: 2,
            zeroDurationReplacementNanoseconds: 5,
            timingPolicyVersion: 7
        )

        XCTAssertEqual(timeline.frameDurationsNanoseconds, [10, 5, 20])
        XCTAssertEqual(timeline.frameEndOffsetsNanoseconds, [10, 15, 35])
        XCTAssertEqual(timeline.totalDurationNanoseconds, 35)
        XCTAssertEqual(timeline.additionalRepeatCount, 2)
        XCTAssertEqual(timeline.timingPolicyVersion, 7)
        XCTAssertEqual(timeline.frameIndex(atLoopOffsetNanoseconds: 0), 0)
        XCTAssertEqual(timeline.frameIndex(atLoopOffsetNanoseconds: 9), 0)
        XCTAssertEqual(timeline.frameIndex(atLoopOffsetNanoseconds: 10), 1)
        XCTAssertEqual(timeline.frameIndex(atLoopOffsetNanoseconds: 14), 1)
        XCTAssertEqual(timeline.frameIndex(atLoopOffsetNanoseconds: 15), 2)
        XCTAssertEqual(timeline.frameIndex(atLoopOffsetNanoseconds: 34), 2)
        XCTAssertEqual(try timeline.frameStartOffsetNanoseconds(at: 2), 15)
        XCTAssertEqual(try timeline.frameEndOffsetNanoseconds(at: 2), 35)

        XCTAssertThrowsError(
            try AnimationPlaybackTimeline(
                frameDurationsNanoseconds: [UInt64.max, 1],
                additionalRepeatCount: nil,
                zeroDurationReplacementNanoseconds: 1,
                timingPolicyVersion: 1
            )
        ) { error in
            XCTAssertEqual(error as? AnimationPlaybackTimelineError, .durationOverflow)
        }
    }

    func
        testDecodePermitLifetimeRecorderClampsNegativeBytesAndSaturatesArithmetic_T100_AUTH_PT_004()
        async
    {
        let recorder = FoveaDecodePermitLifetimeRecorder()
        await recorder.record(
            FoveaDecodePermitLifetimeSample(
                bytes: -7,
                localWorkingSetWaitNanoseconds: 1,
                localWorkingSetHeldWaitingGlobalNanoseconds: 1,
                workingSetsHeldWaitingLocalDecodeNanoseconds: 1,
                workingSetsAndLocalDecodeHeldWaitingGlobalDecodeNanoseconds: 1,
                codecOperationNanoseconds: 1,
                localWorkingSetLeaseNanoseconds: 1,
                globalWorkingSetLeaseNanoseconds: 1,
                localDecodeLeaseNanoseconds: 1,
                globalDecodeLeaseNanoseconds: 1
            )
        )
        await recorder.record(
            FoveaDecodePermitLifetimeSample(
                bytes: Int.max,
                localWorkingSetWaitNanoseconds: UInt64.max,
                localWorkingSetHeldWaitingGlobalNanoseconds: UInt64.max,
                workingSetsHeldWaitingLocalDecodeNanoseconds: UInt64.max,
                workingSetsAndLocalDecodeHeldWaitingGlobalDecodeNanoseconds: UInt64.max,
                codecOperationNanoseconds: UInt64.max,
                localWorkingSetLeaseNanoseconds: UInt64.max,
                globalWorkingSetLeaseNanoseconds: UInt64.max,
                localDecodeLeaseNanoseconds: UInt64.max,
                globalDecodeLeaseNanoseconds: UInt64.max
            )
        )

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.completedOperationCount, 2)
        XCTAssertEqual(snapshot.admittedBytes, UInt64(Int.max))
        XCTAssertEqual(snapshot.localWorkingSetWaitNanoseconds, UInt64.max)
        XCTAssertEqual(snapshot.localWorkingSetHeldWaitingGlobalNanoseconds, UInt64.max)
        XCTAssertEqual(snapshot.workingSetsHeldWaitingLocalDecodeNanoseconds, UInt64.max)
        XCTAssertEqual(
            snapshot.workingSetsAndLocalDecodeHeldWaitingGlobalDecodeNanoseconds,
            UInt64.max
        )
        XCTAssertEqual(snapshot.codecOperationNanoseconds, UInt64.max)
        XCTAssertEqual(snapshot.localWorkingSetLeaseNanoseconds, UInt64.max)
        XCTAssertEqual(snapshot.globalWorkingSetLeaseNanoseconds, UInt64.max)
        XCTAssertEqual(snapshot.localDecodeLeaseNanoseconds, UInt64.max)
        XCTAssertEqual(snapshot.globalDecodeLeaseNanoseconds, UInt64.max)
        XCTAssertEqual(snapshot.localWorkingSetByteNanoseconds, UInt64.max)
        XCTAssertEqual(snapshot.globalWorkingSetByteNanoseconds, UInt64.max)
    }

    @MainActor
    func
        testStaticLoadRecoveryConsumesResumeOnceRejectsStaleTokenAndClearPreventsRevival_T100_AUTH_PT_005()
        throws
    {
        let recovery = ImageViewStaticLoadRecovery()
        let request = try ImageRequest(
            url: XCTUnwrap(URL(string: "https://example.test/t100-static-recovery.png")),
            target: try TargetPixels(width: 8, height: 8),
            namespace: SecurityNamespaceID("t100-static-recovery")
        )
        let spy = T100RecoveryCompletionSpy()
        let recipe = recovery.install(
            request: request,
            loader: T100NeverImageLoader(),
            placeholderDelayNanoseconds: 17,
            completion: { result in spy.record(result) }
        )

        recovery.suspend(resumeWhenAttached: true)
        XCTAssertEqual(recovery.takeResumeRecipe()?.token, recipe.token)
        XCTAssertNil(recovery.takeResumeRecipe())

        let failure = PipelineFailure(
            category: .cancelled,
            stage: .pipeline,
            disposition: .cancelled,
            reasonCode: "t100-test-cancelled"
        )
        recovery.resolve(.failure(failure), token: UUID())
        XCTAssertEqual(spy.completionCount, 0)

        recovery.suspend(resumeWhenAttached: true)
        XCTAssertEqual(recovery.takeResumeRecipe()?.token, recipe.token)
        recovery.resolve(.failure(failure), token: recipe.token)
        XCTAssertEqual(spy.completionCount, 1)
        XCTAssertEqual(spy.lastFailure, failure)

        recovery.suspend(resumeWhenAttached: true)
        XCTAssertNil(recovery.takeResumeRecipe())

        _ = recovery.install(
            request: request,
            loader: T100NeverImageLoader(),
            placeholderDelayNanoseconds: 17,
            completion: { result in spy.record(result) }
        )
        recovery.suspend(resumeWhenAttached: true)
        recovery.clear()
        XCTAssertNil(recovery.takeResumeRecipe())
        XCTAssertEqual(spy.completionCount, 1)
    }
}

private struct T100NeverImageLoader: ImageLoading {
    func image(for request: ImageRequest) async throws -> DecodedImage {
        throw CancellationError()
    }
}

@MainActor
private final class T100RecoveryCompletionSpy {
    private(set) var completionCount = 0
    private(set) var lastFailure: PipelineFailure?

    func record(_ result: Result<DecodedImage, PipelineFailure>) {
        completionCount += 1
        if case .failure(let failure) = result {
            lastFailure = failure
        }
    }
}
