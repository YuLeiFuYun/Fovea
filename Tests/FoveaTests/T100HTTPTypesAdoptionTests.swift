import CryptoKit
import Foundation
import XCTest

@_spi(FoveaBenchmarking) @testable import FoveaHTTP

final class T100HTTPTypesAdoptionTests: XCTestCase {
    func testHTTPHexHelperMatchesIndependentReferenceForEveryByte_HTTP_TYPES_PT_001() {
        let bytes = Array(UInt8.min...UInt8.max)
        let expected = bytes.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(httpLowercaseHexString(bytes), expected)
    }

    func testBenchmarkingFingerprintMatchesIndependentSHAReference_HTTP_TYPES_PT_002() {
        let identifier = "  benchmark-context  "
        let normalized = "benchmark-context"
        let material = Data("transport-context-v2\u{0}\(normalized)".utf8)
        let expectedDigest = SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
        let reusable = TransportReusePolicy.reusable(contextIdentifier: identifier)
        XCTAssertTrue(reusable.allowsCrossRequestReuse)
        XCTAssertEqual(
            reusable.benchmarkingExecutionFingerprint,
            "transport-context-v2:\(expectedDigest)"
        )
        XCTAssertEqual(
            TransportReusePolicy.taskLocal.benchmarkingExecutionFingerprint,
            "transport-task-local-v1"
        )
    }

    func
        testReassembledResponseRehashesWholeBodyAndPreservesNetworkByteAccounting_HTTP_TYPES_PT_003()
        throws
    {
        let head = try TransportResponseHead(statusCode: 206, headers: [:], url: nil)
        let body = Data([0, 1, 2, 3, 254, 255])
        let expectedDigest = SHA256.hash(data: body)
            .map { String(format: "%02x", $0) }
            .joined()
        let response = TransportResponse(
            head: head,
            reassembledBody: body,
            receivedBytes: 2,
            metrics: TransportMetrics(receivedBytes: 999, spilledToDisk: true)
        )
        XCTAssertEqual(try response.body, body)
        XCTAssertEqual(response.bodyByteCount, body.count)
        XCTAssertEqual(response.digestHex, expectedDigest)
        XCTAssertEqual(response.metrics.receivedBytes, 2)
        XCTAssertTrue(response.metrics.spilledToDisk)
    }

    func testProgressCompletionBoundsByteCountAndCannotClaimSpill_HTTP_TYPES_PT_004() throws {
        let head = try TransportResponseHead(statusCode: 200, headers: [:], url: nil)
        let negative = TransportProgressCompletion(
            head: head,
            digestHex: "abc",
            byteCount: -7,
            metrics: TransportMetrics(receivedBytes: 999, spilledToDisk: true)
        )
        XCTAssertEqual(negative.byteCount, 0)
        XCTAssertEqual(negative.metrics.receivedBytes, 0)
        XCTAssertFalse(negative.metrics.spilledToDisk)

        let positive = TransportProgressCompletion(
            head: head,
            digestHex: "def",
            byteCount: 123,
            metrics: TransportMetrics(receivedBytes: 999, spilledToDisk: true)
        )
        XCTAssertEqual(positive.byteCount, 123)
        XCTAssertEqual(positive.metrics.receivedBytes, 123)
        XCTAssertFalse(positive.metrics.spilledToDisk)
    }

    func testProgressOnlyProtocolCarriesCompletionWithoutFullBody_HTTP_TYPES_PT_005() async throws {
        let fixture = ProgressOnlyTransportFixture()
        let request = try TransportRequest(
            request: URLRequest(url: XCTUnwrap(URL(string: "https://example.test/image"))),
            maximumBytes: 64,
            memoryThreshold: 64
        )
        let completion = try await fixture.executeProgressOnly(request)
        XCTAssertEqual(completion.digestHex, "fixture-digest")
        XCTAssertEqual(completion.byteCount, 7)
        XCTAssertEqual(completion.metrics.receivedBytes, 7)
        XCTAssertFalse(completion.metrics.spilledToDisk)
    }
}

private struct ProgressOnlyTransportFixture: TransportProgressOnlyExecuting {
    let reusePolicy = TransportReusePolicy.taskLocal

    func execute(_ request: TransportRequest) async throws -> TransportResponse {
        let head = try TransportResponseHead(
            statusCode: 200, headers: [:], url: request.request.url)
        return TransportResponse(
            head: head,
            body: Data(),
            metrics: TransportMetrics(receivedBytes: 0, spilledToDisk: false)
        )
    }

    func executeProgressOnly(_ request: TransportRequest) async throws
        -> TransportProgressCompletion
    {
        let head = try TransportResponseHead(
            statusCode: 200, headers: [:], url: request.request.url)
        return TransportProgressCompletion(
            head: head,
            digestHex: "fixture-digest",
            byteCount: 7,
            metrics: TransportMetrics(receivedBytes: 999, spilledToDisk: true)
        )
    }
}
