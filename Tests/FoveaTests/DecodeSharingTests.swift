import AkashicDisk
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class DecodeSharingTests: XCTestCase {
    func testSameDecodeKeyExecutesProbeAndDecodeOnce_SCHED_PT_002() async throws {
        let body = try makePNG(width: 400, height: 300)
        let transport = FakeHTTPTransport(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                body: body,
                delayNanoseconds: 40_000_000
            )
        ])
        let decoder = DelayedDelegatingDecoder(delay: 0.08)
        let root = try makeTemporaryDirectory()
        let diagnostics = BoundedDiagnosticsSink(capacity: 64)
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")
            ),
            recordStore: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")
            ),
            diagnostics: diagnostics,
            profileAccessPolicy: .unrestricted,
            decoder: decoder
        )
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/shared-decode.png")),
            target: try TargetPixels(width: 100, height: 75),
            appID: "tests"
        )

        async let first = pipeline.image(for: request)
        async let second = pipeline.image(for: request)
        let images = try await [first, second]

        XCTAssertEqual(images[0].pixelWidth, 100)
        XCTAssertEqual(images[1].pixelWidth, 100)
        let events = await diagnostics.snapshot().map(\.event.kind)
        XCTAssertEqual(events.filter { $0 == .decodeStarted }.count, 1)
        XCTAssertEqual(events.filter { $0 == .decodeCompleted }.count, 1)
        XCTAssertEqual(events.filter { $0 == .decodeJoined }.count, 1)
    }

    func testDifferentTargetsUseDifferentDecodeKeys() async throws {
        let body = try makePNG(width: 400, height: 300)
        let transport = FakeHTTPTransport(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                body: body,
                delayNanoseconds: 40_000_000
            )
        ])
        let decoder = DelayedDelegatingDecoder(delay: 0.04)
        let root = try makeTemporaryDirectory()
        let diagnostics = BoundedDiagnosticsSink(capacity: 64)
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")
            ),
            recordStore: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")
            ),
            diagnostics: diagnostics,
            profileAccessPolicy: .unrestricted,
            decoder: decoder
        )
        let url = try XCTUnwrap(URL(string: "https://example.test/distinct-decodes.png"))
        let small = try ImageRequest.publicImage(
            url: url,
            target: try TargetPixels(width: 80, height: 60),
            appID: "tests"
        )
        let large = try ImageRequest.publicImage(
            url: url,
            target: try TargetPixels(width: 160, height: 120),
            appID: "tests"
        )

        async let first = pipeline.image(for: small)
        async let second = pipeline.image(for: large)
        _ = try await [first, second]

        let events = await diagnostics.snapshot().map(\.event.kind)
        XCTAssertEqual(events.filter { $0 == .decodeStarted }.count, 2)
        XCTAssertEqual(events.filter { $0 == .decodeCompleted }.count, 2)
    }
}

private struct DelayedDelegatingDecoder: ImageDecoding {
    let delay: TimeInterval
    private let decoder = ImageIOImageDecoder()

    func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
        try decoder.probe(data: data, limits: limits)
    }

    func decode(
        data: Data,
        probe: ImageProbe,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage {
        Thread.sleep(forTimeInterval: delay)
        return try decoder.decode(data: data, probe: probe, request: request, limits: limits)
    }
}
