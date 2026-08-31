import FoveaStorage

/// 精确 derived-raster identity 的有界进程内需求历史。
///
/// 该历史只做观测而不做预测：只有真实发生足够多次权威 original-cache reuse 后才允许派生 artifact 准入。
/// 拒绝结果会把 retry 阈值反馈给 tracker，避免在观察 cohort 仍低于 break-even 时每次 warm-disk hit 都重复压缩昂贵候选。
package actor DerivedRasterReuseObservationTracker {
    package struct Observation: Equatable, Sendable {
        package let hitCount: Int
        package let shouldAttemptCreation: Bool
    }

    private struct Entry: Sendable {
        let namespaceFingerprint: StorageNamespaceFingerprint
        var hitCount: Int
        var minimumHitCountForNextAttempt: Int
        var lastAccessSequence: UInt64
    }

    private static let maximumEntryCount = 4_096

    private var entries: [String: Entry] = [:]
    private var accessSequence: UInt64 = 0

    package func observe(_ key: DerivedRasterArtifactKey) -> Observation {
        observe(
            keyDigest: key.digestHex,
            namespaceFingerprint: key.namespaceFingerprint
        )
    }

    package func observe(
        keyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint
    ) -> Observation {
        accessSequence = Self.saturatingIncrement(accessSequence)
        if entries[keyDigest] == nil, entries.count >= Self.maximumEntryCount {
            evictLeastRecentlyObserved()
        }

        var entry =
            entries[keyDigest]
            ?? Entry(
                namespaceFingerprint: namespaceFingerprint,
                hitCount: 0,
                minimumHitCountForNextAttempt: 1,
                lastAccessSequence: accessSequence
            )
        guard entry.namespaceFingerprint == namespaceFingerprint else {
            // 即使发生跨 namespace 的 SHA-256 identity 碰撞，也绝不能合并观测。
            return Observation(hitCount: 1, shouldAttemptCreation: true)
        }
        entry.hitCount = Self.saturatingIncrement(entry.hitCount)
        entry.lastAccessSequence = accessSequence
        entries[keyDigest] = entry
        return Observation(
            hitCount: entry.hitCount,
            shouldAttemptCreation: entry.hitCount >= entry.minimumHitCountForNextAttempt
        )
    }

    package func recordRejection(
        _ rejection: DerivedRasterAdmissionRejection,
        for key: DerivedRasterArtifactKey
    ) {
        recordRejection(rejection, keyDigest: key.digestHex)
    }

    package func recordRejection(
        _ rejection: DerivedRasterAdmissionRejection,
        keyDigest: String
    ) {
        guard var entry = entries[keyDigest] else { return }
        switch rejection {
        case .insufficientObservedReuse(let required, _):
            entry.minimumHitCountForNextAttempt = max(
                entry.minimumHitCountForNextAttempt,
                required
            )
        case .creationBudgetExceeded, .noReadSavings:
            entry.minimumHitCountForNextAttempt = Self.exponentialRetryThreshold(
                after: entry.hitCount
            )
        case .byteBudgetExceeded, .invalidArtifactIdentity, .unsupportedFormatForRender,
            .foregroundCreation, .inactiveNamespace, .staleRepresentation,
            .requiresRevalidation, .invalidMetrics:
            entry.minimumHitCountForNextAttempt = Int.max
        }
        entries[keyDigest] = entry
    }

    package func recordTransientFailure(_ key: DerivedRasterArtifactKey) {
        recordTransientFailure(keyDigest: key.digestHex)
    }

    package func recordTransientFailure(keyDigest: String) {
        guard var entry = entries[keyDigest] else { return }
        entry.minimumHitCountForNextAttempt = Self.exponentialRetryThreshold(
            after: entry.hitCount
        )
        entries[keyDigest] = entry
    }

    package func markPublished(_ key: DerivedRasterArtifactKey) {
        entries.removeValue(forKey: key.digestHex)
    }

    package func markPublished(keyDigest: String) {
        entries.removeValue(forKey: keyDigest)
    }

    package func removeAll(namespaceFingerprint: StorageNamespaceFingerprint) {
        entries = entries.filter { _, entry in
            entry.namespaceFingerprint != namespaceFingerprint
        }
    }

    package func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }

    package func trackedEntryCountForTesting() -> Int {
        entries.count
    }

    private func evictLeastRecentlyObserved() {
        guard
            let victim = entries.min(by: { lhs, rhs in
                lhs.value.lastAccessSequence < rhs.value.lastAccessSequence
            })?.key
        else { return }
        entries.removeValue(forKey: victim)
    }

    private static func exponentialRetryThreshold(after hitCount: Int) -> Int {
        guard hitCount > 0 else { return 1 }
        let doubled = hitCount.multipliedReportingOverflow(by: 2)
        return doubled.overflow ? Int.max : max(hitCount + 1, doubled.partialValue)
    }

    private static func saturatingIncrement(_ value: Int) -> Int {
        value == Int.max ? Int.max : value + 1
    }

    private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? UInt64.max : value + 1
    }
}
