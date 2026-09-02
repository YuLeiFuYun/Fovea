import ComparativeLabCore
import FLAnimatedImageComparatorAdapter
import Foundation

@MainActor
enum BenchmarkAdapterFactory {
    static let comparatorName = "FLAnimatedImage"

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
            throw BenchmarkAppError.runFailed("flanimatedimage-w5-only-adapter")
        }
        return try FLAnimatedImageComparatorAdapter()
    }
}
