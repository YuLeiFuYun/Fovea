import ComparativeLabCore
import Foundation
import GifuComparatorAdapter

@MainActor
enum BenchmarkAdapterFactory {
    static let comparatorName = "Gifu"

    static func make(
        cacheDirectory: URL,
        sessionConfiguration: URLSessionConfiguration,
        identity: ComparatorIdentity,
        workload: ComparativeWorkloadID
    ) async throws -> any ComparatorAdapter {
        _ = cacheDirectory
        _ = sessionConfiguration
        _ = identity
        guard workload == .w5AnimatedMedia else {
            throw BenchmarkAppError.runFailed("gifu-w5-only-adapter")
        }
        return try GifuComparatorAdapter()
    }
}
