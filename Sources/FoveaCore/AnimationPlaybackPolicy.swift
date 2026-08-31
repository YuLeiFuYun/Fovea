import Foundation

/// 应用在系统“减弱动态效果”偏好开启时选择的动画退化策略。
package enum AnimationReduceMotionBehavior: String, Codable, Hashable, Sendable {
    /// 保留调用方请求的播放模式。仅适用于应用已经确认动画不造成额外运动负担的场景。
    case preserveRequestedMode
    /// 无论容器 loop 如何，只播放首轮一次。
    case playOnce
    /// 只显示第一帧且不安排后续 tick。
    case firstFrame
}

/// 把调用方播放意图与 Reduce Motion 行为组合为稳定、可版本化的模式选择。
package struct AnimationPlaybackPolicy: Codable, Hashable, Sendable {
    package let requestedMode: AnimationPlaybackMode
    package let reduceMotionBehavior: AnimationReduceMotionBehavior

    package init(
        requestedMode: AnimationPlaybackMode = .normal,
        reduceMotionBehavior: AnimationReduceMotionBehavior = .firstFrame
    ) {
        self.requestedMode = requestedMode
        self.reduceMotionBehavior = reduceMotionBehavior
    }

    package func resolvedMode(reduceMotionEnabled: Bool) -> AnimationPlaybackMode {
        guard reduceMotionEnabled else { return requestedMode }
        switch reduceMotionBehavior {
        case .preserveRequestedMode:
            return requestedMode
        case .playOnce:
            return requestedMode == .firstFrame ? .firstFrame : .playOnce
        case .firstFrame:
            return .firstFrame
        }
    }
}
