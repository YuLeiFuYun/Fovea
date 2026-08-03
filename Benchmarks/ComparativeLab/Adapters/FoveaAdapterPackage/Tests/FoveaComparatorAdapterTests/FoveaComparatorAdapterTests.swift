import ComparativeLabCore
import Foundation
@testable import FoveaComparatorAdapter
import XCTest

final class FoveaComparatorAdapterTests: XCTestCase {
    func testCancelledProgressiveStreamIsReportedAsCancelled() async throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fovea-comparator-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [NeverCompletingURLProtocol.self]
        let identity = try ComparatorIdentity(
            name: "Fovea",
            version: "test",
            exactCommit: String(repeating: "a", count: 40)
        )
        let adapter = try await FoveaComparatorAdapter(
            cacheDirectory: cacheRoot,
            identity: identity,
            sessionConfiguration: session
        )
        let request = try ComparatorRequest(
            resourceID: "cancelled-progressive-stream",
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
