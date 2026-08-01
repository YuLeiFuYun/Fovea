import AkashicDisk
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import ImageCraftCore
import XCTest

final class EncodedDataCoordinatorTests: XCTestCase {
    func testFreshReusableRecordReturnsEncodedBytesWithoutNetwork() async throws {
        let body = try makePNG(red: 91)
        let diagnostics = BoundedDiagnosticsSink(capacity: 32)
        let (pipeline, transport, _, _) = try await makePipeline(
            stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                    body: body
                )
            ],
            diagnostics: diagnostics
        )
        let request = try makeRequest(path: "fresh-hit")

        _ = try await pipeline.image(for: request)
        let encoded = try await pipeline.encodedData(for: request)

        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(encoded, body)
        XCTAssertEqual(requestCount, 1)
        let hitRecorded = await diagnostics.snapshot().contains {
            $0.event.kind == .originalEncodedHit
        }
        XCTAssertTrue(hitRecorded)
    }

    func testCorruptFreshBlobIsRemovedBeforeNetworkFallback() async throws {
        let firstBody = try makePNG(red: 41)
        let fallbackBody = try makePNG(red: 42)
        let diagnostics = BoundedDiagnosticsSink(capacity: 32)
        let root = try makeTemporaryDirectory("encoded-data-corrupt-fallback")
        let (pipeline, transport, encodedStore, records) = try await makePipeline(
            stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                    body: firstBody
                ),
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                    body: fallbackBody
                ),
            ],
            root: root,
            diagnostics: diagnostics
        )
        let request = try makeRequest(path: "corrupt-fallback")

        _ = try await pipeline.image(for: request)
        let storedRecord = await records.record(for: request.fetchVariantKey.digestHex)
        let record = try XCTUnwrap(storedRecord)
        let storedPhysicalID = await encodedStore.physicalID(
            contentID: record.contentID,
            namespace: request.namespace.value
        )
        let physicalID = try XCTUnwrap(storedPhysicalID)
        let blobURL = root.appendingPathComponent(
            "encoded/blobs/\(physicalID.foveaStorageFileName)"
        )
        try Data("corrupt".utf8).write(to: blobURL)

        let result = try await pipeline.encodedData(for: request)

        let requestCount = await transport.capturedRequests().count
        let removedRecord = await records.record(for: request.fetchVariantKey.digestHex)
        XCTAssertEqual(result, fallbackBody)
        XCTAssertEqual(requestCount, 2)
        XCTAssertNil(removedRecord)
        let readFailureRecorded = await diagnostics.snapshot().contains {
            $0.event.kind == .cacheReadFailed && $0.event.reason == "encoded-data-read"
        }
        XCTAssertTrue(readFailureRecorded)
    }

    func testOnlyIfCachedMissFailsBeforeNetwork() async throws {
        let (pipeline, transport, _, _) = try await makePipeline(stubs: [])
        let request = try ImageRequest(
            url: try XCTUnwrap(URL(string: "https://example.test/encoded/only-if-cached")),
            target: try TargetPixels(width: 20, height: 20),
            namespace: .publicNamespace(appID: "encoded-data-tests"),
            cachePolicy: .onlyIfCached
        )

        do {
            _ = try await pipeline.encodedData(for: request)
            XCTFail("only-if-cached 未命中时不得访问网络")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .cacheRead)
            XCTAssertEqual(failure.stage, .cacheLookup)
            XCTAssertEqual(failure.reasonCode, "only-if-cached-miss")
        }
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 0)
    }

    func testEncodedDataRejectsNonImageContentType() async throws {
        let body = Data("not-an-image".utf8)
        let (pipeline, transport, _, _) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "text/plain", "Cache-Control": "no-store"],
                body: body
            )
        ])

        do {
            _ = try await pipeline.encodedData(for: makeRequest(path: "non-image"))
            XCTFail("原编码入口不得接受明确的非图片 Content-Type")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .http)
            XCTAssertEqual(failure.stage, .responseValidation)
            XCTAssertEqual(failure.reasonCode, "non-image-response")
        }
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testMissingContentTypeReturnsBytesAndRecordsAnomaly() async throws {
        let body = Data("opaque-image-bytes".utf8)
        let diagnostics = BoundedDiagnosticsSink(capacity: 16)
        let (pipeline, _, _, _) = try await makePipeline(
            stubs: [
                .init(statusCode: 200, headers: ["Cache-Control": "no-store"], body: body)
            ],
            diagnostics: diagnostics
        )

        let result = try await pipeline.encodedData(for: makeRequest(path: "missing-content-type"))

        XCTAssertEqual(result, body)
        let anomaly = await diagnostics.snapshot().contains {
            $0.event.kind == .responseAnomaly && $0.event.reason == "missing-content-type"
        }
        XCTAssertTrue(anomaly)
    }

    func testNonSuccessStatusUsesStructuredHTTPFailure() async throws {
        let (pipeline, _, _, _) = try await makePipeline(stubs: [
            .init(statusCode: 404, headers: [:], body: Data())
        ])

        do {
            _ = try await pipeline.encodedData(for: makeRequest(path: "missing"))
            XCTFail("非 200 响应不得作为原编码数据返回")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .http)
            XCTAssertEqual(failure.stage, .responseValidation)
            XCTAssertEqual(failure.statusCode, 404)
            XCTAssertEqual(failure.reasonCode, "unsupported-http-status")
        }
    }

    private func makeRequest(path: String) throws -> ImageRequest {
        try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/encoded/\(path)")),
            target: TargetPixels(width: 20, height: 20),
            appID: "encoded-data-tests"
        )
    }
}
