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
