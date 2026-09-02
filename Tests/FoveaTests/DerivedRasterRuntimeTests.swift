import AkashicCore
import CoreGraphics
import CryptoKit
import Foundation
import FoveaHTTP
import FoveaStorage
import ImageCraftCore
import XCTest

@testable import FoveaCore

final class DerivedRasterRuntimeTests: XCTestCase {
    func testTransientStoreFailureFallsBackWithoutDeletingAlias_W11_PT_038() async throws {
        let fixture = try await makeFixture(mode: .fail(.storageUnavailable))

        let loaded = try await fixture.runtime.load(key: fixture.key)

        XCTAssertNil(loaded)
        let removeCount = await fixture.store.removeCount()
        XCTAssertEqual(removeCount, 0)
        let reasons = await fixture.diagnostics.snapshot().compactMap(\.event.reason)
        XCTAssertTrue(reasons.contains("derived-raster-store-read-failed"))
    }

    func testCancellationPropagatesWithoutDeletingAlias_W11_PT_039() async throws {
        let fixture = try await makeFixture(mode: .sleep)
        let task = Task {
            try await fixture.runtime.load(key: fixture.key)
        }
        try await waitUntil("derived store read started") {
            await fixture.store.hasStarted()
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled derived read must throw")
        } catch is CancellationError {
            // 取消保留为顶层请求语义。
        }
        let removeCount = await fixture.store.removeCount()
        XCTAssertEqual(removeCount, 0)
    }

    func testHotContainerServesRepeatedLoadsWithoutStoreReads_W11_PT_059() async throws {
        let fixture = try await makeFixture(mode: .artifact(trusted: true))

        let first = try await requiredLoad(fixture)
        let firstPixels = try materializedRGBA(first.image.cgImage)
        let firstLoadCount = await fixture.store.loadCount()
        XCTAssertEqual(firstLoadCount, 1)

        let second = try await requiredLoad(fixture)
        XCTAssertEqual(try materializedRGBA(second.image.cgImage), firstPixels)
        let secondLoadCount = await fixture.store.loadCount()
        XCTAssertEqual(secondLoadCount, 1)

        let third = try await requiredLoad(fixture)
        XCTAssertEqual(try materializedRGBA(third.image.cgImage), firstPixels)
        let thirdLoadCount = await fixture.store.loadCount()
        XCTAssertEqual(thirdLoadCount, 1)
        XCTAssertEqual(fixture.runtime.purgeHotContainers(), 1)
    }

    func testHotContainerPurgeRestoresPersistentRead_W11_PT_061() async throws {
        let fixture = try await makeFixture(mode: .artifact(trusted: true))

        let firstResult = try await fixture.runtime.load(key: fixture.key)
        _ = try XCTUnwrap(firstResult)
        _ = try await requiredLoad(fixture)
        XCTAssertEqual(fixture.runtime.purgeHotContainers(), 1)

        _ = try await requiredLoad(fixture)
        let afterPurgeLoadCount = await fixture.store.loadCount()
        XCTAssertEqual(afterPurgeLoadCount, 2)
    }

    func testNamespaceRevokeEvictsHotContainerBeforeNextLoad_W11_PT_060() async throws {
        let fixture = try await makeFixture(mode: .artifact(trusted: true))

        _ = try await requiredLoad(fixture)
        let beforeRevokeCount = await fixture.store.loadCount()
        XCTAssertEqual(beforeRevokeCount, 1)

        _ = await fixture.runtime.revoke(namespaceFingerprint: fixture.key.namespaceFingerprint)

        _ = try await requiredLoad(fixture)
        let afterRevokeCount = await fixture.store.loadCount()
        XCTAssertEqual(afterRevokeCount, 2)
    }

    func testUntrustedStoreForcesFullValidationAndDoesNotSeedHotTier_W11_PT_065()
        async throws
    {
        let fixture = try await makeFixture(mode: .artifact(trusted: false))

        let first = try await requiredLoad(fixture)
        let firstPixels = try materializedRGBA(first.image.cgImage)
        let second = try await requiredLoad(fixture)
        XCTAssertEqual(try materializedRGBA(second.image.cgImage), firstPixels)
        let loadCount = await fixture.store.loadCount()
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(fixture.runtime.purgeHotContainers(), 0)
    }

    func testUntrustedStoreRejectsReboundOuterIdentityWithWrongPixelDigest_W11_PT_066()
        async throws
    {
        let fixture = try await makeFixture(mode: .artifact(trusted: false))
        try await fixture.store.tamperPixelDigestAndRebindOuterIdentity()

        let loaded = try await fixture.runtime.load(key: fixture.key)
        XCTAssertNil(loaded)
        let removeCount = await fixture.store.removeCount()
        XCTAssertEqual(removeCount, 1)
    }

    private struct Fixture {
        let runtime: DerivedRasterRuntime
        let store: RuntimeTestDerivedStore
        let diagnostics: BoundedDiagnosticsSink
        let request: ImageRequest
        let representation: RepresentationRecord
        let generation: NamespaceGeneration
        let key: DerivedRasterArtifactKey
        let now: Date
    }

    private func makeFixture(mode: RuntimeTestDerivedStore.Mode) async throws -> Fixture {
        let request = try ImageRequest(
            url: XCTUnwrap(URL(string: "https://example.test/runtime.jpg")),
            logicalSource: LogicalSourceID("asset:runtime"),
            target: TargetPixels(width: 31, height: 19),
            colorPolicy: .convertToSRGB,
            namespace: SecurityNamespaceID("runtime-account")
        )
        let registry = NamespaceRegistry()
        let generation = try await registry.generation(for: request.storageNamespaceFingerprint)
        let contentID = ContentID(data: Data("runtime-original".utf8))
        let now = Date(timeIntervalSinceReferenceDate: 2000)
        let representation = RepresentationRecord(
            securityNamespace: request.namespace.value,
            namespaceGeneration: generation.value,
            baseKeyDigest: request.fetchBaseDigest,
            variantKeyDigest: request.fetchVariantKey.digestHex,
            statusCode: 200,
            requestTime: now.addingTimeInterval(-2),
            responseTime: now.addingTimeInterval(-1),
            responseDate: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(3600),
            etag: nil,
            lastModified: nil,
            disposition: .reusable,
            contentID: contentID.description,
            payloadLength: contentID.byteCount,
            contentType: "image/jpeg"
        )
        let renderKey = RenderKey(
            decodeKey: DecodeKey(
                contentID: contentID,
                targetWidth: request.target.width,
                targetHeight: request.target.height,
                contentMode: request.contentMode,
                geometryPolicyFingerprint: request.geometryPolicyFingerprint,
                colorPolicy: request.colorPolicy,
                codecContractVersion: 1,
                codecFingerprint: "runtime-test-codec-v1"
            ),
            renderVersion: 1
        )
        let key = try XCTUnwrap(
            DerivedRasterArtifactKey(
                request: request,
                representation: representation,
                namespaceGeneration: generation,
                renderKey: renderKey,
                format: DerivedRasterContainer.formatIdentity
            )
        )
        let store = RuntimeTestDerivedStore(mode: mode)
        let diagnostics = BoundedDiagnosticsSink(capacity: 16)
        let runtime = DerivedRasterRuntime(
            configuration: DerivedRasterRuntimeConfiguration(
                maximumContainerBytes: 1024 * 1024,
                maximumContainerToOriginalPermille: 1000,
                maximumCreationNanoseconds: 1_000_000,
                estimatedPersistentReadOverheadNanoseconds: 0
            ),
            store: store,
            namespaceRegistry: registry,
            diagnostics: diagnostics,
            clock: SystemWallClock()
        )
        if case .artifact(let trusted) = mode {
            var rgb = Data(count: request.target.width * request.target.height * 3)
            for pixel in 0..<(request.target.width * request.target.height) {
                let offset = pixel * 3
                rgb[offset] = 0x6d
                rgb[offset + 1] = 0x8f
                rgb[offset + 2] = 0xb1
            }
            let container = try DerivedRasterContainer.encode(
                pixelData: rgb,
                width: request.target.width,
                height: request.target.height,
                format: key.format
            )
            let containerContentID = ContentID(data: container)
            let pixelDigestHex = SHA256.hash(data: rgb)
                .map { String(format: "%02x", $0) }.joined()
            let artifactRecord = try DerivedRasterRecord(
                artifactKeyDigest: key.digestHex,
                baseKeyDigest: key.baseKeyDigest,
                variantKeyDigest: key.variantKeyDigest,
                namespaceFingerprint: key.namespaceFingerprint,
                namespaceGeneration: key.namespaceGeneration.value,
                containerContentID: containerContentID.description,
                containerByteCount: container.count,
                formatIdentifier: key.format.identifier,
                formatSemanticVersion: key.format.semanticVersion,
                pixelLayoutFingerprint: key.format.pixelLayoutFingerprint,
                pixelDigestHex: pixelDigestHex,
                pixelWidth: request.target.width,
                pixelHeight: request.target.height,
                createdAt: now
            )
            await store.install(
                DerivedRasterStoredArtifact(
                    record: artifactRecord,
                    container: container,
                    recordValidated: trusted,
                    containerContentDigestVerified: trusted
                )
            )
        }
        return Fixture(
            runtime: runtime,
            store: store,
            diagnostics: diagnostics,
            request: request,
            representation: representation,
            generation: generation,
            key: key,
            now: now
        )
    }

    private func requiredLoad(_ fixture: Fixture) async throws -> DerivedRasterLoadedImage {
        let loaded = try await fixture.runtime.load(key: fixture.key)
        return try XCTUnwrap(loaded)
    }

    private func materializedRGBA(_ image: CGImage) throws -> Data {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bytesPerRow = image.width * 4
        var pixels = Data(count: bytesPerRow * image.height)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let base = storage.baseAddress,
                let context = CGContext(
                    data: base,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                )
            else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        XCTAssertTrue(rendered)
        return pixels
    }
}

private actor RuntimeTestDerivedStore: DerivedRasterStoring {
    enum Mode: Sendable {
        case fail(AkashicError)
        case sleep
        case artifact(trusted: Bool)
    }

    private let mode: Mode
    private var started = false
    private var removals = 0
    private var loads = 0
    private var artifact: DerivedRasterStoredArtifact?

    init(mode: Mode) {
        self.mode = mode
    }

    func load(
        artifactKeyDigest _: String,
        namespaceFingerprint _: StorageNamespaceFingerprint,
        namespaceGeneration _: UInt64
    ) async throws -> DerivedRasterStoredArtifact? {
        started = true
        loads += 1
        switch mode {
        case .fail(let error): throw error
        case .sleep:
            try await testSleep(.seconds(30))
            return nil
        case .artifact:
            return artifact
        }
    }

    func commit(
        container _: Data,
        record _: DerivedRasterRecord,
        publicationPermission _: any DerivedRasterPublicationPermission
    ) async throws {}

    func remove(
        artifactKeyDigest _: String,
        namespaceFingerprint _: StorageNamespaceFingerprint,
        namespaceGeneration _: UInt64
    ) async throws {
        removals += 1
    }

    func removeAll(namespaceFingerprint _: StorageNamespaceFingerprint) async throws {}

    func removeAll(
        variantKeyDigest _: String,
        namespaceFingerprint _: StorageNamespaceFingerprint,
        namespaceGeneration _: UInt64
    ) async throws {}

    func install(_ artifact: DerivedRasterStoredArtifact) {
        self.artifact = artifact
    }

    func tamperPixelDigestAndRebindOuterIdentity() throws {
        guard let artifact else { throw AkashicError.notFound }
        var container = artifact.container
        guard container.count > 87 else { throw AkashicError.integrityMismatch }
        container[56] ^= 0xff
        let pixelDigestHex = container[56..<88]
            .map { String(format: "%02x", $0) }.joined()
        let contentID = ContentID(data: container)
        let record = artifact.record
        let rebound = try DerivedRasterRecord(
            artifactKeyDigest: record.artifactKeyDigest,
            baseKeyDigest: record.baseKeyDigest,
            variantKeyDigest: record.variantKeyDigest,
            namespaceFingerprint: record.namespaceFingerprint,
            namespaceGeneration: record.namespaceGeneration,
            containerContentID: contentID.description,
            containerByteCount: container.count,
            formatIdentifier: record.formatIdentifier,
            formatSemanticVersion: record.formatSemanticVersion,
            pixelLayoutFingerprint: record.pixelLayoutFingerprint,
            pixelDigestHex: pixelDigestHex,
            pixelWidth: record.pixelWidth,
            pixelHeight: record.pixelHeight,
            createdAt: record.createdAt
        )
        self.artifact = DerivedRasterStoredArtifact(record: rebound, container: container)
    }

    func loadCount() -> Int {
        loads
    }

    func hasStarted() -> Bool {
        started
    }

    func removeCount() -> Int {
        removals
    }
}
