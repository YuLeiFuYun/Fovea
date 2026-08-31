import Foundation
@testable import KingfisherComparatorAdapter
import XCTest

final class KingfisherComparatorAdapterTests: XCTestCase {
    func testRuntimeConfigurationUsesFixedEvaluatorOwnedCacheBudget() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kingfisher-comparator-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 6
        let adapter = try KingfisherComparatorAdapter(
            cacheDirectory: cacheRoot,
            sessionConfiguration: configuration
        )
        let parameters = try XCTUnwrap(adapter.runtimeConfiguration?.parameters)
        XCTAssertEqual(parameters["cache.rootPolicy"], "evaluator-owned")
        XCTAssertEqual(parameters["cache.memoryTotalCostLimitBytes"], "134217728")
        XCTAssertEqual(parameters["cache.memoryCountLimit"], "9223372036854775807")
        XCTAssertEqual(parameters["cache.memoryExpiration"], "seconds:300.0")
        XCTAssertEqual(parameters["cache.memoryCleanIntervalSeconds"], "120.0")
        XCTAssertEqual(parameters["cache.memoryKeepWhenEnteringBackground"], "false")
        XCTAssertEqual(parameters["cache.diskSizeLimitBytes"], "268435456")
        XCTAssertEqual(parameters["cache.diskExpiration"], "days:7")
        XCTAssertEqual(parameters["cache.diskUsesHashedFileName"], "true")
        XCTAssertEqual(parameters["cache.diskAutoExtAfterHashedFileName"], "false")
        XCTAssertEqual(parameters["session.httpMaximumConnectionsPerHost"], "6")
    }
}
