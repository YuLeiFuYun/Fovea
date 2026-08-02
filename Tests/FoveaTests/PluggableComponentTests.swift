import AkashicMemory
import Foundation
import FoveaCore
import FoveaSystem
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class PluggableComponentTests: XCTestCase {
    func testPublicCodecContractCanDriveThePipeline_CODEC_PT_010() async throws {
        let body = try makePNG(width: 40, height: 20)
        let codec = DelegatingTestCodec()
        let (pipeline, _, _, _) = try await makePipeline(
            stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                    body: body
                )
            ],
            decoder: codec
        )
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/plugin-codec.png")),
            target: TargetPixels(width: 20, height: 10),
            appID: "plugin-codec"
        )

        let image = try await pipeline.image(for: request)

        XCTAssertEqual(image.pixelWidth, 20)
        XCTAssertEqual(image.pixelHeight, 10)
        XCTAssertEqual(
            pipeline.codecDescriptor.identifier.rawValue,
            "test.delegating-codec"
        )
    }

    func testCustomRenderedCacheOwnsHitsInsertionAndPurge_CACHE_PT_043() async throws {
        let body = try makePNG(width: 48, height: 24)
        let cache = RecordingRenderedImageCache()
        let (pipeline, transport, _, _) = try await makePipeline(
            stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                    body: body
                )
            ],
            renderedImageCache: cache
        )
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/plugin-cache.png")),
            target: TargetPixels(width: 24, height: 12),
            appID: "plugin-cache"
        )

        _ = try await pipeline.image(for: request)
        _ = try await pipeline.image(for: request)
        let residentCount = cache.count
        let residentCost = cache.currentCost
        let removed = await pipeline.purgeMemoryCache()
        let requestCount = await transport.capturedRequests().count

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(residentCount, 1)
        XCTAssertGreaterThan(residentCost, 0)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(cache.count, 0)
    }

    func testSystemCompositionAcceptsCustomCodecAndRenderedCache_CODEC_PT_011() async throws {
        let codec = DelegatingTestCodec()
        let cache = RecordingRenderedImageCache()
        let system = try await FoveaSystemPipeline.open(
            cacheRoot: try makeTemporaryDirectory("system-plugin-components"),
            automaticallyPurgesMemoryOnPressure: false,
            decoder: codec,
            renderedImageCache: cache
        )

        XCTAssertEqual(
            system.pipeline.codecDescriptor.identifier.rawValue,
            "test.delegating-codec"
        )
        XCTAssertEqual(cache.count, 0)
    }
}

private struct DelegatingTestCodec: ImageCodec, PreparedImageDecoding {
    private let base = ImageIOImageDecoder()

    let codecDescriptor = ImageCodecDescriptor(
        identifier: ImageCodecIdentifier(rawValue: "test.delegating-codec"),
        implementationVersion: 1,
        capabilities: ImageCodecCapabilities(
            formats: [.png, .jpeg, .gif],
            deliveryModes: [.completeFrame],
            trackModes: [.primaryFrame],
            metadata: [.orientation, .sourceColorProfile],
            dynamicRanges: [.standard],
            outputRepresentations: [.coreGraphicsImage],
            cancellationMode: .operationBoundary
        )
    )

    func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
        try base.probe(data: data, limits: limits)
    }

    func decode(
        data: Data,
        probe: ImageProbe,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage {
        try base.decode(data: data, probe: probe, request: request, limits: limits)
    }

    func resourceEstimate(
        probe: ImageProbe,
        request: ImageDecodeRequest
    ) throws -> ImageDecodeResourceEstimate {
        let pixels = request.target.pixelCount
        let bytes = pixels.multipliedReportingOverflow(by: 4)
        return try ImageDecodeResourceEstimate(
            workingSetBytes: bytes.overflow ? Int.max : max(1, bytes.partialValue)
        )
    }

    func prepare(data: Data, limits: DecodeLimits) throws -> ImageDecodePreparation {
        try base.prepare(data: data, limits: limits)
    }

    func decode(
        preparation: ImageDecodePreparation,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage {
        try base.decode(
            preparation: preparation,
            request: request,
            limits: limits
        )
    }

    func discard(_ preparation: ImageDecodePreparation) {
        base.discard(preparation)
    }
}

private struct RecordingRenderedImageCache: RenderedImageCaching {
    private let storage = MemoryCache<RenderedImageCacheKey, DecodedImage>(costLimit: Int.max)

    var currentCost: Int { storage.currentCost }
    var count: Int { storage.count }

    func image(for key: RenderedImageCacheKey) -> DecodedImage? {
        storage.value(for: key)
    }

    func insert(_ image: DecodedImage, for key: RenderedImageCacheKey, cost: Int) {
        storage.insert(image, for: key, cost: cost)
    }

    func remove(_ key: RenderedImageCacheKey) {
        storage.remove(key)
    }

    func removeAll(where predicate: @Sendable (RenderedImageCacheKey) -> Bool) {
        storage.removeAll(where: predicate)
    }

    func removeAllAndReport() -> RenderedImageCacheRemovalSummary {
        let summary = RenderedImageCacheRemovalSummary(
            itemCount: storage.count,
            costBytes: storage.currentCost
        )
        storage.removeAll()
        return summary
    }
}
