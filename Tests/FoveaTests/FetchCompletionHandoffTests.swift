import Foundation
import FoveaCore
import FoveaHTTP
import ImageCraftCore
import XCTest

final class FetchCompletionHandoffTests: XCTestCase {
    func testFreshReusableResponseReceivesBoundedCompletionHandoff_CACHE_PT_047() throws {
        let request = try makeRequest()
        let responseTime = Date()
        let retention = FetchCompletionHandoffPolicy.retentionNanoseconds(
            head: try makeHead(headers: ["Cache-Control": "max-age=3600"]),
            requestTime: responseTime.addingTimeInterval(-0.1),
            responseTime: responseTime,
            request: request
        )
        XCTAssertEqual(retention, FetchCompletionHandoffPolicy.maximumRetentionNanoseconds)
    }

    func testNoStoreAndImmediatelyStaleResponsesNeverReceiveHandoff_CACHE_PT_048() throws {
        let request = try makeRequest()
        let responseTime = Date()
        for headers in [
            ["Cache-Control": "no-store"],
            ["Cache-Control": "max-age=0"],
            ["Cache-Control": "no-cache, max-age=3600"],
        ] {
            XCTAssertEqual(
                FetchCompletionHandoffPolicy.retentionNanoseconds(
                    head: try makeHead(headers: headers),
                    requestTime: responseTime.addingTimeInterval(-0.1),
                    responseTime: responseTime,
                    request: request
                ),
                0
            )
        }
    }

    func testUnrepresentableVaryAndNon200ResponsesNeverReceiveHandoff_CACHE_PT_048() throws {
        let request = try makeRequest()
        let responseTime = Date()
        XCTAssertEqual(
            FetchCompletionHandoffPolicy.retentionNanoseconds(
                head: try makeHead(
                    headers: ["Cache-Control": "max-age=3600", "Vary": "*"]
                ),
                requestTime: responseTime.addingTimeInterval(-0.1),
                responseTime: responseTime,
                request: request
            ),
            0
        )
        XCTAssertEqual(
            FetchCompletionHandoffPolicy.retentionNanoseconds(
                head: try TransportResponseHead(
                    statusCode: 304,
                    headers: ["Cache-Control": "max-age=3600"],
                    url: request.url
                ),
                requestTime: responseTime.addingTimeInterval(-0.1),
                responseTime: responseTime,
                request: request
            ),
            0
        )
    }

    private func makeRequest() throws -> ImageRequest {
        try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/completion-handoff.png")),
            target: TargetPixels(width: 20, height: 20),
            appID: "fetch-completion-handoff-tests"
        )
    }

    private func makeHead(headers: [String: String]) throws -> TransportResponseHead {
        try TransportResponseHead(
            statusCode: 200,
            headers: headers,
            url: XCTUnwrap(URL(string: "https://example.test/completion-handoff.png"))
        )
    }
}
