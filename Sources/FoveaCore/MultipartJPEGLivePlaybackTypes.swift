import Foundation
import ImageCraftCore

package enum MultipartJPEGReduceMotionBehavior: String, Codable, Hashable, Sendable {
    /// 保留实时运动；调用方必须确认内容在 Reduce Motion 下仍适合连续播放。
    case preserveLiveMotion
    /// 只解码并发布源流第一帧，随后关闭网络和会话。
    case firstFrame
}

package struct MultipartJPEGLivePlaybackPolicy: Equatable, Sendable {
    package let minimumFrameIntervalNanoseconds: UInt64
    package let reduceMotionBehavior: MultipartJPEGReduceMotionBehavior

    package init(
        maximumFramesPerSecond: Int = 30,
        reduceMotionBehavior: MultipartJPEGReduceMotionBehavior = .firstFrame
    ) {
        let rate = UInt64(min(240, max(1, maximumFramesPerSecond)))
        let nanosecondsPerSecond: UInt64 = 1_000_000_000
        self.minimumFrameIntervalNanoseconds = (nanosecondsPerSecond + rate - 1) / rate
        self.reduceMotionBehavior = reduceMotionBehavior
    }

    package init(
        minimumFrameIntervalNanoseconds: UInt64,
        reduceMotionBehavior: MultipartJPEGReduceMotionBehavior = .firstFrame
    ) {
        self.minimumFrameIntervalNanoseconds = max(1, minimumFrameIntervalNanoseconds)
        self.reduceMotionBehavior = reduceMotionBehavior
    }

    package func stopsAfterFirstFrame(reduceMotionEnabled: Bool) -> Bool {
        reduceMotionEnabled && reduceMotionBehavior == .firstFrame
    }
}

package struct MultipartJPEGLiveFrameOutput: Sendable {
    package let image: DecodedImage
    package let sourcePartIndex: Int
    package let droppedEncodedFrameCount: UInt64
    package let decodedFrameCount: UInt64
    package let decodeDurationNanoseconds: UInt64
}

package enum MultipartJPEGLivePlaybackError: Error, Equatable, Sendable {
    case alreadyStarted
    case cancelled
    case deadlineOverflow
    case nonMonotonicClock
    case sourceIndexRegressed
}
