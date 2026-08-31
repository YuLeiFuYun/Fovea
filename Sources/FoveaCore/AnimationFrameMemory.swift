import AkashicMemory
import Foundation
import ImageCraftCore

package enum AnimationFrameStrategy: String, Codable, Hashable, Sendable {
    case firstFrameOnly
    case streamingWindow
    case boundedFrameCache
    case predecodeAll
}

/// Chooses the concrete cache/decode strategy for an encoded animation after decoder preparation.
/// `automaticWholeTrack` never guesses pixel cost: it requires a preparer-supplied whole-track
/// decoded-byte upper bound and otherwise falls back to `.boundedFrameCache`.
package enum AnimationFrameStrategySelection: Equatable, Sendable {
    case fixed(AnimationFrameStrategy)
    case automaticWholeTrack(
        maximumFrameCount: Int,
        maximumPredecodePeakByteCost: Int,
        maximumDecodedByteCost: Int? = nil
    )
}

/// 动画像素解码身份；不包含播放位置、view clock 或 dropped-frame 状态。
package struct AnimationDecodeKey: Hashable, Sendable {
    package let contentID: ContentID
    package let target: TargetPixels
    package let contentMode: ImageContentMode
    package let colorPolicy: ImageColorPolicy
    package let codecFingerprint: String
    package let animationPolicyVersion: UInt16
    package let timingPolicyVersion: UInt16
    package let frameStrategy: AnimationFrameStrategy

    package init?(
        contentID: ContentID,
        target: TargetPixels,
        contentMode: ImageContentMode,
        colorPolicy: ImageColorPolicy,
        codecFingerprint: String,
        animationPolicyVersion: UInt16,
        timingPolicyVersion: UInt16,
        frameStrategy: AnimationFrameStrategy
    ) {
        guard contentID.byteCount > 0,
            !codecFingerprint.isEmpty,
            codecFingerprint.utf8.count <= 1_024,
            codecFingerprint.unicodeScalars.allSatisfy({
                $0.value >= 0x20 && $0.value != 0x7f
            })
        else { return nil }
        self.contentID = contentID
        self.target = target
        self.contentMode = contentMode
        self.colorPolicy = colorPolicy
        self.codecFingerprint = codecFingerprint
        self.animationPolicyVersion = animationPolicyVersion
        self.timingPolicyVersion = timingPolicyVersion
        self.frameStrategy = frameStrategy
    }
}

package struct AnimationFrameMemoryKey: Hashable, Sendable {
    package let namespace: SecurityNamespaceID
    package let generation: NamespaceGeneration
    package let decodeKey: AnimationDecodeKey
    package let frameIndex: Int

    package init?(
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration,
        decodeKey: AnimationDecodeKey,
        frameIndex: Int
    ) {
        guard frameIndex >= 0 else { return nil }
        self.namespace = namespace
        self.generation = generation
        self.decodeKey = decodeKey
        self.frameIndex = frameIndex
    }
}

/// A reference-counted pin lease. Pixel bytes stay charged to `AnimationFrameMemory` until every
/// lease for the same keys is released. Release is synchronous and idempotent so platform
/// presentation objects can make budget ownership follow their exact lifetime.
package final class AnimationFrameMemoryPinLease: @unchecked Sendable {
    package let frames: [DecodedImage]
    package let byteCost: Int
    private let lock = NSLock()
    private var releaseHandler: (@Sendable () -> Void)?

    fileprivate init(
        frames: [DecodedImage],
        byteCost: Int,
        releaseHandler: @escaping @Sendable () -> Void
    ) {
        self.frames = frames
        self.byteCost = byteCost
        self.releaseHandler = releaseHandler
    }

    package func release() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            let value = releaseHandler
            releaseHandler = nil
            return value
        }
        handler?()
    }

    deinit { release() }
}

/// 独立于静态 RenderedMemory 的动画帧 SIEVE 缓存。
///
/// 成本必须使用 `DecodedImage.estimatedByteCost`；超出整个预算的单帧不会驻留。平台 compositor
/// 可以把已经驻留的帧临时 pin 在同一预算内：pin 会把条目移出普通 SIEVE 区，防止后续逐出后
/// 像素仍被 CA 强引用却逃离预算会计。namespace 撤销或 purge 会把活跃 pin 标记为释放后丢弃，
/// 从而阻止旧像素在 lease 结束时重新进入缓存。
package final class AnimationFrameMemory: @unchecked Sendable {
    private struct PinnedEntry {
        let image: DecodedImage
        let cost: Int
        var referenceCount: Int
        var reinsertOnFinalRelease: Bool
    }

    package let costLimit: Int
    private let lock = NSLock()
    private let storage: FoveaCompactSieveCache<AnimationFrameMemoryKey, DecodedImage>
    private var pinnedEntries: [AnimationFrameMemoryKey: PinnedEntry] = [:]
    private var pinLeases: [UUID: [AnimationFrameMemoryKey]] = [:]
    private var pinnedCost = 0
    private var externalRetainedReservations: [UUID: Int] = [:]
    private var externalRetainedCost = 0

    package init(costLimit: Int) {
        self.costLimit = max(1, costLimit)
        storage = FoveaCompactSieveCache(costLimit: self.costLimit)
    }

    package func image(for key: AnimationFrameMemoryKey) -> DecodedImage? {
        lock.withLock {
            if let pinned = pinnedEntries[key] { return pinned.image }
            return storage.value(for: key)
        }
    }

    @discardableResult
    package func insert(
        _ image: DecodedImage,
        for key: AnimationFrameMemoryKey
    ) -> [AnimationFrameMemoryKey] {
        lock.withLock { insertLocked(image, for: key) }
    }

    /// Pins a complete ordered key set only if every frame is currently resident. The transfer from
    /// ordinary SIEVE entries to pinned entries does not change total charged bytes. Multiple leases
    /// over the same key share one charged pixel entry through a reference count.
    package func pinResidentFrames(
        for keys: [AnimationFrameMemoryKey]
    ) -> AnimationFrameMemoryPinLease? {
        lock.withLock {
            guard !keys.isEmpty, Set(keys).count == keys.count else { return nil }
            var frames: [DecodedImage] = []
            frames.reserveCapacity(keys.count)
            for key in keys {
                if let pinned = pinnedEntries[key] {
                    frames.append(pinned.image)
                } else if let resident = storage.value(for: key) {
                    frames.append(resident)
                } else {
                    return nil
                }
            }

            let leaseID = UUID()
            for (key, image) in zip(keys, frames) {
                if var pinned = pinnedEntries[key] {
                    pinned.referenceCount += 1
                    pinnedEntries[key] = pinned
                    continue
                }
                storage.remove(key)
                let cost = max(1, image.estimatedByteCost)
                pinnedEntries[key] = PinnedEntry(
                    image: image,
                    cost: cost,
                    referenceCount: 1,
                    reinsertOnFinalRelease: true
                )
                pinnedCost = Self.saturatingAdd(pinnedCost, cost)
            }
            precondition(totalBudgetCostLocked <= costLimit)
            pinLeases[leaseID] = keys
            let chargedCost = keys.reduce(into: 0) { partial, key in
                if let entry = pinnedEntries[key] {
                    partial = Self.saturatingAdd(partial, entry.cost)
                }
            }
            return AnimationFrameMemoryPinLease(
                frames: frames,
                byteCost: chargedCost,
                releaseHandler: { [weak self] in
                    self?.releasePinLease(leaseID)
                }
            )
        }
    }

    /// Reserves non-evictable provider-retained bytes in the same animation resident budget as
    /// decoded frames. Ordinary SIEVE entries may be evicted to make room, but active pins and other
    /// provider reservations cannot be displaced. The reservation is keyed by handle identity.
    package func reserveExternalRetainedCost(_ cost: Int, for identifier: UUID) -> Bool {
        guard cost >= 0 else { return false }
        return lock.withLock {
            if let existing = externalRetainedReservations[identifier] {
                return existing == cost
            }
            let nonEvictable = Self.saturatingAdd(pinnedCost, externalRetainedCost)
            guard cost <= max(0, costLimit - nonEvictable) else { return false }
            externalRetainedReservations[identifier] = cost
            externalRetainedCost = Self.saturatingAdd(externalRetainedCost, cost)
            _ = storage.trimReportingEvictions(toCost: ordinaryCostLimitLocked)
            precondition(totalBudgetCostLocked <= costLimit)
            return true
        }
    }

    package func releaseExternalRetainedCost(for identifier: UUID) {
        lock.withLock {
            guard let cost = externalRetainedReservations.removeValue(forKey: identifier) else {
                return
            }
            externalRetainedCost = max(0, externalRetainedCost - cost)
            precondition(totalBudgetCostLocked <= costLimit)
        }
    }

    package func remove(_ key: AnimationFrameMemoryKey) {
        lock.withLock {
            storage.remove(key)
            markPinnedForDiscardLocked(where: { $0 == key })
        }
    }

    package func removeAll(
        namespace: SecurityNamespaceID
    ) -> MemoryCacheRemovalSummary {
        lock.withLock {
            let summary = storage.removeAllAndReport { $0.namespace == namespace }
            markPinnedForDiscardLocked(where: { $0.namespace == namespace })
            return summary
        }
    }

    package func removeAll(
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration,
        decodeKey: AnimationDecodeKey
    ) -> MemoryCacheRemovalSummary {
        lock.withLock {
            let matches: @Sendable (AnimationFrameMemoryKey) -> Bool = {
                $0.namespace == namespace
                    && $0.generation == generation
                    && $0.decodeKey == decodeKey
            }
            let summary = storage.removeAllAndReport(where: matches)
            markPinnedForDiscardLocked(where: matches)
            return summary
        }
    }

    package func removeAllAndReport() -> MemoryCacheRemovalSummary {
        lock.withLock {
            let summary = storage.removeAllAndReport()
            markPinnedForDiscardLocked(where: { _ in true })
            return summary
        }
    }

    /// Pixel-frame cost only. Provider-retained reservations are exposed separately so existing
    /// frame-memory diagnostics keep their established meaning.
    package var currentCost: Int { lock.withLock { frameCostLocked } }
    package var count: Int { lock.withLock { storage.count + pinnedEntries.count } }
    /// Maximum additional decoded whole-track byte cost after active presentation pins and
    /// provider-retained reservations. Ordinary SIEVE entries are intentionally excluded because
    /// they can be evicted to make room for a newly admitted whole track.
    package var availableWholeTrackAdmissionCost: Int {
        lock.withLock { max(0, costLimit - pinnedCost - externalRetainedCost) }
    }
    package var pinnedCostForTesting: Int { lock.withLock { pinnedCost } }
    package var pinnedCountForTesting: Int { lock.withLock { pinnedEntries.count } }
    package var externalRetainedCostForTesting: Int { lock.withLock { externalRetainedCost } }
    package var totalBudgetCostForTesting: Int { lock.withLock { totalBudgetCostLocked } }

    private var ordinaryCostLimitLocked: Int {
        max(0, costLimit - pinnedCost - externalRetainedCost)
    }

    private var frameCostLocked: Int {
        Self.saturatingAdd(storage.currentCost, pinnedCost)
    }

    private var totalBudgetCostLocked: Int {
        Self.saturatingAdd(frameCostLocked, externalRetainedCost)
    }

    private func insertLocked(
        _ image: DecodedImage,
        for key: AnimationFrameMemoryKey
    ) -> [AnimationFrameMemoryKey] {
        if pinnedEntries[key] != nil {
            // A pinned frame is immutable for the lease lifetime. Session planning treats it as cached,
            // so a replacement indicates stale duplicate work; keep the pinned identity authoritative.
            return []
        }
        storage.remove(key)
        let cost = max(1, image.estimatedByteCost)
        let ordinaryLimit = ordinaryCostLimitLocked
        guard cost <= ordinaryLimit else { return [] }
        var evicted = storage.trimReportingEvictions(toCost: ordinaryLimit - cost)
        evicted.append(contentsOf: storage.insertReportingEvictions(image, for: key, cost: cost))
        precondition(totalBudgetCostLocked <= costLimit)
        return evicted
    }

    private func releasePinLease(_ leaseID: UUID) {
        lock.withLock {
            guard let keys = pinLeases.removeValue(forKey: leaseID) else { return }
            var toReinsert: [(AnimationFrameMemoryKey, DecodedImage)] = []
            toReinsert.reserveCapacity(keys.count)
            for key in keys {
                guard var entry = pinnedEntries[key] else { continue }
                if entry.referenceCount > 1 {
                    entry.referenceCount -= 1
                    pinnedEntries[key] = entry
                    continue
                }
                pinnedEntries.removeValue(forKey: key)
                pinnedCost = max(0, pinnedCost - entry.cost)
                if entry.reinsertOnFinalRelease {
                    toReinsert.append((key, entry.image))
                }
            }
            for (key, image) in toReinsert {
                _ = insertLocked(image, for: key)
            }
            precondition(totalBudgetCostLocked <= costLimit)
        }
    }

    private func markPinnedForDiscardLocked(
        where predicate: @Sendable (AnimationFrameMemoryKey) -> Bool
    ) {
        for key in Array(pinnedEntries.keys) where predicate(key) {
            guard var entry = pinnedEntries[key] else { continue }
            entry.reinsertOnFinalRelease = false
            pinnedEntries[key] = entry
        }
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let next = lhs.addingReportingOverflow(rhs)
        return next.overflow ? Int.max : next.partialValue
    }
}
