import Foundation
@testable import NukeComparatorAdapter
import XCTest

final class NukeComparatorAdapterTests: XCTestCase {
    func testRuntimeConfigurationCapturesDataCacheAndWorkloadControls() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nuke-comparator-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 6
        let adapter = try NukeComparatorAdapter(
            cacheDirectory: cacheRoot,
            sessionConfiguration: configuration,
            maximumConcurrentDownloads: 6,
            progressiveDecodingEnabled: false
        )
        let parameters = try XCTUnwrap(adapter.runtimeConfiguration?.parameters)
        XCTAssertEqual(parameters["cache.data"], "Nuke.DataCache")
        XCTAssertEqual(parameters["cache.dataPolicy"], "storeOriginalData")
        XCTAssertEqual(parameters["cache.dataSizeLimitBytes"], "157286400")
        XCTAssertEqual(parameters["cache.dataSweepEnabled"], "true")
        XCTAssertEqual(parameters["cache.dataSweepIntervalSeconds"], "1800.0")
        XCTAssertEqual(parameters["cache.imageCostLimitBytes"], "134217728")
        XCTAssertEqual(parameters["progressive.enabledAtInitialization"], "false")
        XCTAssertEqual(parameters["progressive.intervalSeconds"], "0")
        XCTAssertEqual(parameters["scheduler.maximumConcurrentDownloads"], "6")
        XCTAssertEqual(parameters["session.httpMaximumConnectionsPerHost"], "6")
        XCTAssertEqual(parameters["session.urlCache"], "nil")
    }

    func testProgressiveWorkloadAttestationRecordsEnabledPipeline() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nuke-comparator-progressive-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let adapter = try NukeComparatorAdapter(
            cacheDirectory: cacheRoot,
            progressiveDecodingEnabled: true
        )
        XCTAssertEqual(
            adapter.runtimeConfiguration?.parameters["progressive.enabledAtInitialization"],
            "true"
        )
    }
}
