import AkashicMemory
import Foundation
import ImageCraftCore

package enum AnimationPlaybackSessionError: Error, Equatable, Sendable {
    case invalidFrameIndex
}

package struct AnimationPlaybackWork: Equatable, Sendable {
    package let decision: AnimationPlaybackDecision
    package let decodePlan: AnimationFrameDecodePlan
}

/// 把确定性播放 cursor、独立帧缓存和生命周期窗口策略组合为单个 view 会话。
///
/// 多个会话可以共享 `AnimationFrameMemory` 与动画像素，但各自保有独立 clock、pause reason、
/// loop 和 dropped-frame 统计。offscreen、后台和 critical memory pressure 不产生新解码工作；
/// 恢复时继续冻结前的时间点，禁止把不可见期间的墙钟时间作为待追赶帧。
package actor AnimationPlaybackSession {
    private let namespace: SecurityNamespaceID
    private let generation: NamespaceGeneration
    private let decodeKey: AnimationDecodeKey
    private let frameMemory: AnimationFrameMemory
    private let windowPolicy: AnimationFrameWindowPolicy
    private var maximumPredecodeAllFrameCount: Int
    private var cursor: AnimationPlaybackCursor
    private var memoryPressure: AnimationMemoryPressureLevel = .normal
    private var maximumObservedFrameByteCost = 0

    package init(
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration,
        decodeKey: AnimationDecodeKey,
        timeline: AnimationPlaybackTimeline,
        mode: AnimationPlaybackMode,
        frameMemory: AnimationFrameMemory,
        windowPolicy: AnimationFrameWindowPolicy,
        maximumPredecodeAllFrameCount: Int = 0
    ) {
        self.namespace = namespace
        self.generation = generation
        self.decodeKey = decodeKey
        self.frameMemory = frameMemory
        self.windowPolicy = windowPolicy
        self.maximumPredecodeAllFrameCount = min(
            timeline.frameCount,
            max(0, maximumPredecodeAllFrameCount)
        )
        self.cursor = AnimationPlaybackCursor(timeline: timeline, mode: mode)
    }

    package func start(at monotonicNanoseconds: UInt64) {
        cursor.start(at: monotonicNanoseconds)
    }

    package func restart(at monotonicNanoseconds: UInt64) throws {
        try cursor.restart(at: monotonicNanoseconds)
    }

    package func setVisible(
        _ visible: Bool,
        at monotonicNanoseconds: UInt64
    ) throws {
        try cursor.setPaused(
            !visible,
            reason: .offscreen,
            at: monotonicNanoseconds
        )
    }

    package func setApplicationActive(
        _ active: Bool,
        at monotonicNanoseconds: UInt64
    ) throws {
        try cursor.setPaused(
            !active,
            reason: .applicationBackground,
            at: monotonicNanoseconds
        )
    }

    package func setExplicitlyPaused(
        _ paused: Bool,
        at monotonicNanoseconds: UInt64
    ) throws {
        try cursor.setPaused(
            paused,
            reason: .explicit,
            at: monotonicNanoseconds
        )
    }

    package func seek(
        toFrame index: Int,
        at monotonicNanoseconds: UInt64
    ) throws {
        try cursor.seek(toFrame: index, at: monotonicNanoseconds)
    }

    @discardableResult
    package func applyMemoryPressure(
        _ level: AnimationMemoryPressureLevel,
        at monotonicNanoseconds: UInt64
    ) throws -> MemoryCacheRemovalSummary {
        memoryPressure = level
        switch level {
        case .normal, .warning:
            try cursor.setPaused(
                false,
                reason: .memoryPressure,
                at: monotonicNanoseconds
            )
            return MemoryCacheRemovalSummary(itemCount: 0, costBytes: 0)
        case .critical:
            try cursor.setPaused(
                true,
                reason: .memoryPressure,
                at: monotonicNanoseconds
            )
            return frameMemory.removeAll(
                namespace: namespace,
                generation: generation,
                decodeKey: decodeKey
            )
        }
    }

    /// Revalidates an automatic whole-track admission against current non-evictable pinned bytes.
    /// On failure this session permanently falls back to its bounded window policy.
    package func revalidateAutomaticWholeTrackAdmission(
        residentDecodedByteCostUpperBound: Int
    ) -> Bool {
        guard decodeKey.frameStrategy == .predecodeAll,
            maximumPredecodeAllFrameCount == cursor.timeline.frameCount,
            residentDecodedByteCostUpperBound > 0
        else { return false }
        guard frameMemory.availableWholeTrackAdmissionCost >= residentDecodedByteCostUpperBound
        else {
            maximumPredecodeAllFrameCount = 0
            return false
        }
        return true
    }

    package func automaticWholeTrackAdmissionIsEnabled() -> Bool {
        decodeKey.frameStrategy == .predecodeAll
            && maximumPredecodeAllFrameCount == cursor.timeline.frameCount
    }

    package func work(
        at monotonicNanoseconds: UInt64
    ) throws -> AnimationPlaybackWork {
        let decision = try cursor.sample(at: monotonicNanoseconds)
        if decision.pauseReasons.contains(.offscreen)
            || decision.pauseReasons.contains(.applicationBackground)
            || decision.pauseReasons.contains(.memoryPressure)
        {
            return AnimationPlaybackWork(
                decision: decision,
                decodePlan: AnimationFrameDecodePlan(ranges: [])
            )
        }

        let maximumWindow = desiredWindowSize(for: decision)
        let plan = try AnimationFrameWindowPlanner.plan(
            startingAt: decision.frameIndex,
            frameCount: cursor.timeline.frameCount,
            maximumWindowSize: maximumWindow
        )
        let missing = AnimationFrameWindowPlanner.missingRanges(from: plan) { index in
            guard let key = self.frameKey(index: index) else { return false }
            return self.frameMemory.image(for: key) != nil
        }
        return AnimationPlaybackWork(decision: decision, decodePlan: missing)
    }

    package func providerFramesAreValid(_ frames: [AnimationProviderFrame]) -> Bool {
        frames.allSatisfy { frame in
            let image = frame.image
            return image.pixelWidth > 0
                && image.pixelHeight > 0
                && image.pixelWidth <= decodeKey.target.width
                && image.pixelHeight <= decodeKey.target.height
                && image.estimatedByteCost > 0
                && image.estimatedByteCost <= frameMemory.costLimit
        }
    }

    package func cachedFrame(at index: Int) throws -> DecodedImage? {
        guard cursor.timeline.frameDurationsNanoseconds.indices.contains(index),
            let key = frameKey(index: index)
        else { throw AnimationPlaybackSessionError.invalidFrameIndex }
        return frameMemory.image(for: key)
    }

    /// Returns an immutable whole-track snapshot only when the existing predecode-all policy
    /// has already left every frame resident under the shared frame-memory budget.
    /// This method never asks the provider to decode and never inserts cache entries.
    package func effectivePlaybackStartNanosecondsForPresentation(
        at monotonicNanoseconds: UInt64
    ) -> UInt64? {
        try? cursor.effectivePlaybackStartNanosecondsForPresentation(
            at: monotonicNanoseconds
        )
    }

    package func fullyResidentFramesSnapshotForCompositor()
        -> AnimationPlaybackResidentFramesSnapshot?
    {
        guard decodeKey.frameStrategy == .predecodeAll,
            maximumPredecodeAllFrameCount == cursor.timeline.frameCount,
            cursor.mode == .normal,
            cursor.timeline.frameCount > 1,
            memoryPressure == .normal
        else { return nil }

        var keys: [AnimationFrameMemoryKey] = []
        keys.reserveCapacity(cursor.timeline.frameCount)
        for index in 0..<cursor.timeline.frameCount {
            guard let key = frameKey(index: index) else { return nil }
            keys.append(key)
        }
        guard let pinLease = frameMemory.pinResidentFrames(for: keys) else { return nil }
        return AnimationPlaybackResidentFramesSnapshot(
            timeline: cursor.timeline,
            mode: cursor.mode,
            pinLease: pinLease
        )
    }

    @discardableResult
    package func storeFrame(
        _ image: DecodedImage,
        at index: Int
    ) throws -> [AnimationFrameMemoryKey] {
        guard cursor.timeline.frameDurationsNanoseconds.indices.contains(index),
            let key = frameKey(index: index)
        else { throw AnimationPlaybackSessionError.invalidFrameIndex }
        maximumObservedFrameByteCost = max(
            maximumObservedFrameByteCost,
            image.estimatedByteCost
        )
        return frameMemory.insert(image, for: key)
    }

    package func cancel() {
        cursor.cancel()
    }

    private func desiredWindowSize(for decision: AnimationPlaybackDecision) -> Int {
        if decision.isFinished
            || decision.pauseReasons.contains(.explicit)
            || decodeKey.frameStrategy == .firstFrameOnly
        {
            return 1
        }
        let frameCountBound: Int
        if decodeKey.frameStrategy == .predecodeAll,
            maximumPredecodeAllFrameCount == cursor.timeline.frameCount,
            memoryPressure == .normal
        {
            frameCountBound = cursor.timeline.frameCount
        } else {
            frameCountBound = windowPolicy.frameCount(for: memoryPressure)
        }
        guard maximumObservedFrameByteCost > 0 else { return frameCountBound }
        let byteBound = max(1, frameMemory.costLimit / maximumObservedFrameByteCost)
        return min(frameCountBound, byteBound)
    }

    private func frameKey(index: Int) -> AnimationFrameMemoryKey? {
        AnimationFrameMemoryKey(
            namespace: namespace,
            generation: generation,
            decodeKey: decodeKey,
            frameIndex: index
        )
    }
}
