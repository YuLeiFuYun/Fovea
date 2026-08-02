import ComparativeLabCore
import Foundation
import PINRemoteImageComparatorAdapter

@MainActor
enum BenchmarkAdapterFactory {
    static let comparatorName = "PINRemoteImage"

    static func make(
        cacheDirectory: URL,
        sessionConfiguration: URLSessionConfiguration,
        identity: ComparatorIdentity,
        workload: ComparativeWorkloadID
    ) async throws -> any ComparatorAdapter {
        try PINRemoteImageComparatorAdapter(
            cacheDirectory: cacheDirectory,
            sessionConfiguration: sessionConfiguration,
            maximumConcurrentDownloads: workload == .w7ThousandConcurrent ? 8 : 6
        )
    }
}
