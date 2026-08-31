import ImageCraftCore

/// A fully resident, already-authorized animation track that a platform presenter may consume
/// without requesting additional decoding or bypassing `AnimationFrameMemory` admission.
///
/// `pinLease` transfers these frame identities from the ordinary SIEVE region into the pinned region
/// of the same animation-memory budget for exactly as long as this snapshot is retained. This keeps
/// Core Animation's strong pixel references charged even if unrelated streaming work proceeds.
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
