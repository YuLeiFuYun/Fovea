import ComparativeLabCore
import Foundation
import NukeComparatorAdapter

@MainActor
enum BenchmarkAdapterFactory {
    static let comparatorName = "Nuke"

    static func make(
        cacheDirectory: URL,
        sessionConfiguration: URLSessionConfiguration,
        identity: ComparatorIdentity,
        workload: ComparativeWorkloadID
    ) async throws -> any ComparatorAdapter {
        try NukeComparatorAdapter(
            cacheDirectory: cacheDirectory,
            sessionConfiguration: sessionConfiguration,
            maximumConcurrentDownloads: workload == .w7ThousandConcurrent ? 8 : 6,
            progressiveDecodingEnabled: workload == .w4ProgressiveJPEG
        )
    }
}
