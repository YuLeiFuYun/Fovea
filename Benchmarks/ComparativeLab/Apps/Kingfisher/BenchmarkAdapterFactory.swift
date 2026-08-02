import ComparativeLabCore
import Foundation
import KingfisherComparatorAdapter

@MainActor
enum BenchmarkAdapterFactory {
    static let comparatorName = "Kingfisher"

    static func make(
        cacheDirectory: URL,
        sessionConfiguration: URLSessionConfiguration,
        identity: ComparatorIdentity,
        workload: ComparativeWorkloadID
    ) async throws -> any ComparatorAdapter {
        _ = workload
        return try KingfisherComparatorAdapter(
            cacheDirectory: cacheDirectory,
            sessionConfiguration: sessionConfiguration
        )
    }
}
