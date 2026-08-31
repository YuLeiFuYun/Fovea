import Foundation
import FoveaStorage
import ImageCraftCore
import XCTest

@testable import FoveaCore

final class T100ImageRequestPersistentIdentityTests: XCTestCase {
    func testInitialRequestPrecomputesPersistentIdentity_IMAGE_REQUEST_PT_001() throws {
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/persistent-identity.png")),
            logicalSource: LogicalSourceID("asset:persistent-identity"),
            target: try TargetPixels(width: 64, height: 48),
            appID: "image-request-owner-047"
        )

        XCTAssertEqual(request.fetchBaseDigest, request.fetchBaseKey.digestHex)
        XCTAssertEqual(request.fetchVariantKey.baseDigest, request.fetchBaseDigest)
        XCTAssertEqual(
            request.storageNamespaceFingerprint,
            StorageNamespaceFingerprint(namespace: request.namespace.value)
        )
    }

    func testRetargetPreservesPersistentIdentity_IMAGE_REQUEST_PT_002() throws {
        let original = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/retarget.png")),
            logicalSource: LogicalSourceID("asset:retarget-owner-047"),
            target: try TargetPixels(width: 16, height: 16),
            appID: "image-request-owner-047",
            networkPolicy: .conservative
        )
        let target = ResolvedImageTarget(
            pixels: try TargetPixels(width: 320, height: 180),
            contentMode: .fill,
            geometryPolicyFingerprint: "geometry-v2:owner-047",
            cacheAdmission: .transient
        )

        let retargeted = try original.retargeted(to: target)

        XCTAssertEqual(retargeted.fetchBaseDigest, original.fetchBaseDigest)
        XCTAssertEqual(retargeted.fetchBaseKey, original.fetchBaseKey)
        XCTAssertEqual(retargeted.fetchVariantKey, original.fetchVariantKey)
        XCTAssertEqual(
            retargeted.storageNamespaceFingerprint,
            original.storageNamespaceFingerprint
        )
        XCTAssertNotEqual(retargeted.displayIdentity, original.displayIdentity)
    }

    func testReprioritizePreservesPersistentIdentity_IMAGE_REQUEST_PT_003() throws {
        let original = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/reprioritized.png")),
            logicalSource: LogicalSourceID("asset:reprioritized-owner-047"),
            target: try TargetPixels(width: 48, height: 48),
            appID: "image-request-owner-047"
        )

        let reprioritized = original.reprioritized(.high)

        XCTAssertEqual(reprioritized.fetchBaseDigest, original.fetchBaseDigest)
        XCTAssertEqual(reprioritized.fetchBaseKey, original.fetchBaseKey)
        XCTAssertEqual(reprioritized.fetchVariantKey, original.fetchVariantKey)
        XCTAssertEqual(
            reprioritized.storageNamespaceFingerprint,
            original.storageNamespaceFingerprint
        )
        XCTAssertEqual(reprioritized.priority, .high)
    }

    func testNamespaceChangesBothPersistentIdentityComponents_IMAGE_REQUEST_PT_004() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/namespace.png"))
        let first = try ImageRequest.publicImage(
            url: url,
            logicalSource: LogicalSourceID("asset:namespace-owner-047"),
            target: try TargetPixels(width: 24, height: 24),
            appID: "image-request-owner-047-a"
        )
        let second = try ImageRequest.publicImage(
            url: url,
            logicalSource: LogicalSourceID("asset:namespace-owner-047"),
            target: try TargetPixels(width: 24, height: 24),
            appID: "image-request-owner-047-b"
        )

        XCTAssertNotEqual(first.namespace, second.namespace)
        XCTAssertNotEqual(first.storageNamespaceFingerprint, second.storageNamespaceFingerprint)
        XCTAssertNotEqual(first.fetchBaseDigest, second.fetchBaseDigest)
        XCTAssertEqual(first.fetchBaseDigest, first.fetchBaseKey.digestHex)
        XCTAssertEqual(second.fetchBaseDigest, second.fetchBaseKey.digestHex)
    }
}
