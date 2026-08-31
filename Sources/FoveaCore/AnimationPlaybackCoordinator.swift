import AkashicMemory
import Foundation
import ImageCraftCore

package struct AnimationProviderFrame: Sendable {
    package let index: Int
    package let image: DecodedImage

    package init(index: Int, image: DecodedImage) {
        self.index = index
        self.image = image
    }
}

/// Fovea 播放层与具体 GIF/APNG/JPEG-sequence decoder 之间的最小桥接面。
///
/// provider 必须按请求 range 的升序返回每一帧且不得多交付；Fovea 在写入共享帧缓存前
/// 重新验证完整窗口。`cancel()` 只用于终止整个资产，offscreen/background 使用发布代际
/// 栅栏丢弃迟到结果，不永久关闭可恢复的 decoder session。
package protocol AnimationFrameProvider: Sendable {
    func frames(in range: Range<Int>) async throws -> [AnimationProviderFrame]
    func cancel() async
}

package enum AnimationPlaybackCoordinatorError: Error, Equatable, Sendable {
    case cancelled
    case providerResultMismatch
    case publicationRevoked
    case currentFrameUnavailable
}

package struct AnimationPlaybackOutput: Sendable {
    package let decision: AnimationPlaybackDecision
    package let image: DecodedImage?
    package let decodedFrameCount: Int
    package let currentFrameWasCached: Bool
    package let automaticWholeTrackHandoffAvailable: Bool
}

/// 执行一个动画 view 会话的“计划、批量解码、验证、发布、显示”事务。
///
/// 单许可避免 actor reentrancy 造成同一会话重复窗口解码。每次可能暂停、seek 或清理的
/// 生命周期变化都会推进 publication generation；provider 在旧 generation 下完成时，像素
/// 不得进入共享缓存。终止取消同时关闭 session 和 provider，且幂等。
package actor AnimationPlaybackCoordinator {
    private let session: AnimationPlaybackSession
    private let provider: any AnimationFrameProvider
    private let decodePermits: AsyncPermitPool
    private let automaticWholeTrackPredecodePeakPermits: AsyncPermitPool?
    private let automaticWholeTrackDecodePermits: AsyncPermitPool?
    private let automaticWholeTrackDecodedByteCostUpperBound: Int?
    private let automaticWholeTrackPredecodePeakByteCost: Int?
    private let automaticWholeTrackPredecodePriority: ImageRequestPriority
    private var automaticWholeTrackPredecodeTask: Task<AnimationPlaybackOutput, any Error>?
    private var automaticWholeTrackHandoffSnapshot: AnimationPlaybackResidentFramesSnapshot?
    private var publicationGeneration: UInt64 = 0
    private var isCancelled = false

    package init(
        session: AnimationPlaybackSession,
        provider: any AnimationFrameProvider,
        maximumQueuedAdvances: Int = 8,
        automaticWholeTrackPredecodePeakPermits: AsyncPermitPool? = nil,
        automaticWholeTrackDecodePermits: AsyncPermitPool? = nil,
        automaticWholeTrackDecodedByteCostUpperBound: Int? = nil,
        automaticWholeTrackPredecodePeakByteCost: Int? = nil,
        automaticWholeTrackPredecodePriority: ImageRequestPriority = .normal
    ) {
        self.session = session
        self.provider = provider
        self.decodePermits = AsyncPermitPool(
            limit: 1,
            queueLimit: min(10_000, max(0, maximumQueuedAdvances))
        )
        self.automaticWholeTrackPredecodePeakPermits =
            automaticWholeTrackPredecodePeakPermits
        self.automaticWholeTrackDecodePermits = automaticWholeTrackDecodePermits
        self.automaticWholeTrackDecodedByteCostUpperBound =
            automaticWholeTrackDecodedByteCostUpperBound
        self.automaticWholeTrackPredecodePeakByteCost =
            automaticWholeTrackPredecodePeakByteCost
        self.automaticWholeTrackPredecodePriority = automaticWholeTrackPredecodePriority
    }

    package func start(at monotonicNanoseconds: UInt64) async throws {
        guard !isCancelled else { throw AnimationPlaybackCoordinatorError.cancelled }
        await session.start(at: monotonicNanoseconds)
    }

    package func restart(at monotonicNanoseconds: UInt64) async throws {
        guard !isCancelled else { throw AnimationPlaybackCoordinatorError.cancelled }
        advancePublicationGeneration()
        try await session.restart(at: monotonicNanoseconds)
    }

    package func setVisible(
        _ visible: Bool,
        at monotonicNanoseconds: UInt64
    ) async throws {
        guard !isCancelled else { throw AnimationPlaybackCoordinatorError.cancelled }
        if !visible { advancePublicationGeneration() }
        try await session.setVisible(visible, at: monotonicNanoseconds)
    }

    package func setApplicationActive(
        _ active: Bool,
        at monotonicNanoseconds: UInt64
    ) async throws {
        guard !isCancelled else { throw AnimationPlaybackCoordinatorError.cancelled }
        if !active { advancePublicationGeneration() }
        try await session.setApplicationActive(active, at: monotonicNanoseconds)
    }

    package func setExplicitlyPaused(
        _ paused: Bool,
        at monotonicNanoseconds: UInt64
    ) async throws {
        guard !isCancelled else { throw AnimationPlaybackCoordinatorError.cancelled }
        if paused { advancePublicationGeneration() }
        try await session.setExplicitlyPaused(paused, at: monotonicNanoseconds)
    }

    package func seek(
        toFrame index: Int,
        at monotonicNanoseconds: UInt64
    ) async throws {
        guard !isCancelled else { throw AnimationPlaybackCoordinatorError.cancelled }
        advancePublicationGeneration()
        try await session.seek(toFrame: index, at: monotonicNanoseconds)
    }

    @discardableResult
    package func applyMemoryPressure(
        _ level: AnimationMemoryPressureLevel,
        at monotonicNanoseconds: UInt64
    ) async throws -> MemoryCacheRemovalSummary {
        guard !isCancelled else { throw AnimationPlaybackCoordinatorError.cancelled }
        if level != .normal { advancePublicationGeneration() }
        return try await session.applyMemoryPressure(level, at: monotonicNanoseconds)
    }

    package func effectivePlaybackStartNanosecondsForPresentation(
        at monotonicNanoseconds: UInt64
    ) async -> UInt64? {
        guard !isCancelled else { return nil }
        return await session.effectivePlaybackStartNanosecondsForPresentation(
            at: monotonicNanoseconds
        )
    }

    package func fullyResidentFramesSnapshotForCompositor() async
        -> AnimationPlaybackResidentFramesSnapshot?
    {
        guard !isCancelled else { return nil }
        if let automaticWholeTrackHandoffSnapshot {
            self.automaticWholeTrackHandoffSnapshot = nil
            return automaticWholeTrackHandoffSnapshot
        }
        return await session.fullyResidentFramesSnapshotForCompositor()
    }

    package func advance(
        at monotonicNanoseconds: UInt64
    ) async throws -> AnimationPlaybackOutput {
        guard !isCancelled else { throw AnimationPlaybackCoordinatorError.cancelled }
        let permit = try await decodePermits.acquire(
            priority: .high,
            workEstimate: 1
        )
        return try await permit.withPermit {
            try await self.produce(at: monotonicNanoseconds)
        }
    }

    package func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        advancePublicationGeneration()
        await session.cancel()
        await provider.cancel()
    }

    private func produce(
        at monotonicNanoseconds: UInt64
    ) async throws -> AnimationPlaybackOutput {
        try Task.checkCancellation()
        guard !isCancelled else { throw AnimationPlaybackCoordinatorError.cancelled }
        automaticWholeTrackHandoffSnapshot = nil
        if let automaticWholeTrackDecodedByteCostUpperBound {
            _ = await session.revalidateAutomaticWholeTrackAdmission(
                residentDecodedByteCostUpperBound:
                    automaticWholeTrackDecodedByteCostUpperBound
            )
        }
        let generation = publicationGeneration
        let work = try await session.work(at: monotonicNanoseconds)
        let existing = try await session.cachedFrame(at: work.decision.frameIndex)
        try requireCurrentPublication(generation)
        guard !work.decodePlan.ranges.isEmpty else {
            return AnimationPlaybackOutput(
                decision: work.decision,
                image: existing,
                decodedFrameCount: 0,
                currentFrameWasCached: existing != nil,
                automaticWholeTrackHandoffAvailable: false
            )
        }

        let automaticWholeTrackAdmissionEnabled =
            await session.automaticWholeTrackAdmissionIsEnabled()
        try requireCurrentPublication(generation)
        if automaticWholeTrackAdmissionEnabled,
            let automaticWholeTrackPredecodePeakPermits,
            let automaticWholeTrackPredecodePeakByteCost
        {
            let task = Task<AnimationPlaybackOutput, any Error> { [weak self] in
                let peakPermit = try await automaticWholeTrackPredecodePeakPermits.acquire(
                    units: automaticWholeTrackPredecodePeakByteCost,
                    priority: self?.automaticWholeTrackPredecodePriority ?? .normal,
                    workEstimate: work.decodePlan.frameCount
                )
                return try await peakPermit.withPermit {
                    guard let self else { throw CancellationError() }
                    try Task.checkCancellation()
                    if let automaticWholeTrackDecodePermits = self.automaticWholeTrackDecodePermits
                    {
                        let decodePermit = try await automaticWholeTrackDecodePermits.acquire(
                            priority: self.automaticWholeTrackPredecodePriority,
                            workEstimate: work.decodePlan.frameCount
                        )
                        return try await decodePermit.withPermit {
                            try await self.decodePublishAndCaptureAutomaticHandoff(
                                work: work,
                                existing: existing,
                                publicationGeneration: generation
                            )
                        }
                    }
                    return try await self.decodePublishAndCaptureAutomaticHandoff(
                        work: work,
                        existing: existing,
                        publicationGeneration: generation
                    )
                }
            }
            automaticWholeTrackPredecodeTask?.cancel()
            automaticWholeTrackPredecodeTask = task
            defer { automaticWholeTrackPredecodeTask = nil }
            return try await task.value
        }
        return try await decodeAndPublish(
            work: work,
            existing: existing,
            publicationGeneration: generation
        )
    }

    private func decodePublishAndCaptureAutomaticHandoff(
        work: AnimationPlaybackWork,
        existing: DecodedImage?,
        publicationGeneration generation: UInt64
    ) async throws -> AnimationPlaybackOutput {
        let output = try await decodeAndPublish(
            work: work,
            existing: existing,
            publicationGeneration: generation
        )
        automaticWholeTrackHandoffSnapshot =
            await session.fullyResidentFramesSnapshotForCompositor()
        return AnimationPlaybackOutput(
            decision: output.decision,
            image: output.image,
            decodedFrameCount: output.decodedFrameCount,
            currentFrameWasCached: output.currentFrameWasCached,
            automaticWholeTrackHandoffAvailable: automaticWholeTrackHandoffSnapshot != nil
        )
    }

    private func decodeAndPublish(
        work: AnimationPlaybackWork,
        existing: DecodedImage?,
        publicationGeneration generation: UInt64
    ) async throws -> AnimationPlaybackOutput {
        var decoded: [AnimationProviderFrame] = []
        decoded.reserveCapacity(work.decodePlan.frameCount)
        for range in work.decodePlan.ranges {
            try Task.checkCancellation()
            let frames = try await provider.frames(in: range)
            guard frames.count == range.count else {
                throw AnimationPlaybackCoordinatorError.providerResultMismatch
            }
            for (expected, frame) in zip(range, frames) where frame.index != expected {
                throw AnimationPlaybackCoordinatorError.providerResultMismatch
            }
            guard await session.providerFramesAreValid(frames) else {
                throw AnimationPlaybackCoordinatorError.providerResultMismatch
            }
            decoded.append(contentsOf: frames)
        }

        try Task.checkCancellation()
        try requireCurrentPublication(generation)
        for frame in decoded where frame.index != work.decision.frameIndex {
            try await session.storeFrame(frame.image, at: frame.index)
        }
        if let currentFrame = decoded.first(where: { $0.index == work.decision.frameIndex }) {
            try await session.storeFrame(currentFrame.image, at: currentFrame.index)
        }
        let current: DecodedImage
        if let existing {
            current = existing
        } else if let retained = try await session.cachedFrame(at: work.decision.frameIndex) {
            current = retained
        } else {
            throw AnimationPlaybackCoordinatorError.currentFrameUnavailable
        }
        return AnimationPlaybackOutput(
            decision: work.decision,
            image: current,
            decodedFrameCount: decoded.count,
            currentFrameWasCached: existing != nil,
            automaticWholeTrackHandoffAvailable: false
        )
    }

    private func requireCurrentPublication(_ generation: UInt64) throws {
        guard !isCancelled else { throw AnimationPlaybackCoordinatorError.cancelled }
        guard generation == publicationGeneration else {
            throw AnimationPlaybackCoordinatorError.publicationRevoked
        }
    }

    private func advancePublicationGeneration() {
        automaticWholeTrackPredecodeTask?.cancel()
        automaticWholeTrackHandoffSnapshot = nil
        publicationGeneration = publicationGeneration == .max ? 0 : publicationGeneration + 1
    }
}
