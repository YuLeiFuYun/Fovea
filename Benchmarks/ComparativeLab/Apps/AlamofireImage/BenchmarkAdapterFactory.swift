import AlamofireImageComparatorAdapter
import ComparativeLabCore
import Foundation

@MainActor
enum BenchmarkAdapterFactory {
    static let comparatorName = "AlamofireImage"

    static func make(
        cacheDirectory: URL,
        sessionConfiguration: URLSessionConfiguration,
        identity: ComparatorIdentity,
        workload: ComparativeWorkloadID
    ) async throws -> any ComparatorAdapter {
        try AlamofireImageComparatorAdapter(
            cacheDirectory: cacheDirectory,
            sessionConfiguration: sessionConfiguration,
            maximumConcurrentDownloads: workload == .w7ThousandConcurrent ? 8 : 6
        )
    }
}
