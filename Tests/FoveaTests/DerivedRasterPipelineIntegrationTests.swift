import CoreGraphics
import CryptoKit
import Foundation
import FoveaHTTP
import FoveaPersistence
import FoveaStorage
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

@testable import FoveaCore

final class DerivedRasterPipelineIntegrationTests: XCTestCase {
    func testDefaultPipelineDoesNotCreateDerivedArtifacts_W11_PT_031() async throws {
        let fixture = try await makeFixture(derivedConfiguration: nil)
        let request = try fixture.request()

        _ = try await fixture.pipeline.image(for: request)
        _ = await fixture.pipeline.purgeMemoryCache()
        _ = try await fixture.pipeline.image(for: request)
        try await waitUntil("default-off pipeline remains idle") {
            await fixture.pipeline.derivedRasterActiveCreationCountForTesting() == 0
        }

        let derivedRecords = await fixture.derived.recordsForTesting()
        XCTAssertTrue(derivedRecords.isEmpty)
        let requests = await fixture.transport.capturedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testOptInWarmDiskCreatesAndServesDerivedAfterOriginalRemoval_W11_PT_032() async throws {
        let fixture = try await makeFixture(derivedConfiguration: permissiveConfiguration())
        let request = try fixture.request()

        let network = try await fixture.pipeline.image(for: request)
        let networkDigest = try normalizedRGBDigest(network.cgImage)
        let recordsAfterNetwork = await fixture.derived.recordsForTesting()
        let activeAfterNetwork =
            await fixture.pipeline.derivedRasterActiveCreationCountForTesting()
        XCTAssertTrue(recordsAfterNetwork.isEmpty)
        XCTAssertEqual(activeAfterNetwork, 0)
        _ = await fixture.pipeline.purgeMemoryCache()

        let creationBaseline =
            await fixture.pipeline.derivedRasterCreationActivityForTesting()
        let originalWarmDisk = try await fixture.pipeline.image(for: request)
        XCTAssertEqual(try normalizedRGBDigest(originalWarmDisk.cgImage), networkDigest)
        try await waitForDerivedCreation(
            fixture,
            after: creationBaseline,
            description: "derived artifact publication"
        )

        _ = await fixture.pipeline.purgeMemoryCache()
        try await fixture.encoded.remove(
            contentID: ContentID(data: fixture.imageData).description,
            namespace: request.namespace.value
        )

        let derivedWarmDisk = try await fixture.pipeline.image(for: request)
        XCTAssertEqual(try normalizedRGBDigest(derivedWarmDisk.cgImage), networkDigest)
        XCTAssertEqual(derivedWarmDisk.pixelWidth, originalWarmDisk.pixelWidth)
        XCTAssertEqual(derivedWarmDisk.pixelHeight, originalWarmDisk.pixelHeight)
        XCTAssertEqual(derivedWarmDisk.alphaMode, .none)
        let requests = await fixture.transport.capturedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testOptInPreserveSourceSRGBCreatesAndRestoresSourceProfile_W11_PT_055() async throws {
        let fixture = try await makeFixture(derivedConfiguration: permissiveConfiguration())
        let request = try fixture.request(
            namespace: "preserve-source-srgb",
            colorPolicy: .preserveSource
        )

        let network = try await fixture.pipeline.image(for: request)
        let expectedDigest = try normalizedRGBDigest(network.cgImage)
        let expectedColorDescription = network.colorDescription
        XCTAssertEqual(
            expectedColorDescription.outputColorSpaceName,
            CGColorSpace.sRGB as String
        )
        _ = await fixture.pipeline.purgeMemoryCache()

        let creationBaseline =
            await fixture.pipeline.derivedRasterCreationActivityForTesting()
        let originalWarmDisk = try await fixture.pipeline.image(for: request)
        XCTAssertEqual(originalWarmDisk.colorDescription, expectedColorDescription)
        try await waitForDerivedCreation(
            fixture,
            after: creationBaseline,
            description: "preserve-source sRGB derived artifact publication"
        )

        let storedRecords = await fixture.derived.recordsForTesting()
        let storedRecord = try XCTUnwrap(storedRecords.singleElement)
        XCTAssertTrue(storedRecord.formatIdentifier.contains("preserve-srgb"))
        XCTAssertEqual(
            storedRecord.pixelLayoutFingerprint,
            DerivedRasterContainer.formatIdentity.pixelLayoutFingerprint
        )

        _ = await fixture.pipeline.purgeMemoryCache()
        try await fixture.encoded.remove(
            contentID: ContentID(data: fixture.imageData).description,
            namespace: request.namespace.value
        )

        let derivedWarmDisk = try await fixture.pipeline.image(for: request)
        XCTAssertEqual(try normalizedRGBDigest(derivedWarmDisk.cgImage), expectedDigest)
        XCTAssertEqual(derivedWarmDisk.colorDescription, expectedColorDescription)
        XCTAssertEqual(derivedWarmDisk.alphaMode, .none)
        let requests = await fixture.transport.capturedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testOptInNoStoreNeverCreatesDerivedArtifacts_W11_PT_035() async throws {
        let fixture = try await makeFixture(
            derivedConfiguration: permissiveConfiguration(),
            cacheControl: "no-store",
            responseCount: 2
        )
        let request = try fixture.request(namespace: "no-store")

        _ = try await fixture.pipeline.image(for: request)
        _ = await fixture.pipeline.purgeMemoryCache()
        _ = try await fixture.pipeline.image(for: request)
        try await waitUntil("no-store derived runtime remains idle") {
            await fixture.pipeline.derivedRasterActiveCreationCountForTesting() == 0
        }

        let derivedRecords = await fixture.derived.recordsForTesting()
        let requests = await fixture.transport.capturedRequests()
        XCTAssertTrue(derivedRecords.isEmpty)
        XCTAssertEqual(requests.count, 2)
    }

    func testCorruptDerivedArtifactFallsBackToOriginalAndIsQuarantined_W11_PT_036()
        async throws
    {
        let fixture = try await makeFixture(derivedConfiguration: permissiveConfiguration())
        let request = try fixture.request(namespace: "corrupt-derived")

        let network = try await fixture.pipeline.image(for: request)
        let expectedDigest = try normalizedRGBDigest(network.cgImage)
        _ = await fixture.pipeline.purgeMemoryCache()
        let creationBaseline =
            await fixture.pipeline.derivedRasterCreationActivityForTesting()
        _ = try await fixture.pipeline.image(for: request)
        try await waitForDerivedCreation(
            fixture,
            after: creationBaseline,
            description: "derived artifact before corruption"
        )

        let storedRecords = await fixture.derived.recordsForTesting()
        let record = try XCTUnwrap(storedRecords.singleElement)
        let physicalValue = await fixture.derived.physicalIDForTesting(record)
        let physical = try XCTUnwrap(physicalValue)
        let blobURL = fixture.root
            .appendingPathComponent("derived", isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(physical.rawValue.uuidString.lowercased())
        var corrupted = try Data(contentsOf: blobURL)
        corrupted[corrupted.count - 1] ^= 0xFF
        try corrupted.write(to: blobURL)
        _ = await fixture.pipeline.purgeMemoryCache()

        let recovered = try await fixture.pipeline.image(for: request)
        XCTAssertEqual(try normalizedRGBDigest(recovered.cgImage), expectedDigest)
        let events = await fixture.diagnostics.snapshot().map(\.event)
        XCTAssertTrue(
            events.contains {
                $0.kind == .cacheReadFailed && $0.reason == "derived-raster-read-invalid"
            }
        )
        let requests = await fixture.transport.capturedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testDurableWriteBudgetRejectsPublicationWithSpecificDiagnostic_W11_PT_045() async throws {
        let fixture = try await makeFixture(
            derivedConfiguration: permissiveConfiguration(),
            derivedWriteBudgetBytes: 1
        )
        let request = try fixture.request(namespace: "write-budget")

        _ = try await fixture.pipeline.image(for: request)
        _ = await fixture.pipeline.purgeMemoryCache()
        let baseline = await fixture.pipeline.derivedRasterCreationActivityForTesting()
        _ = try await fixture.pipeline.image(for: request)
        let completed = await fixture.pipeline.waitForDerivedRasterCreationForTesting(
            after: baseline)

        XCTAssertGreaterThan(completed.terminalCount, baseline.terminalCount)
        XCTAssertEqual(completed.activeCount, 0)
        let records = await fixture.derived.recordsForTesting()
        XCTAssertTrue(records.isEmpty)
        let events = await fixture.diagnostics.snapshot().map(\.event)
        let budgetEvent = events.first {
            $0.kind == .cacheWriteFailed
                && $0.reason == "derived-raster-global-write-budget"
        }
        XCTAssertNotNil(budgetEvent)
        XCTAssertGreaterThan(budgetEvent?.byteCount ?? 0, 1)
    }

    func testNamespaceRevokeRemovesPublishedDerivedArtifacts_W11_PT_033() async throws {
        let fixture = try await makeFixture(derivedConfiguration: permissiveConfiguration())
        let request = try fixture.request(namespace: "account-revoke")

        _ = try await fixture.pipeline.image(for: request)
        _ = await fixture.pipeline.purgeMemoryCache()
        let creationBaseline =
            await fixture.pipeline.derivedRasterCreationActivityForTesting()
        _ = try await fixture.pipeline.image(for: request)
        try await waitForDerivedCreation(
            fixture,
            after: creationBaseline,
            description: "derived artifact before revoke"
        )

        try await fixture.pipeline.revoke(namespace: request.namespace)

        let records = await fixture.derived.recordsForTesting()
        XCTAssertTrue(records.isEmpty)
        let activeCreationCount =
            await fixture.pipeline.derivedRasterActiveCreationCountForTesting()
        XCTAssertEqual(activeCreationCount, 0)
    }

    private struct Fixture {
        let root: URL
        let imageData: Data
        let pipeline: FoveaPipeline
        let transport: FakeHTTPTransport
        let encoded: AkashicOriginalEncodedStore
        let derived: AkashicDerivedRasterStore
        let diagnostics: BoundedDiagnosticsSink

        func request(
            namespace: String = "public",
            colorPolicy: ImageColorPolicy = .convertToSRGB
        ) throws -> ImageRequest {
            try ImageRequest(
                url: XCTUnwrap(URL(string: "https://example.test/hero.jpg")),
                logicalSource: LogicalSourceID("asset:derived-integration"),
                target: TargetPixels(width: 1170, height: 780),
                colorPolicy: colorPolicy,
                namespace: SecurityNamespaceID(namespace)
            )
        }
    }

    private func makeFixture(
        derivedConfiguration: DerivedRasterRuntimeConfiguration?,
        cacheControl: String = "public, max-age=3600",
        responseCount: Int = 1,
        derivedWriteBudgetBytes: Int = 1024 * 1024 * 1024
    ) async throws -> Fixture {
        let root = try makeTemporaryDirectory("derived-runtime-\(UUID().uuidString)")
        let imageData = try BenchmarkFixtureCatalog.load(
            named: "hero-48mp-8000x6000.jpg"
        ).data
        let stub = FakeHTTPTransport.Stub(
            statusCode: 200,
            headers: [
                "Content-Type": "image/jpeg",
                "Cache-Control": cacheControl,
            ],
            body: imageData
        )
        let transport = FakeHTTPTransport(
            stubs: Array(repeating: stub, count: max(1, responseCount))
        )
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"),
            softLimitBytes: 64 * 1024 * 1024
        )
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let derived = try await AkashicDerivedRasterStore.open(
            root: root.appendingPathComponent("derived"),
            limits: DerivedRasterStoreLimits(
                softTotalBytes: 64 * 1024 * 1024,
                maximumBlobBytes: 32 * 1024 * 1024,
                maximumWriteBytesPerWindow: derivedWriteBudgetBytes,
                writeBudgetWindowNanoseconds: 60_000_000_000
            )
        )
        let namespaceRegistry = NamespaceRegistry()
        let diagnostics = BoundedDiagnosticsSink(capacity: 64)
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: encoded,
            recordStore: records,
            namespaceRegistry: namespaceRegistry,
            diagnostics: diagnostics,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder(),
            derivedRasterStore: derived,
            derivedRasterConfiguration: derivedConfiguration,
            derivedRasterCostEstimator: FixedDerivedRasterCostEstimator()
        )
        return Fixture(
            root: root,
            imageData: imageData,
            pipeline: pipeline,
            transport: transport,
            encoded: encoded,
            derived: derived,
            diagnostics: diagnostics
        )
    }

    private func waitForDerivedCreation(
        _ fixture: Fixture,
        after baseline: DerivedRasterCreationActivity,
        description: String
    ) async throws {
        let registered =
            await fixture.pipeline.derivedRasterCreationActivityForTesting()
        guard registered.scheduledCount > baseline.scheduledCount else {
            XCTFail("派生创建未登记：\(description)")
            return
        }
        let completed =
            await fixture.pipeline.waitForDerivedRasterCreationForTesting(after: baseline)
        XCTAssertGreaterThan(completed.terminalCount, baseline.terminalCount)
        XCTAssertEqual(completed.activeCount, 0)

        let records = await fixture.derived.recordsForTesting()
        guard records.count == 1 else {
            let reasons = await fixture.diagnostics.snapshot().compactMap { entry in
                entry.event.kind == .cacheWriteFailed ? entry.event.reason : nil
            }
            XCTFail("派生创建未发布：\(reasons)")
            return
        }
    }

    private func permissiveConfiguration() -> DerivedRasterRuntimeConfiguration {
        DerivedRasterRuntimeConfiguration(
            maximumContainerBytes: 32 * 1024 * 1024,
            maximumContainerToOriginalPermille: 10000,
            maximumCreationNanoseconds: 30_000_000_000,
            estimatedPersistentReadOverheadNanoseconds: 0,
            safetyMarginHits: 0,
            maximumConcurrentCreations: 1,
            maximumQueuedCreations: 2
        )
    }
}

private func normalizedRGBDigest(_ image: CGImage) throws -> String {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw DerivedRasterContainerError.invalidInput
    }
    let bytesPerRow = image.width * 4
    var pixels = Data(count: bytesPerRow * image.height)
    let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let address = raw.baseAddress,
            let context = CGContext(
                data: address,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            )
        else { return false }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    guard rendered else { throw DerivedRasterContainerError.invalidInput }
    var rgb = Data(capacity: image.width * image.height * 3)
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        rgb.append(pixels[offset])
        rgb.append(pixels[offset + 1])
        rgb.append(pixels[offset + 2])
    }
    return SHA256.hash(data: rgb).map { String(format: "%02x", $0) }.joined()
}

private struct FixedDerivedRasterCostEstimator: DerivedRasterCostEstimating {
    func estimate(
        key _: DerivedRasterArtifactKey,
        measuredOriginalDecodeNanoseconds _: UInt64,
        measuredDerivedReadNanoseconds _: UInt64
    ) -> DerivedRasterCostEstimate? {
        DerivedRasterCostEstimate(
            originalDecodeNanoseconds: 60_000_000_000,
            derivedReadNanoseconds: 1
        )
    }
}
