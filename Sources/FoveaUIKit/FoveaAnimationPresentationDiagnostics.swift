#if canImport(UIKit)
    import Foundation

    /// Benchmark-only UIKit animation presentation diagnostics.
    ///
    /// These counters describe the bounded newest-only display-target bridge. They intentionally do not
    /// reinterpret timeline dropped frames, decoder work, or product success as display-refresh loss.
    @_spi(BenchmarkDiagnostics)
    public struct FoveaAnimationPresentationDiagnosticsSnapshot: Equatable, Sendable {
        public let acceptedTargetCount: UInt64
        public let consumedTargetCount: UInt64
        public let supersededPendingTargetCount: UInt64
        public let rejectedNonmonotonicTargetCount: UInt64
        public let lifecycleClearedPendingTargetCount: UInt64
        public let hasPendingTarget: Bool
        public let lastAcceptedTargetNanoseconds: UInt64?
        public let isDisplayLinkPaused: Bool
        public let requestedPreferredFramesPerSecond: Int?
        public let effectiveVisibility: Bool?

        package init(
            acceptedTargetCount: UInt64,
            consumedTargetCount: UInt64,
            supersededPendingTargetCount: UInt64,
            rejectedNonmonotonicTargetCount: UInt64,
            lifecycleClearedPendingTargetCount: UInt64,
            hasPendingTarget: Bool,
            lastAcceptedTargetNanoseconds: UInt64?,
            isDisplayLinkPaused: Bool,
            requestedPreferredFramesPerSecond: Int?,
            effectiveVisibility: Bool?
        ) {
            self.acceptedTargetCount = acceptedTargetCount
            self.consumedTargetCount = consumedTargetCount
            self.supersededPendingTargetCount = supersededPendingTargetCount
            self.rejectedNonmonotonicTargetCount = rejectedNonmonotonicTargetCount
            self.lifecycleClearedPendingTargetCount = lifecycleClearedPendingTargetCount
            self.hasPendingTarget = hasPendingTarget
            self.lastAcceptedTargetNanoseconds = lastAcceptedTargetNanoseconds
            self.isDisplayLinkPaused = isDisplayLinkPaused
            self.requestedPreferredFramesPerSecond = requestedPreferredFramesPerSecond
            self.effectiveVisibility = effectiveVisibility
        }
    }
#endif
