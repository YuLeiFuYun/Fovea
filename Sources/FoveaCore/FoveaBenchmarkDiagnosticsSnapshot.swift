import Foundation

@_spi(BenchmarkDiagnostics)
public struct FoveaBenchmarkDiagnosticsSnapshot: Sendable {
    public let transientHandoffCount: Int
    public let transientHandoffBytes: Int
    public let adaptiveWarmupCount: Int
    public let inFlightHandoffPreparationCount: Int
    public let inFlightHandoffPreparationBytes: Int

    public init(
        transientHandoffCount: Int,
        transientHandoffBytes: Int,
        adaptiveWarmupCount: Int,
        inFlightHandoffPreparationCount: Int,
        inFlightHandoffPreparationBytes: Int
    ) {
        self.transientHandoffCount = transientHandoffCount
        self.transientHandoffBytes = transientHandoffBytes
        self.adaptiveWarmupCount = adaptiveWarmupCount
        self.inFlightHandoffPreparationCount = inFlightHandoffPreparationCount
        self.inFlightHandoffPreparationBytes = inFlightHandoffPreparationBytes
    }
}

/// Comparative Lab 用于等待后台派生光栅准备完成的只读活动快照。
@_spi(FoveaBenchmarking)
public struct FoveaDerivedRasterCreationActivitySnapshot: Equatable, Sendable {
    public let scheduledCount: UInt64
    public let terminalCount: UInt64
    public let activeCount: Int

    public init(scheduledCount: UInt64, terminalCount: UInt64, activeCount: Int) {
        self.scheduledCount = scheduledCount
        self.terminalCount = terminalCount
        self.activeCount = activeCount
    }
}

/// 一次成功 rendered-memory 命中的仅基准计时分解。
///
/// 生产加载路径绝不调用该 SPI。各阶段独立取时，因此相加后可能不精确等于
/// 因而阶段合计可能不精确等于 `totalNanoseconds`。
@_spi(FoveaBenchmarking)
public struct FoveaWarmMemoryTimingSample: Codable, Equatable, Sendable {
    public let requestValidationNanoseconds: UInt64
    public let namespaceGenerationNanoseconds: UInt64
    public let aliasAuthorizationNanoseconds: UInt64
    public let aliasIndexLookupNanoseconds: UInt64
    public let representationAuthorizationNanoseconds: UInt64
    public let varySelectionNanoseconds: UInt64
    public let fixedIdentityAuthorizationNanoseconds: UInt64
    public let renderedImageLookupNanoseconds: UInt64
    public let freshnessClockNanoseconds: UInt64
    public let freshnessEvaluationNanoseconds: UInt64
    public let activeNamespaceFenceNanoseconds: UInt64
    public let cancellationFenceNanoseconds: UInt64
    public let coordinatorTotalNanoseconds: UInt64
    public let totalNanoseconds: UInt64
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        requestValidationNanoseconds: UInt64,
        namespaceGenerationNanoseconds: UInt64,
        aliasAuthorizationNanoseconds: UInt64,
        aliasIndexLookupNanoseconds: UInt64,
        representationAuthorizationNanoseconds: UInt64,
        varySelectionNanoseconds: UInt64,
        fixedIdentityAuthorizationNanoseconds: UInt64,
        renderedImageLookupNanoseconds: UInt64,
        freshnessClockNanoseconds: UInt64,
        freshnessEvaluationNanoseconds: UInt64,
        activeNamespaceFenceNanoseconds: UInt64,
        cancellationFenceNanoseconds: UInt64,
        coordinatorTotalNanoseconds: UInt64,
        totalNanoseconds: UInt64,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.requestValidationNanoseconds = requestValidationNanoseconds
        self.namespaceGenerationNanoseconds = namespaceGenerationNanoseconds
        self.aliasAuthorizationNanoseconds = aliasAuthorizationNanoseconds
        self.aliasIndexLookupNanoseconds = aliasIndexLookupNanoseconds
        self.representationAuthorizationNanoseconds = representationAuthorizationNanoseconds
        self.varySelectionNanoseconds = varySelectionNanoseconds
        self.fixedIdentityAuthorizationNanoseconds = fixedIdentityAuthorizationNanoseconds
        self.renderedImageLookupNanoseconds = renderedImageLookupNanoseconds
        self.freshnessClockNanoseconds = freshnessClockNanoseconds
        self.freshnessEvaluationNanoseconds = freshnessEvaluationNanoseconds
        self.activeNamespaceFenceNanoseconds = activeNamespaceFenceNanoseconds
        self.cancellationFenceNanoseconds = cancellationFenceNanoseconds
        self.coordinatorTotalNanoseconds = coordinatorTotalNanoseconds
        self.totalNanoseconds = totalNanoseconds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}
