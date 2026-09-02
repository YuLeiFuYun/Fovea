import Foundation
import FoveaCore

extension FoveaSystemPipeline {

    /// 使用 Fovea 当前精确固定的 ImageCraft 动画解码器创建授权动画 handle。
    ///
    /// 调用方仍显式提供零时长替代与 timing policy 版本；其余解码、帧窗口和整轨成本
    /// 由生产 ImageCraft adapter 提供，不再依赖资格化 fixture 注入。
    package func makeImageCraftEncodedAnimationHandle(
        for request: ImageRequest,
        zeroDurationReplacementNanoseconds: UInt64,
        timingPolicyVersion: UInt16,
        animationPolicyVersion: UInt16,
        frameStrategy: AnimationFrameStrategy,
        playbackPolicy: AnimationPlaybackPolicy,
        reduceMotionEnabled: Bool,
        windowPolicy: AnimationFrameWindowPolicy,
        maximumPredecodeAllFrameCount: Int = 0,
        maximumQueuedAdvances: Int = 8,
        clock: any AnimationPlaybackClock = SystemAnimationPlaybackClock()
    ) async throws -> AnimationPlaybackHandle {
        let preparer = ImageCraftAnimationPlaybackPreparer(
            zeroDurationReplacementNanoseconds: zeroDurationReplacementNanoseconds,
            timingPolicyVersion: timingPolicyVersion
        )
        return try await makeEncodedAnimationHandle(
            for: request,
            using: preparer,
            animationPolicyVersion: animationPolicyVersion,
            frameStrategy: frameStrategy,
            playbackPolicy: playbackPolicy,
            reduceMotionEnabled: reduceMotionEnabled,
            windowPolicy: windowPolicy,
            maximumPredecodeAllFrameCount: maximumPredecodeAllFrameCount,
            maximumQueuedAdvances: maximumQueuedAdvances,
            clock: clock
        )
    }

    /// 从普通 Fovea 请求创建 decoder-neutral 静态动画 handle。
    ///
    /// 加载阶段复用管线 ACL、授权、HTTP 缓存与 namespace generation；preparer 返回后再次
    /// 验证 generation。授权 runtime 工厂负责在身份、codec 或容量失败时取消 provider。
    package func makeEncodedAnimationHandle(
        for request: ImageRequest,
        using preparer: any EncodedAnimationPlaybackPreparing,
        animationPolicyVersion: UInt16,
        frameStrategy: AnimationFrameStrategy,
        playbackPolicy: AnimationPlaybackPolicy,
        reduceMotionEnabled: Bool,
        windowPolicy: AnimationFrameWindowPolicy,
        maximumPredecodeAllFrameCount: Int = 0,
        maximumQueuedAdvances: Int = 8,
        clock: any AnimationPlaybackClock = SystemAnimationPlaybackClock()
    ) async throws -> AnimationPlaybackHandle {
        let asset = try await pipeline.prepareAuthorizedAnimationPlayback(
            for: request,
            using: preparer
        )
        return try await animationRuntime.makeHandle(
            authorizedAsset: asset,
            request: request,
            animationPolicyVersion: animationPolicyVersion,
            frameStrategy: frameStrategy,
            playbackPolicy: playbackPolicy,
            reduceMotionEnabled: reduceMotionEnabled,
            windowPolicy: windowPolicy,
            maximumPredecodeAllFrameCount: maximumPredecodeAllFrameCount,
            maximumQueuedAdvances: maximumQueuedAdvances,
            clock: clock
        )
    }

    /// 创建带失败关闭自动整轨准入的 encoded animation handle；preparer 必须提供保守的整轨解码字节上界，
    /// 否则 runtime 继续使用 bounded-frame-cache 策略。
    package func makeEncodedAnimationHandle(
        for request: ImageRequest,
        using preparer: any EncodedAnimationPlaybackPreparing,
        animationPolicyVersion: UInt16,
        frameStrategySelection: AnimationFrameStrategySelection,
        playbackPolicy: AnimationPlaybackPolicy,
        reduceMotionEnabled: Bool,
        windowPolicy: AnimationFrameWindowPolicy,
        maximumQueuedAdvances: Int = 8,
        clock: any AnimationPlaybackClock = SystemAnimationPlaybackClock()
    ) async throws -> AnimationPlaybackHandle {
        let asset = try await pipeline.prepareAuthorizedAnimationPlayback(
            for: request,
            using: preparer
        )
        return try await animationRuntime.makeHandle(
            authorizedAsset: asset,
            request: request,
            animationPolicyVersion: animationPolicyVersion,
            frameStrategySelection: frameStrategySelection,
            playbackPolicy: playbackPolicy,
            reduceMotionEnabled: reduceMotionEnabled,
            windowPolicy: windowPolicy,
            maximumQueuedAdvances: maximumQueuedAdvances,
            clock: clock
        )
    }

}
