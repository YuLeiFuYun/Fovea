import FoveaCore
import XCTest

final class T100MultipartJPEGLivePlaybackTypesTests: XCTestCase {
    func testFrameRatePolicyClampsAndUsesCeilingInterval_MJPEG_LIVE_TYPES_PT_001() {
        let belowRange = MultipartJPEGLivePlaybackPolicy(maximumFramesPerSecond: 0)
        let nominal = MultipartJPEGLivePlaybackPolicy(maximumFramesPerSecond: 30)
        let aboveRange = MultipartJPEGLivePlaybackPolicy(maximumFramesPerSecond: 10_000)

        XCTAssertEqual(belowRange.minimumFrameIntervalNanoseconds, 1_000_000_000)
        XCTAssertEqual(nominal.minimumFrameIntervalNanoseconds, 33_333_334)
        XCTAssertEqual(aboveRange.minimumFrameIntervalNanoseconds, 4_166_667)
    }

    func testDirectIntervalClampsToOneAndPreservesReduceMotionBehavior_MJPEG_LIVE_TYPES_PT_002() {
        let firstFrame = MultipartJPEGLivePlaybackPolicy(
            minimumFrameIntervalNanoseconds: 0,
            reduceMotionBehavior: .firstFrame
        )
        let preserved = MultipartJPEGLivePlaybackPolicy(
            minimumFrameIntervalNanoseconds: 42,
            reduceMotionBehavior: .preserveLiveMotion
        )

        XCTAssertEqual(firstFrame.minimumFrameIntervalNanoseconds, 1)
        XCTAssertEqual(firstFrame.reduceMotionBehavior, .firstFrame)
        XCTAssertEqual(preserved.minimumFrameIntervalNanoseconds, 42)
        XCTAssertEqual(preserved.reduceMotionBehavior, .preserveLiveMotion)
    }

    func testReduceMotionStopDecisionIsExplicitAndFailClosed_MJPEG_LIVE_TYPES_PT_003() {
        let defaultPolicy = MultipartJPEGLivePlaybackPolicy()
        let preserve = MultipartJPEGLivePlaybackPolicy(
            maximumFramesPerSecond: 60,
            reduceMotionBehavior: .preserveLiveMotion
        )

        XCTAssertTrue(defaultPolicy.stopsAfterFirstFrame(reduceMotionEnabled: true))
        XCTAssertFalse(defaultPolicy.stopsAfterFirstFrame(reduceMotionEnabled: false))
        XCTAssertFalse(preserve.stopsAfterFirstFrame(reduceMotionEnabled: true))
    }
}
