import AppleNativeComparatorAdapter
import ComparativeLabCore
import Foundation

@MainActor
enum BenchmarkAdapterFactory {
    static let comparatorName = "Apple URLSession + URLCache + ImageIO"

    static func make(
        cacheDirectory: URL,
        sessionConfiguration: URLSessionConfiguration,
        identity: ComparatorIdentity,
        workload: ComparativeWorkloadID
    ) async throws -> any ComparatorAdapter {
        try AppleNativeComparatorAdapter(
            identity: identity,
            cacheDirectory: cacheDirectory,
            sessionConfiguration: sessionConfiguration
        )
    }
}
