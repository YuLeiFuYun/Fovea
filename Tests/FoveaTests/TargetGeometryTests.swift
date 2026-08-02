import AkashicDisk
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class TargetGeometryTests: XCTestCase {
    func testCodableRejectsInvalidTargetAndDecodeLimits() throws {
        let invalidTarget = Data(#"{"width":0,"height":20}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TargetPixels.self, from: invalidTarget))

        let validLimits = DecodeLimits(maximumPixelCount: 10_000)
        let encodedLimits = try JSONEncoder().encode(validLimits)
        var limitsObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedLimits) as? [String: Any]
        )
        limitsObject["maximumPixelCount"] = -1
        let invalidLimits = try JSONSerialization.data(withJSONObject: limitsObject)
        XCTAssertThrowsError(try JSONDecoder().decode(DecodeLimits.self, from: invalidLimits))
    }

    func testGeometryPolicyCodableRejectsUnknownSchemaAndInvalidLimits_MATH_PT_009() throws {
        let policy = TargetGeometryPolicy(bucketStep: 8)
        let encoded = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(TargetGeometryPolicy.self, from: encoded)
        XCTAssertEqual(decoded, policy)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["schemaVersion"] = 99
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TargetGeometryPolicy.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )

        object["schemaVersion"] = 99
        object["bucketStep"] = 0
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TargetGeometryPolicy.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testDecodeLimitsClampProgrammaticExtremesAndRejectPersistedOverflow() throws {
        let limits = DecodeLimits(
            maximumEncodedBytes: Int.max,
            maximumDimension: Int.max,
            maximumPixelCount: Int.max,
            maximumFrameCount: Int.max,
            maximumMetadataBytes: Int.max,
            maximumAuxiliaryAttachments: Int.max
        )
        XCTAssertEqual(limits.maximumEncodedBytes, 1024 * 1024 * 1024)
        XCTAssertEqual(limits.maximumDimension, 65_536)
        XCTAssertEqual(limits.maximumPixelCount, 1_000_000_000)
        XCTAssertEqual(limits.maximumFrameCount, 4_096)
        XCTAssertEqual(limits.maximumMetadataBytes, 64 * 1024 * 1024)
        XCTAssertEqual(limits.maximumAuxiliaryAttachments, 1_024)

        let data = try JSONEncoder().encode(DecodeLimits())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["maximumDimension"] = 65_537
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                DecodeLimits.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testGeometryPolicyClampsProgrammaticExtremesAndRejectsPersistedOverflow() throws {
        let policy = TargetGeometryPolicy(
            bucketStep: Int.max,
            growthHysteresisPermille: Int.max,
            shrinkHysteresisPermille: Int.max,
            maximumDimension: Int.max,
            maximumPixelCount: Int.max
        )
        XCTAssertEqual(policy.bucketStep, 65_536)
        XCTAssertEqual(policy.growthHysteresisPermille, 1_000)
        XCTAssertEqual(policy.shrinkHysteresisPermille, 1_000)
        XCTAssertEqual(policy.maximumDimension, 65_536)
        XCTAssertEqual(policy.maximumPixelCount, 1_000_000_000)

        let data = try JSONEncoder().encode(TargetGeometryPolicy())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["growthHysteresisPermille"] = 1_001
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TargetGeometryPolicy.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testGeometricBucketsBoundRelativeOversamplingAndReduceVariants_MATH_PT_010()
        throws
    {
        let policy = TargetGeometryPolicy(
            bucketStep: 16,
            relativeBucketPermille: 64,
            relativeBucketThreshold: 256,
            growthHysteresisPermille: 0,
            shrinkHysteresisPermille: 0,
            maximumDimension: 16_384,
            maximumPixelCount: 300_000_000
        )
        var geometricBuckets: Set<Int> = []
        var linearBuckets: Set<Int> = []

        for raw in 257...4_096 {
            var resolver = TargetGeometryResolver(policy: policy)
            let target = try XCTUnwrap(
                resolver.resolve(
                    widthPoints: Double(raw),
                    heightPoints: Double(raw),
                    scale: 1,
                    isStable: false
                )
            )
            let bucket = target.pixels.width
            XCTAssertGreaterThanOrEqual(bucket, raw)
            XCTAssertLessThanOrEqual(Double(bucket) / Double(raw), 1.07)
            XCTAssertLessThanOrEqual(
                Double(target.pixels.pixelCount) / Double(raw * raw),
                1.145
            )
            geometricBuckets.insert(bucket)
            linearBuckets.insert(((raw + 15) / 16) * 16)
        }

        XCTAssertLessThan(geometricBuckets.count, linearBuckets.count / 3)
        XCTAssertTrue(policy.fingerprint.contains("relative:64"))
    }

    func testStableGeometryUsesExactPixelsAfterTransientQuantization_MATH_PT_011() throws {
        var resolver = TargetGeometryResolver(
            policy: TargetGeometryPolicy(
                bucketStep: 16,
                relativeBucketPermille: 64,
                relativeBucketThreshold: 256,
                growthHysteresisPermille: 125,
                shrinkHysteresisPermille: 250
            )
        )

        let transient = try XCTUnwrap(
            resolver.resolve(
                widthPoints: 320,
                heightPoints: 240,
                scale: 3,
                isStable: false
            )
        )
        let stable = try XCTUnwrap(
            resolver.resolve(
                widthPoints: 320,
                heightPoints: 240,
                scale: 3,
                isStable: true
            )
        )
        let repeatedStable = try XCTUnwrap(
            resolver.resolve(
                widthPoints: 321,
                heightPoints: 241,
                scale: 3,
                isStable: true
            )
        )

        XCTAssertEqual(transient.cacheAdmission, .transient)
        XCTAssertGreaterThanOrEqual(transient.pixels.width, 960)
        XCTAssertGreaterThanOrEqual(transient.pixels.height, 720)
        XCTAssertEqual(stable.pixels, try TargetPixels(width: 960, height: 720))
        XCTAssertEqual(stable.cacheAdmission, .stable)
        XCTAssertEqual(repeatedStable.pixels, stable.pixels)
        XCTAssertEqual(repeatedStable.cacheAdmission, .stable)
        XCTAssertNotEqual(transient.pixels, stable.pixels)
    }

    func testEquivalentPointScalePairsProduceSameDecodeIdentityGeoPt001() throws {
        var firstResolver = TargetGeometryResolver()
        var secondResolver = TargetGeometryResolver()
        let first = try XCTUnwrap(
            firstResolver.resolve(
                widthPoints: 50,
                heightPoints: 25,
                scale: 2,
                isStable: true
            )
        )
        let second = try XCTUnwrap(
            secondResolver.resolve(
                widthPoints: 100,
                heightPoints: 50,
                scale: 1,
                isStable: true
            )
        )
        let contentID = ContentID(data: Data("same-content".utf8))

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            decodeKey(contentID: contentID, target: first),
            decodeKey(contentID: contentID, target: second))
    }

    func testZeroPointGeometryRemainsPendingGeoPt002() throws {
        var resolver = TargetGeometryResolver()

        XCTAssertNil(
            try resolver.resolve(
                widthPoints: 0,
                heightPoints: 20,
                scale: 2,
                isStable: false
            )
        )
        XCTAssertNil(
            try resolver.resolve(
                widthPoints: 20,
                heightPoints: 0,
                scale: 2,
                isStable: false
            )
        )
    }

    func testResizeHysteresisSuppressesSmallFluctuationsGeoPt005() throws {
        var resolver = TargetGeometryResolver(
            policy: TargetGeometryPolicy(
                bucketStep: 16,
                growthHysteresisPermille: 125,
                shrinkHysteresisPermille: 250
            )
        )
        let initial = try XCTUnwrap(
            resolver.resolve(
                widthPoints: 50,
                heightPoints: 50,
                scale: 2,
                isStable: false
            )
        )
        let fluctuating = try XCTUnwrap(
            resolver.resolve(
                widthPoints: 56,
                heightPoints: 53,
                scale: 2,
                isStable: false
            )
        )
        let grown = try XCTUnwrap(
            resolver.resolve(
                widthPoints: 70,
                heightPoints: 70,
                scale: 2,
                isStable: true
            )
        )

        XCTAssertEqual(initial.pixels, try TargetPixels(width: 112, height: 112))
        XCTAssertEqual(fluctuating.pixels, initial.pixels)
        XCTAssertNotEqual(grown.pixels, initial.pixels)
        XCTAssertEqual(initial.cacheAdmission, .transient)
        XCTAssertEqual(grown.cacheAdmission, .stable)
    }

    func testGeometryPolicyAndContentModeChangeDecodeIdentityGeoPt006() throws {
        let pixels = try TargetPixels(width: 100, height: 100)
        let contentID = ContentID(data: Data("same-content".utf8))
        let fit = ResolvedImageTarget(
            pixels: pixels,
            contentMode: .fit,
            geometryPolicyFingerprint: "geometry-v1"
        )
        let fill = ResolvedImageTarget(
            pixels: pixels,
            contentMode: .fill,
            geometryPolicyFingerprint: "geometry-v1"
        )
        let otherPolicy = ResolvedImageTarget(
            pixels: pixels,
            contentMode: .fit,
            geometryPolicyFingerprint: "geometry-v2"
        )

        XCTAssertNotEqual(
            decodeKey(contentID: contentID, target: fit),
            decodeKey(contentID: contentID, target: fill))
        XCTAssertNotEqual(
            decodeKey(contentID: contentID, target: fit),
            decodeKey(contentID: contentID, target: otherPolicy)
        )
    }

    func testExtremeGeometryIsRejectedBeforeAllocationGeoPt007() throws {
        var resolver = TargetGeometryResolver(
            policy: TargetGeometryPolicy(maximumDimension: 1_024, maximumPixelCount: 1_000_000)
        )

        XCTAssertThrowsError(
            try resolver.resolve(
                widthPoints: 1_025,
                heightPoints: 10,
                scale: 1,
                isStable: true
            )
        ) { error in
            XCTAssertEqual(error as? TargetGeometryError, .limitExceeded)
        }
        XCTAssertThrowsError(
            try resolver.resolve(
                widthPoints: Double.greatestFiniteMagnitude,
                heightPoints: 10,
                scale: 2,
                isStable: true
            )
        ) { error in
            XCTAssertEqual(error as? TargetGeometryError, .limitExceeded)
        }
    }

    func testStableAdmissionChangesDisplaySubscriptionButNotDecodeIdentityGeoPt010() throws {
        let pixels = try TargetPixels(width: 100, height: 75)
        let transientTarget = ResolvedImageTarget(
            pixels: pixels,
            geometryPolicyFingerprint: "geometry-v1",
            cacheAdmission: .transient
        )
        let stableTarget = ResolvedImageTarget(
            pixels: pixels,
            geometryPolicyFingerprint: "geometry-v1",
            cacheAdmission: .stable
        )
        let url = try XCTUnwrap(URL(string: "https://example.test/admission-identity.png"))
        let transient = try ImageRequest.publicImage(
            url: url,
            resolvedTarget: transientTarget,
            appID: "tests"
        )
        let stable = try ImageRequest.publicImage(
            url: url,
            resolvedTarget: stableTarget,
            appID: "tests"
        )
        let contentID = ContentID(data: Data("same-content".utf8))

        XCTAssertEqual(transient.fetchExecutionKey, stable.fetchExecutionKey)
        XCTAssertEqual(
            decodeKey(contentID: contentID, target: transientTarget),
            decodeKey(contentID: contentID, target: stableTarget)
        )
        XCTAssertNotEqual(transient.displayIdentity, stable.displayIdentity)
    }

    func testTransientTargetDoesNotEnterRenderedMemoryUntilStableGeoPt009() async throws {
        let body = try makePNG(width: 400, height: 300)
        let root = try makeTemporaryDirectory()
        let diagnostics = BoundedDiagnosticsSink(capacity: 128)
        let transport = FakeHTTPTransport(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                body: body
            )
        ])
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")),
            recordStore: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")
            ),
            diagnostics: diagnostics,
            profileAccessPolicy: .unrestricted,
            decoder: ImageIOImageDecoder()
        )
        let pixels = try TargetPixels(width: 100, height: 75)
        let transient = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/transient-target.png")),
            resolvedTarget: ResolvedImageTarget(
                pixels: pixels,
                geometryPolicyFingerprint: "geometry-v1",
                cacheAdmission: .transient
            ),
            appID: "tests"
        )
        let stable = try ImageRequest.publicImage(
            url: transient.url,
            resolvedTarget: ResolvedImageTarget(
                pixels: pixels,
                geometryPolicyFingerprint: "geometry-v1",
                cacheAdmission: .stable
            ),
            appID: "tests"
        )

        _ = try await pipeline.image(for: transient)
        _ = try await pipeline.image(for: transient)
        _ = try await pipeline.image(for: stable)
        _ = try await pipeline.image(for: stable)

        let events = await diagnostics.snapshot().map(\.event.kind)
        XCTAssertEqual(events.filter { $0 == .decodeCompleted }.count, 3)
        XCTAssertEqual(events.filter { $0 == .renderedMemoryHit }.count, 1)
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    private func decodeKey(contentID: ContentID, target: ResolvedImageTarget) -> DecodeKey {
        DecodeKey(
            contentID: contentID,
            targetWidth: target.pixels.width,
            targetHeight: target.pixels.height,
            contentMode: target.contentMode,
            geometryPolicyFingerprint: target.geometryPolicyFingerprint,
            decoderVersion: 1
        )
    }
}
