import ComparativeLabCore
import Foundation
@testable import SDWebImageComparatorAdapter
import XCTest

final class SDWebImageComparatorAdapterTests: XCTestCase {
    func testRuntimeConfigurationFreezesCacheLifetimeAndDownloaderPolicy() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdwebimage-comparator-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 6
        let adapter = try SDWebImageComparatorAdapter(
            cacheDirectory: cacheRoot,
            sessionConfiguration: configuration,
            maximumConcurrentDownloads: 6
        )
        let parameters = try XCTUnwrap(adapter.runtimeConfiguration?.parameters)
        XCTAssertEqual(parameters["cache.rootPolicy"], "evaluator-owned")
        XCTAssertEqual(parameters["cache.diskSizeBytes"], "268435456")
        XCTAssertEqual(parameters["cache.diskExpirationSeconds"], "604800.0")
        XCTAssertEqual(parameters["cache.diskExpireTypeRaw"], "0")
        XCTAssertEqual(parameters["cache.diskReadingOptionsRaw"], "0")
        XCTAssertEqual(parameters["cache.diskWritingOptionsRaw"], "1")
        XCTAssertEqual(parameters["cache.memoryCostLimitBytes"], "134217728")
        XCTAssertEqual(parameters["cache.memoryCountLimit"], "0")
        XCTAssertEqual(parameters["cache.memoryEnabled"], "true")
        XCTAssertEqual(parameters["cache.weakMemoryEnabled"], "false")
        XCTAssertEqual(parameters["downloader.timeoutSeconds"], "15.0")
        XCTAssertEqual(parameters["downloader.executionOrderRaw"], "0")
        XCTAssertEqual(parameters["downloader.minimumProgressInterval"], "0.0")
        XCTAssertEqual(parameters["scheduler.maximumConcurrentDownloads"], "6")
        XCTAssertEqual(parameters["session.httpMaximumConnectionsPerHost"], "6")
    }

    func testManagerCancellationUsesSDWebImageErrorDomain() async throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdwebimage-comparator-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NeverCompletingURLProtocol.self]
        let adapter = try SDWebImageComparatorAdapter(
            cacheDirectory: cacheRoot,
            sessionConfiguration: configuration
        )
        let request = try ComparatorRequest(
            resourceID: "cancelled-manager-load",
            url: try XCTUnwrap(URL(string: "https://benchmark.invalid/cancel")),
            target: try ComparatorPixelTarget(width: 32, height: 32),
            contentMode: .aspectFit,
            priority: .visible
        )

        let load = try await adapter.makeLoad(request)
        try await Task.sleep(nanoseconds: 20_000_000)
        load.cancel()
        let output = await load.result()

        XCTAssertEqual(output.measurement.outcome, .cancelled)
        XCTAssertNil(output.measurement.failureCategory)
        await adapter.cancelAll()
    }
}

private final class NeverCompletingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "benchmark.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {}

    override func stopLoading() {}
}
