import ImageCraftCore

/// 已完全驻留且完成授权的动画轨道；平台 presenter 可直接消费，而无需额外解码，也不能绕过 `AnimationFrameMemory` 准入。
///
/// `pinLease` 在 snapshot 被持有期间，把帧 identity 从普通 SIEVE 区转入同一预算的 pinned 区；
/// 即使无关流式工作继续进行，Core Animation 强持有的像素引用仍会被正确计费。
package struct AnimationPlaybackResidentFramesSnapshot: Sendable {
    package let timeline: AnimationPlaybackTimeline
    package let mode: AnimationPlaybackMode
    package let frames: [DecodedImage]
    private let pinLease: AnimationFrameMemoryPinLease

    package init(
        timeline: AnimationPlaybackTimeline,
        mode: AnimationPlaybackMode,
        pinLease: AnimationFrameMemoryPinLease
    ) {
        self.timeline = timeline
        self.mode = mode
        self.frames = pinLease.frames
        self.pinLease = pinLease
    }
}
