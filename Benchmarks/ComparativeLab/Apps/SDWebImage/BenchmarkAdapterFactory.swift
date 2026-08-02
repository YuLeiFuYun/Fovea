import ComparativeLabCore
import Foundation
import SDWebImageComparatorAdapter

@MainActor
enum BenchmarkAdapterFactory {
    static let comparatorName = "SDWebImage"

    static func make(
        cacheDirectory: URL,
        sessionConfiguration: URLSessionConfiguration,
        identity: ComparatorIdentity,
        workload: ComparativeWorkloadID
    ) async throws -> any ComparatorAdapter {
        try SDWebImageComparatorAdapter(
            cacheDirectory: cacheDirectory,
            sessionConfiguration: sessionConfiguration,
            maximumConcurrentDownloads: workload == .w7ThousandConcurrent ? 8 : 6
        )
    }
}
