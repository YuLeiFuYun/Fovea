import Foundation
@testable import PINRemoteImageComparatorAdapter
import XCTest

final class PINRemoteImageComparatorAdapterTests: XCTestCase {
    func testRuntimeConfigurationUsesIsolatedPinnedTTLCache() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinremoteimage-comparator-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 6
        let adapter = try PINRemoteImageComparatorAdapter(
            cacheDirectory: cacheRoot,
            sessionConfiguration: configuration,
            maximumConcurrentDownloads: 6
        )
        let parameters = try XCTUnwrap(adapter.runtimeConfiguration?.parameters)
        XCTAssertEqual(parameters["cache.rootPolicy"], "evaluator-owned")
        XCTAssertEqual(parameters["cache.memoryCostLimit"], "0")
        XCTAssertEqual(parameters["cache.memoryAgeLimitSeconds"], "0.0")
        XCTAssertEqual(parameters["cache.memoryTTL"], "true")
        XCTAssertEqual(parameters["cache.diskByteLimit"], "52428800")
        XCTAssertEqual(parameters["cache.diskAgeLimitSeconds"], "2592000.0")
        XCTAssertEqual(parameters["cache.diskTTL"], "true")
        XCTAssertEqual(parameters["cache.evictionStrategy"], "least-recently-used")
        XCTAssertEqual(parameters["cache.serialization"], "PINRemoteImage-resume-aware-v1")
        XCTAssertEqual(
            parameters["dependency.PINCache"],
            "3.0.4@2fb85948463292c2e824148cf17dc62a4c217a94"
        )
        XCTAssertEqual(
            parameters["dependency.PINOperation"],
            "1.2.3@a74f978733bdaf982758bfa23d70a189f4b4c1b6"
        )
        XCTAssertEqual(parameters["scheduler.maximumConcurrentDownloads"], "6")
        XCTAssertEqual(parameters["scheduler.maximumConcurrentOperations"], "6")
        XCTAssertEqual(parameters["session.httpMaximumConnectionsPerHost"], "6")
    }
}
