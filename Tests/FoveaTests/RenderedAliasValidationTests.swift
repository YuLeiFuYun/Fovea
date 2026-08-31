import FoveaHTTP
import FoveaPersistence
import ImageCraftCore
import ImageCraftImageIO
import XCTest

@testable import FoveaCore

final class RenderedAliasValidationTests: XCTestCase {
    func testOnlyValidatedImmutableRecordCanPublishRenderedAlias_CACHE_PT_054() async throws {
        let root = try makeTemporaryDirectory("rendered-alias-validation")
        defer { try? FileManager.default.removeItem(at: root) }
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded")
        )
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let registry = NamespaceRegistry(maximumTrackedNamespaces: 16)
        let cache = PipelineCache(
            encodedStore: encoded,
            recordStore: records,
            memoryCostLimit: 1_024 * 1_024,
            transportVerifiedEncodedHandoffCostLimit: 1_024 * 1_024,
            mutationQueueLimit: 16,
            namespaceRegistry: registry,
            diagnostics: NullDiagnosticsSink()
        )
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/alias.png")),
            target: try TargetPixels(width: 32, height: 32),
            colorPolicy: .convertToSRGB,
            appID: "rendered-alias-validation"
        )
        let generation = NamespaceGeneration(0)
        let data = try makePNG(width: 32, height: 32)
        let decoder = ImageIOImageDecoder()
        let limits = DecodeLimits.coreV1
        let probe = try decoder.probe(data: data, limits: limits)
        let image = try decoder.decode(
            data: data,
            probe: probe,
            request: ImageDecodeRequest(
                target: request.target,
                contentMode: request.contentMode,
                colorPolicy: request.colorPolicy
            ),
            limits: limits
        )
        let decodeKey = DecodeKey(
            contentID: ContentID(data: data),
            targetWidth: request.target.width,
            targetHeight: request.target.height,
            contentMode: request.contentMode,
            geometryPolicyFingerprint: request.geometryPolicyFingerprint,
            colorPolicy: request.colorPolicy,
            codecContractVersion: decoder.codecDescriptor.contractVersion,
            codecFingerprint: decoder.codecDescriptor.cacheFingerprint
        )
        let scoped = ScopedRenderKey(
            namespace: request.namespace,
            generation: generation,
            renderKey: RenderKey(decodeKey: decodeKey, renderVersion: 1)
        )
        await cache.insertRendered(image, for: scoped)

        let invalid = makeRepresentationRecord(
            recordSchemaVersion: RepresentationRecord.currentSchemaVersion + 1,
            namespace: request.namespace.value,
            namespaceGeneration: generation.value,
            baseKeyDigest: request.fetchBaseKey.digestHex,
            variantKeyDigest: request.fetchVariantKey.digestHex,
            expiresAt: Date().addingTimeInterval(60),
            contentID: ContentID(data: data).description,
            payloadLength: data.count
        )
        try await cache.insertRenderedAlias(
            for: request,
            generation: generation,
            renderKey: scoped,
            representation: invalid
        )
        let rejected = await cache.renderedImage(
            for: request,
            generation: generation,
            currentDate: { Date() }
        )
        XCTAssertNil(rejected)

        let valid = makeRepresentationRecord(
            namespace: request.namespace.value,
            namespaceGeneration: generation.value,
            baseKeyDigest: request.fetchBaseKey.digestHex,
            variantKeyDigest: request.fetchVariantKey.digestHex,
            expiresAt: Date().addingTimeInterval(60),
            contentID: ContentID(data: data).description,
            payloadLength: data.count
        )
        try await cache.insertRenderedAlias(
            for: request,
            generation: generation,
            renderKey: scoped,
            representation: valid
        )
        let accepted = await cache.renderedImage(
            for: request,
            generation: generation,
            currentDate: { Date() }
        )
        XCTAssertEqual(accepted?.pixelWidth, image.pixelWidth)
        XCTAssertEqual(accepted?.pixelHeight, image.pixelHeight)
    }
}
