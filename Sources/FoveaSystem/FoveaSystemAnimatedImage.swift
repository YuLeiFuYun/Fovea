import Foundation
import FoveaCore

extension FoveaSystemPipeline {
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

    /// Creates an encoded animation handle with fail-closed automatic whole-track admission.
    /// The preparer must supply a conservative full-track decoded-byte upper bound; otherwise the
    /// runtime keeps the bounded-frame-cache strategy.
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
