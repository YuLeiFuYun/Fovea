import APNGKitComparatorAdapter
import ComparativeLabCore
import Foundation

@MainActor
enum BenchmarkAdapterFactory {
    static let comparatorName = "APNGKit"

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
            throw BenchmarkAppError.runFailed("apngkit-w5-only-adapter")
        }
        return try APNGKitComparatorAdapter()
    }
}
