import ComparativeLabCore
import Foundation
@_spi(FoveaBenchmarking) import FoveaComparatorAdapter
import FoveaCore
import FoveaHTTP
@_spi(FoveaBenchmarking) import FoveaSystem

@MainActor
enum BenchmarkAdapterFactory {
    static let comparatorName = "Fovea"

    static func make(
        cacheDirectory: URL,
        sessionConfiguration: URLSessionConfiguration,
        identity: ComparatorIdentity,
        workload: ComparativeWorkloadID
    ) async throws -> any ComparatorAdapter {
        let concurrencyBudget = workload == .w7ThousandConcurrent ? 8 : 6
        let pipelineConfiguration = PipelineConfiguration(
            maximumConcurrentFetches: concurrencyBudget
        )
        let reusePolicy = TransportReusePolicy.reusable(
            contextIdentifier: "fovea-comparative-deterministic-origin-v1"
        )
        if let derivedRasterConfiguration = try derivedRasterConfiguration(for: workload) {
            return try await FoveaComparatorAdapter(
                cacheDirectory: cacheDirectory,
                identity: identity,
                configuration: pipelineConfiguration,
                sessionConfiguration: sessionConfiguration,
                transportReusePolicy: reusePolicy,
                derivedRasterConfiguration: derivedRasterConfiguration
            )
        }
        return try await FoveaComparatorAdapter(
            cacheDirectory: cacheDirectory,
            identity: identity,
            configuration: pipelineConfiguration,
            sessionConfiguration: sessionConfiguration,
            transportReusePolicy: reusePolicy
        )
    }

    private static func derivedRasterConfiguration(
        for workload: ComparativeWorkloadID
    ) throws -> FoveaDerivedRasterBenchmarkConfiguration? {
        guard
            let profile = ProcessInfo.processInfo.environment["FOVEA_DERIVED_RASTER_PROFILE"]
        else { return nil }
        guard profile == "observed-v1", workload == .w2DetailHero else {
            throw BenchmarkAppError.invalidArguments
        }
        return FoveaDerivedRasterBenchmarkConfiguration(
            softTotalBytes: 64 * 1024 * 1024,
            maximumBlobBytes: 16 * 1024 * 1024,
            maximumWriteBytesPerWindow: 32 * 1024 * 1024,
            writeBudgetWindowNanoseconds: 60_000_000_000,
            maximumContainerToOriginalPermille: 10_000,
            maximumCreationNanoseconds: 1_000_000_000,
            estimatedPersistentReadOverheadNanoseconds: 2_000_000,
            safetyMarginHits: 1,
            maximumConcurrentCreations: 1,
            maximumQueuedCreations: 4
        )
    }
}
