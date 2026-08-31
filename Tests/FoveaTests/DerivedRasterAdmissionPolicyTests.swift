import Foundation
import FoveaCore
import FoveaHTTP
import ImageCraftCore
import XCTest

final class DerivedRasterAdmissionPolicyTests: XCTestCase {
    func testArtifactIdentityBindsRepresentationRenderNamespaceAndFormat_W11_PT_001() throws {
        let fixture = try makeFixture()
        let first = try XCTUnwrap(
            DerivedRasterArtifactKey(
                request: fixture.request,
                representation: fixture.record,
                namespaceGeneration: fixture.generation,
                renderKey: fixture.renderKey,
                format: fixture.format
            )
        )
        let same = try XCTUnwrap(
            DerivedRasterArtifactKey(
                request: fixture.request,
                representation: fixture.record,
                namespaceGeneration: fixture.generation,
                renderKey: fixture.renderKey,
                format: fixture.format
            )
        )
        XCTAssertEqual(first, same)
        XCTAssertEqual(first.digestHex.count, 64)

        let changedFormat = try XCTUnwrap(
            DerivedRasterFormatIdentity(
                identifier: "imagecraft-adaptive-row-lzfse",
                semanticVersion: 2,
                pixelLayoutFingerprint: "rgb8-srgb-row-major-v1"
            )
        )
        let changedFormatKey = try XCTUnwrap(
            DerivedRasterArtifactKey(
                request: fixture.request,
                representation: fixture.record,
                namespaceGeneration: fixture.generation,
                renderKey: fixture.renderKey,
                format: changedFormat
            )
        )
        XCTAssertNotEqual(first.digestHex, changedFormatKey.digestHex)

        let changedVariant = makeRecord(
            request: fixture.request,
            contentID: fixture.contentID,
            generation: fixture.generation,
            variantDigest: String(repeating: "b", count: 64)
        )
        let changedVariantKey = try XCTUnwrap(
            DerivedRasterArtifactKey(
                request: fixture.request,
                representation: changedVariant,
                namespaceGeneration: fixture.generation,
                renderKey: fixture.renderKey,
                format: fixture.format
            )
        )
        XCTAssertNotEqual(first.digestHex, changedVariantKey.digestHex)

        let changedRenderKey = RenderKey(
            decodeKey: fixture.renderKey.decodeKey,
            transformerFingerprint: "rounded-corners-v2",
            renderVersion: 1
        )
        let changedRender = try XCTUnwrap(
            DerivedRasterArtifactKey(
                request: fixture.request,
                representation: fixture.record,
                namespaceGeneration: fixture.generation,
                renderKey: changedRenderKey,
                format: fixture.format
            )
        )
        XCTAssertNotEqual(first.digestHex, changedRender.digestHex)
    }

    func testAdmissionRequiresBackgroundFreshActiveStablePersistence_W11_PT_002() throws {
        let fixture = try makeFixture()
        let now = Date(timeIntervalSinceReferenceDate: 10_000)

        XCTAssertEqual(
            evaluate(fixture, now: now, creationRunsInBackground: false),
            .reject(.foregroundCreation)
        )
        XCTAssertEqual(
            evaluate(fixture, now: now, namespaceIsActive: false),
            .reject(.inactiveNamespace)
        )

        let stale = makeRecord(
            request: fixture.request,
            contentID: fixture.contentID,
            generation: fixture.generation,
            expiresAt: now.addingTimeInterval(-1)
        )
        XCTAssertEqual(
            evaluate(fixture, record: stale, now: now),
            .reject(.staleRepresentation)
        )

        let noStore = makeRecord(
            request: fixture.request,
            contentID: fixture.contentID,
            generation: fixture.generation,
            disposition: .noStore
        )
        XCTAssertEqual(
            evaluate(fixture, record: noStore, now: now),
            .reject(.invalidArtifactIdentity)
        )

        let transientRequest = try ImageRequest(
            url: fixture.request.url,
            logicalSource: fixture.request.logicalSource,
            target: fixture.request.target,
            contentMode: fixture.request.contentMode,
            geometryPolicyFingerprint: fixture.request.geometryPolicyFingerprint,
            colorPolicy: fixture.request.colorPolicy,
            renderCacheAdmission: .transient,
            namespace: fixture.request.namespace
        )
        XCTAssertEqual(
            DerivedRasterAdmissionPolicy.evaluate(
                request: transientRequest,
                representation: fixture.record,
                namespaceGeneration: fixture.generation,
                namespaceIsActive: true,
                renderKey: fixture.renderKey,
                format: fixture.format,
                now: now,
                creationRunsInBackground: true,
                observedReuseHits: 20,
                originalDecodeNanoseconds: 30,
                derivedReadNanoseconds: 5,
                creationNanoseconds: 100,
                maximumCreationNanoseconds: 1_000,
                derivedByteCount: 1_024,
                maximumDerivedByteCount: 4_096
            ),
            .reject(.invalidArtifactIdentity)
        )
    }

    func testAdmissionUsesCeilingAmortizationAndSafetyMargin_W11_PT_003() throws {
        let fixture = try makeFixture()
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        // 每次命中节省 8 ns；ceil(50 / 8) = 7，再加一次安全命中得到 8。
        XCTAssertEqual(
            evaluate(
                fixture,
                now: now,
                observedReuseHits: 7,
                originalDecodeNanoseconds: 10,
                derivedReadNanoseconds: 2,
                creationNanoseconds: 50
            ),
            .reject(.insufficientObservedReuse(required: 8, observed: 7))
        )

        let admitted = evaluate(
            fixture,
            now: now,
            observedReuseHits: 8,
            originalDecodeNanoseconds: 10,
            derivedReadNanoseconds: 2,
            creationNanoseconds: 50
        )
        guard case .admit(let key, let required) = admitted else {
            return XCTFail("Expected admission, got \(admitted)")
        }
        XCTAssertEqual(required, 8)
        XCTAssertEqual(key.renderKey, fixture.renderKey)
    }

    func testAdmissionRejectsNoSavingsBudgetAndGenerationMismatch_W11_PT_004() throws {
        let fixture = try makeFixture()
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        XCTAssertEqual(
            evaluate(
                fixture,
                now: now,
                creationNanoseconds: 1_001,
                maximumCreationNanoseconds: 1_000
            ),
            .reject(.creationBudgetExceeded(actual: 1_001, maximum: 1_000))
        )
        XCTAssertEqual(
            evaluate(
                fixture,
                now: now,
                originalDecodeNanoseconds: 5,
                derivedReadNanoseconds: 5
            ),
            .reject(.noReadSavings)
        )
        XCTAssertEqual(
            evaluate(
                fixture,
                now: now,
                derivedByteCount: 4_097,
                maximumDerivedByteCount: 4_096
            ),
            .reject(.byteBudgetExceeded(actual: 4_097, maximum: 4_096))
        )
        XCTAssertEqual(
            DerivedRasterAdmissionPolicy.evaluate(
                request: fixture.request,
                representation: fixture.record,
                namespaceGeneration: NamespaceGeneration(fixture.generation.value + 1),
                namespaceIsActive: true,
                renderKey: fixture.renderKey,
                format: fixture.format,
                now: now,
                creationRunsInBackground: true,
                observedReuseHits: 20,
                originalDecodeNanoseconds: 30,
                derivedReadNanoseconds: 5,
                creationNanoseconds: 100,
                maximumCreationNanoseconds: 1_000,
                derivedByteCount: 1_024,
                maximumDerivedByteCount: 4_096
            ),
            .reject(.invalidArtifactIdentity)
        )
    }

    func testReuseRevalidatesCurrentHTTPPermissionAndGeneration_W11_PT_006() throws {
        let fixture = try makeFixture()
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let key = try XCTUnwrap(
            DerivedRasterArtifactKey(
                request: fixture.request,
                representation: fixture.record,
                namespaceGeneration: fixture.generation,
                renderKey: fixture.renderKey,
                format: fixture.format
            )
        )
        XCTAssertTrue(
            DerivedRasterReusePolicy.permits(
                key: key,
                request: fixture.request,
                currentRepresentation: fixture.record,
                namespaceGeneration: fixture.generation,
                namespaceIsActive: true,
                now: now
            )
        )

        let noStore = makeRecord(
            request: fixture.request,
            contentID: fixture.contentID,
            generation: fixture.generation,
            disposition: .noStore
        )
        XCTAssertFalse(
            DerivedRasterReusePolicy.permits(
                key: key,
                request: fixture.request,
                currentRepresentation: noStore,
                namespaceGeneration: fixture.generation,
                namespaceIsActive: true,
                now: now
            )
        )

        let mustRevalidate = makeRecord(
            request: fixture.request,
            contentID: fixture.contentID,
            generation: fixture.generation,
            requiresRevalidation: true
        )
        XCTAssertFalse(
            DerivedRasterReusePolicy.permits(
                key: key,
                request: fixture.request,
                currentRepresentation: mustRevalidate,
                namespaceGeneration: fixture.generation,
                namespaceIsActive: true,
                now: now
            )
        )
        XCTAssertFalse(
            DerivedRasterReusePolicy.permits(
                key: key,
                request: fixture.request,
                currentRepresentation: fixture.record,
                namespaceGeneration: NamespaceGeneration(fixture.generation.value + 1),
                namespaceIsActive: true,
                now: now
            )
        )
        XCTAssertFalse(
            DerivedRasterReusePolicy.permits(
                key: key,
                request: fixture.request,
                currentRepresentation: fixture.record,
                namespaceGeneration: fixture.generation,
                namespaceIsActive: false,
                now: now
            )
        )
    }

    func testAdmissionRejectsMandatoryRevalidation_W11_PT_007() throws {
        let fixture = try makeFixture()
        let record = makeRecord(
            request: fixture.request,
            contentID: fixture.contentID,
            generation: fixture.generation,
            requiresRevalidation: true
        )
        XCTAssertEqual(
            evaluate(
                fixture,
                record: record,
                now: Date(timeIntervalSinceReferenceDate: 10_000)
            ),
            .reject(.requiresRevalidation)
        )
    }

    func testAdmissionRejectsSRGBContainerForPreserveSource_W11_PT_026() throws {
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/p3.jpg")),
            logicalSource: LogicalSourceID("asset:p3:1"),
            target: try TargetPixels(width: 780, height: 520),
            colorPolicy: .preserveSource,
            appID: "derived-policy-tests"
        )
        let generation = NamespaceGeneration(1)
        let contentID = ContentID(data: Data("p3-original".utf8))
        let record = makeRecord(
            request: request,
            contentID: contentID,
            generation: generation
        )
        let renderKey = RenderKey(
            decodeKey: DecodeKey(
                contentID: contentID,
                targetWidth: request.target.width,
                targetHeight: request.target.height,
                contentMode: request.contentMode,
                geometryPolicyFingerprint: request.geometryPolicyFingerprint,
                colorPolicy: .preserveSource,
                codecContractVersion: 1,
                codecFingerprint: "imagecraft-imageio-v1"
            ),
            renderVersion: 1
        )
        let decision = DerivedRasterAdmissionPolicy.evaluate(
            request: request,
            representation: record,
            namespaceGeneration: generation,
            namespaceIsActive: true,
            renderKey: renderKey,
            format: DerivedRasterContainer.formatIdentity,
            now: Date(timeIntervalSinceReferenceDate: 10_000),
            creationRunsInBackground: true,
            observedReuseHits: 20,
            originalDecodeNanoseconds: 30,
            derivedReadNanoseconds: 5,
            creationNanoseconds: 100,
            maximumCreationNanoseconds: 1_000,
            derivedByteCount: 1_024,
            maximumDerivedByteCount: 4_096
        )
        XCTAssertEqual(decision, .reject(.unsupportedFormatForRender))
    }

    func testFormatIdentityRejectsUnversionedOrHostileComponents_W11_PT_005() {
        XCTAssertNil(
            DerivedRasterFormatIdentity(
                identifier: "adaptive",
                semanticVersion: 0,
                pixelLayoutFingerprint: "rgb8"
            )
        )
        XCTAssertNil(
            DerivedRasterFormatIdentity(
                identifier: "adaptive\nformat",
                semanticVersion: 1,
                pixelLayoutFingerprint: "rgb8"
            )
        )
        XCTAssertNil(
            DerivedRasterFormatIdentity(
                identifier: "adaptive",
                semanticVersion: 1,
                pixelLayoutFingerprint: String(repeating: "x", count: 129)
            )
        )
    }

    private struct Fixture {
        let request: ImageRequest
        let generation: NamespaceGeneration
        let contentID: ContentID
        let record: RepresentationRecord
        let renderKey: RenderKey
        let format: DerivedRasterFormatIdentity
    }

    private func makeFixture() throws -> Fixture {
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/ordinary.jpg")),
            logicalSource: LogicalSourceID("asset:ordinary:1"),
            target: try TargetPixels(width: 780, height: 520),
            colorPolicy: .convertToSRGB,
            appID: "derived-policy-tests"
        )
        let generation = NamespaceGeneration(7)
        let contentID = ContentID(data: Data("verified-original".utf8))
        let record = makeRecord(
            request: request,
            contentID: contentID,
            generation: generation
        )
        let decodeKey = DecodeKey(
            contentID: contentID,
            targetWidth: request.target.width,
            targetHeight: request.target.height,
            contentMode: request.contentMode,
            geometryPolicyFingerprint: request.geometryPolicyFingerprint,
            colorPolicy: request.colorPolicy,
            codecContractVersion: 1,
            codecFingerprint: "imagecraft-imageio-v1"
        )
        let renderKey = RenderKey(
            decodeKey: decodeKey,
            transformerFingerprint: "identity-transform-v1",
            renderVersion: 1
        )
        let format = DerivedRasterContainer.formatIdentity
        return Fixture(
            request: request,
            generation: generation,
            contentID: contentID,
            record: record,
            renderKey: renderKey,
            format: format
        )
    }

    private func makeRecord(
        request: ImageRequest,
        contentID: ContentID,
        generation: NamespaceGeneration,
        variantDigest: String? = nil,
        expiresAt: Date = Date(timeIntervalSinceReferenceDate: 20_000),
        disposition: CacheDisposition = .reusable,
        requiresRevalidation: Bool = false
    ) -> RepresentationRecord {
        RepresentationRecord(
            securityNamespace: request.namespace.value,
            namespaceGeneration: generation.value,
            baseKeyDigest: request.fetchBaseKey.digestHex,
            variantKeyDigest: variantDigest ?? request.fetchVariantKey.digestHex,
            statusCode: 200,
            requestTime: Date(timeIntervalSinceReferenceDate: 9_000),
            responseTime: Date(timeIntervalSinceReferenceDate: 9_001),
            responseDate: Date(timeIntervalSinceReferenceDate: 9_001),
            expiresAt: expiresAt,
            etag: nil,
            lastModified: nil,
            disposition: disposition,
            requiresRevalidation: requiresRevalidation,
            contentID: contentID.description,
            payloadLength: contentID.byteCount,
            contentType: "image/jpeg"
        )
    }

    private func evaluate(
        _ fixture: Fixture,
        record: RepresentationRecord? = nil,
        now: Date,
        creationRunsInBackground: Bool = true,
        namespaceIsActive: Bool = true,
        observedReuseHits: Int = 20,
        originalDecodeNanoseconds: UInt64 = 30,
        derivedReadNanoseconds: UInt64 = 5,
        creationNanoseconds: UInt64 = 100,
        maximumCreationNanoseconds: UInt64 = 1_000,
        derivedByteCount: Int = 1_024,
        maximumDerivedByteCount: Int = 4_096
    ) -> DerivedRasterAdmissionDecision {
        DerivedRasterAdmissionPolicy.evaluate(
            request: fixture.request,
            representation: record ?? fixture.record,
            namespaceGeneration: fixture.generation,
            namespaceIsActive: namespaceIsActive,
            renderKey: fixture.renderKey,
            format: fixture.format,
            now: now,
            creationRunsInBackground: creationRunsInBackground,
            observedReuseHits: observedReuseHits,
            originalDecodeNanoseconds: originalDecodeNanoseconds,
            derivedReadNanoseconds: derivedReadNanoseconds,
            creationNanoseconds: creationNanoseconds,
            maximumCreationNanoseconds: maximumCreationNanoseconds,
            derivedByteCount: derivedByteCount,
            maximumDerivedByteCount: maximumDerivedByteCount
        )
    }
}
