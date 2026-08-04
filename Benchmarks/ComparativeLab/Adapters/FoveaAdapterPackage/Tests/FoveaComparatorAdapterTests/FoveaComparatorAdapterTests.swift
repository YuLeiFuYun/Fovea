import ComparativeLabCore
import CoreGraphics
import Foundation
import FoveaHTTP
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import FoveaComparatorAdapter

final class FoveaComparatorAdapterTests: XCTestCase {
    func testSameURLWithDifferentObservationIDsSharesOneTransport() async throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fovea-comparator-source-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        CountingImageURLProtocol.reset()

        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [CountingImageURLProtocol.self]
        let identity = try ComparatorIdentity(
            name: "Fovea",
            version: "test",
            exactCommit: String(repeating: "b", count: 40)
        )
        let adapter = try await FoveaComparatorAdapter(
            cacheDirectory: cacheRoot,
            identity: identity,
            sessionConfiguration: session,
            transportReusePolicy: .reusable(contextIdentifier: "adapter-source-test")
        )
        let url = try XCTUnwrap(URL(string: "https://benchmark.invalid/shared-image"))
        let first = try ComparatorRequest(
            resourceID: "hero|shared-image|2x2",
            url: url,
            target: try ComparatorPixelTarget(width: 2, height: 2),
            contentMode: .aspectFit,
            priority: .visible
        )
        let second = try ComparatorRequest(
            resourceID: "hero|shared-image|3x3",
            url: url,
            target: try ComparatorPixelTarget(width: 3, height: 3),
            contentMode: .aspectFit,
            priority: .visible
        )

        let firstLoad = try await adapter.makeLoad(first)
        let secondLoad = try await adapter.makeLoad(second)
        async let firstOutput = firstLoad.result()
        async let secondOutput = secondLoad.result()
        let outputs = await [firstOutput, secondOutput]

        XCTAssertEqual(outputs.map(\.measurement.outcome), [.completed, .completed])
        XCTAssertEqual(CountingImageURLProtocol.startCount, 1)
        await adapter.cancelAll()
    }

    func testPreparedWaitCoversEverySharedFetchSubscriberWithoutRequiringTransportStart()
        async throws
    {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fovea-comparator-prepared-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        NeverCompletingURLProtocol.reset()

        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [NeverCompletingURLProtocol.self]
        let identity = try ComparatorIdentity(
            name: "Fovea",
            version: "test",
            exactCommit: String(repeating: "c", count: 40)
        )
        let adapter = try await FoveaComparatorAdapter(
            cacheDirectory: cacheRoot,
            identity: identity,
            sessionConfiguration: session,
            transportReusePolicy: .reusable(contextIdentifier: "prepared-subscriber-test")
        )
        let request = try ComparatorRequest(
            resourceID: "prepared-shared-image",
            url: try XCTUnwrap(URL(string: "https://benchmark.invalid/prepared")),
            target: try ComparatorPixelTarget(width: 32, height: 32),
            contentMode: .aspectFit,
            priority: .visible
        )

        var loads: [ComparatorLoad] = []
        for _ in 0..<32 {
            loads.append(try await adapter.makeLoad(request))
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for load in loads {
                group.addTask { try await load.waitUntilPrepared() }
            }
            try await group.waitForAll()
        }

        // Subscriber registration is the adapter preparation boundary. V10 separately waits
        // for all eight origin service slots before opening the response gate, so this unit test
        // must not reintroduce V9's assumption that registration implies transport start.
        XCTAssertLessThanOrEqual(NeverCompletingURLProtocol.startCount, 1)
        for load in loads { load.cancel() }
        let outputs = await withTaskGroup(of: ComparatorLoadOutput.self) { group in
            for load in loads { group.addTask { await load.result() } }
            var values: [ComparatorLoadOutput] = []
            for await output in group { values.append(output) }
            return values
        }
        XCTAssertEqual(outputs.count, 32)
        XCTAssertTrue(outputs.allSatisfy { $0.measurement.outcome == .cancelled })
        await adapter.cancelAll()
    }

    func testCancelledProgressiveStreamIsReportedAsCancelled() async throws {
        NeverCompletingURLProtocol.reset()
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
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    static func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "benchmark.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        Self.lock.unlock()
    }

    override func stopLoading() {}
}

private final class CountingImageURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    private static let imageData: Data = {
        let data = NSMutableData()
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 16,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }()

    static var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    static func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "benchmark.invalid" && request.url?.path == "/shared-image"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        Self.lock.unlock()
        guard let url = request.url else { return }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "image/png",
                "Content-Length": String(Self.imageData.count),
                "Cache-Control": "max-age=3600",
            ]
        )!
        let client = client
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.imageData)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
