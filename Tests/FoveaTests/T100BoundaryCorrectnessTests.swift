import FoveaCore
import XCTest

final class T100BoundaryCorrectnessTests: XCTestCase {
    func testAnimationFrameWindowPlannerAvoidsOverflowAtIntDomainBoundary_T100_AUTH_PT_001()
        throws
    {
        let plan = try AnimationFrameWindowPlanner.plan(
            startingAt: Int.max - 1,
            frameCount: Int.max,
            maximumWindowSize: Int.max
        )

        XCTAssertEqual(
            plan.ranges,
            [
                (Int.max - 1)..<Int.max,
                0..<(Int.max - 1),
            ]
        )
        XCTAssertEqual(plan.frameCount, Int.max)
    }

    func testMultipartJPEGMaximumFrameRateUsesStrictMinimalCeilingPeriod_T100_AUTH_PT_002() {
        let requestedRates = [Int.min, 0, 1, 2, 3, 30, 60, 239, 240, 241, Int.max]
        let nanosecondsPerSecond: UInt64 = 1_000_000_000

        for requestedRate in requestedRates {
            let clampedRate = UInt64(min(240, max(1, requestedRate)))
            let policy = MultipartJPEGLivePlaybackPolicy(
                maximumFramesPerSecond: requestedRate
            )
            let interval = policy.minimumFrameIntervalNanoseconds

            XCTAssertGreaterThanOrEqual(
                interval * clampedRate,
                nanosecondsPerSecond,
                "requestedRate=\(requestedRate)"
            )
            if interval > 1 {
                XCTAssertLessThan(
                    (interval - 1) * clampedRate,
                    nanosecondsPerSecond,
                    "requestedRate=\(requestedRate)"
                )
            }
        }

        XCTAssertEqual(
            MultipartJPEGLivePlaybackPolicy(maximumFramesPerSecond: 30)
                .minimumFrameIntervalNanoseconds,
            33_333_334
        )
        XCTAssertEqual(
            MultipartJPEGLivePlaybackPolicy(maximumFramesPerSecond: 60)
                .minimumFrameIntervalNanoseconds,
            16_666_667
        )
        XCTAssertEqual(
            MultipartJPEGLivePlaybackPolicy(maximumFramesPerSecond: 240)
                .minimumFrameIntervalNanoseconds,
            4_166_667
        )
    }
}
