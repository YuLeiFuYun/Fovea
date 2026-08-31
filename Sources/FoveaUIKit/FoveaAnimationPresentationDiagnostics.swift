#if canImport(UIKit)
    import Foundation

    /// 仅 benchmark 使用的 UIKit animation presentation 诊断。
    ///
    /// 这些计数器只描述有界 newest-only display-target bridge，不把 timeline dropped frame、decoder work 或产品成功误解释为 display-refresh loss。
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
