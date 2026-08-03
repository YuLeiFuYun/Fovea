import ComparativeLabCore
import Foundation
@testable import SDWebImageComparatorAdapter
import XCTest

final class SDWebImageComparatorAdapterTests: XCTestCase {
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
