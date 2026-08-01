import ComparativeLabCore
import Foundation
import FoveaComparatorAdapter
import FoveaCore
import FoveaHTTP

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
        return try await FoveaComparatorAdapter(
            cacheDirectory: cacheDirectory,
            identity: identity,
            configuration: PipelineConfiguration(
                maximumConcurrentFetches: concurrencyBudget
            ),
            sessionConfiguration: sessionConfiguration,
            transportReusePolicy: .reusable(
                contextIdentifier: "fovea-comparative-deterministic-origin-v1"
            )
        )
    }
}
