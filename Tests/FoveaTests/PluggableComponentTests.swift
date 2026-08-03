import AkashicCore
import AkashicMemory
import Foundation
import FoveaAdvancedSystem
import FoveaCore
import FoveaPersistence
import FoveaStorage
import FoveaSystem
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class PluggableComponentTests: XCTestCase {
    func testPublicCodecContractCanDriveThePipeline_CODEC_PT_010() async throws {
        let body = try makePNG(width: 40, height: 20)
        let codec = DelegatingTestCodec()
        let root = try makeTemporaryDirectory("qualified-codec-pipeline")
        let transport = FakeHTTPTransport(
            stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                    body: body
                )
            ]
        )
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded", isDirectory: true)
            ),
            recordStore: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records", isDirectory: true)
            ),
            profileAccessPolicy: .unrestricted,
            codec: codec
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
            codec: codec,
            renderedImageCache: cache
        )

        XCTAssertEqual(
            system.pipeline.codecDescriptor.identifier.rawValue,
            "test.delegating-codec"
        )
        XCTAssertEqual(cache.count, 0)
    }

    func testQualifiedPersistentStoreProviderDrivesSystemAndRetainsBundle_CACHE_PT_044()
        async throws
    {
        let probe = StoreLifetimeProbe()
        let provider = try QualifiedTestStoreProvider(lifetimeProbe: probe)
        var system: FoveaSystemPipeline? = try await FoveaSystemPipeline.open(
            cacheRoot: try makeTemporaryDirectory("qualified-store-provider"),
            persistentStoreProvider: provider,
            automaticallyPurgesMemoryOnPressure: false,
            codec: DelegatingTestCodec()
        )
        var pipeline: FoveaPipeline? = try XCTUnwrap(system?.pipeline)

        XCTAssertEqual(
            system?.persistentStoreProviderFingerprint,
            provider.descriptor.cacheFingerprint
        )
        XCTAssertFalse(system?.storageGenerationIdentifier.isEmpty ?? true)
        let bundleAlive = await probe.isAlive()
        XCTAssertTrue(bundleAlive)
        let anchorCount = await pipeline?.lifetimeAnchorCountForTesting()
        XCTAssertEqual(anchorCount, 1)

        system = nil
        let retainedAfterWrapperRelease = await probe.isAlive()
        XCTAssertTrue(retainedAfterWrapperRelease)
        pipeline = nil
        try await waitUntil("pipeline 释放 qualified persistent bundle") {
            !(await probe.isAlive())
        }
        let released = await probe.isAlive()
        XCTAssertFalse(released)
    }

    func testQualifiedPersistentStoreProviderRejectsDescriptorSubstitution_CACHE_PT_045()
        async throws
    {
        let provider = try QualifiedTestStoreProvider(
            lifetimeProbe: StoreLifetimeProbe(),
            substitutesDescriptor: true
        )

        do {
            _ = try await FoveaSystemPipeline.open(
                cacheRoot: try makeTemporaryDirectory("qualified-store-mismatch"),
                persistentStoreProvider: provider,
                automaticallyPurgesMemoryOnPressure: false,
                codec: DelegatingTestCodec()
            )
            XCTFail("Provider must not substitute a different bundle descriptor")
        } catch let error as AkashicError {
            XCTAssertEqual(error, .invalidIdentity)
        }
    }

}

private final class StoreLifetimeToken: Sendable {}

private actor StoreLifetimeProbe {
    private weak var token: StoreLifetimeToken?

    func isAlive() -> Bool {
        token != nil
    }

    func capture(_ token: StoreLifetimeToken) {
        self.token = token
    }
}

private actor QualifiedTestStoreProvider: FoveaPersistentStoreBundleProviding {
    nonisolated let descriptor: FoveaPersistentStoreProviderDescriptor

    private let lifetimeProbe: StoreLifetimeProbe
    private let substitutesDescriptor: Bool

    init(
        lifetimeProbe: StoreLifetimeProbe,
        substitutesDescriptor: Bool = false
    ) throws {
        self.descriptor = try FoveaPersistentStoreProviderDescriptor(
            identifier: "test.qualified-store-provider",
            implementationVersion: 1,
            compatibilityFingerprint: "test-qualified-store-v1"
        )
        self.lifetimeProbe = lifetimeProbe
        self.substitutesDescriptor = substitutesDescriptor
    }

    func open(
        root: URL,
        encodedSoftTotalBytes: Int,
        maximumEncodedBlobBytes: Int,
        maximumTrackedNamespaces: Int
    ) async throws -> FoveaQualifiedPersistentStoreBundle {
        let returnedDescriptor =
            substitutesDescriptor
            ? try FoveaPersistentStoreProviderDescriptor(
                identifier: "test.substituted-store-provider",
                implementationVersion: 1,
                compatibilityFingerprint: "test-substituted-store-v1"
            )
            : descriptor
        let generation = try StoreGenerationDescriptor(
            identifier: StoreGenerationID(),
            compatibilityFingerprint: returnedDescriptor.compatibilityFingerprint
        )
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded", isDirectory: true),
            limits: OriginalEncodedStoreLimits(
                softTotalBytes: encodedSoftTotalBytes,
                maximumBlobBytes: maximumEncodedBlobBytes
            )
        )
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records", isDirectory: true)
        )
        let namespaceStore = InMemoryNamespaceGenerationPersistence()
        let namespaceGenerations = FoveaNamespaceGenerationPersistence(
            load: { maximumCount in
                try await namespaceStore.load(maximumCount: maximumCount)
            },
            persist: { generation, namespace in
                try await namespaceStore.persist(generation, for: namespace)
            }
        )
        let lifetime = StoreLifetimeToken()
        await lifetimeProbe.capture(lifetime)
        return try FoveaQualifiedPersistentStoreBundle(
            descriptor: returnedDescriptor,
            generation: generation,
            encoded: encoded,
            records: records,
            namespaceGenerations: namespaceGenerations,
            lifetimeAnchor: lifetime
        )
    }
}

private actor InMemoryNamespaceGenerationPersistence {
    private var generations: [StorageNamespaceFingerprint: UInt64] = [:]

    func load(
        maximumCount: Int
    ) async throws -> [StorageNamespaceFingerprint: UInt64] {
        guard generations.count <= maximumCount else {
            throw AkashicError.invalidIdentity
        }
        return generations
    }

    func persist(
        _ generation: UInt64,
        for namespace: StorageNamespaceFingerprint
    ) async throws {
        if let existing = generations[namespace], generation < existing {
            throw AkashicError.invalidIdentity
        }
        generations[namespace] = generation
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
