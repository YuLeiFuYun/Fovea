import AkashicDisk
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class TargetGeometryTests: XCTestCase {
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
      decodeKey(contentID: contentID, target: fit), decodeKey(contentID: contentID, target: fill))
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
      XCTAssertEqual(error as? ImageCraftError, .targetLimitExceeded)
    }
    XCTAssertThrowsError(
      try resolver.resolve(
        widthPoints: Double.greatestFiniteMagnitude,
        heightPoints: 10,
        scale: 2,
        isStable: true
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .targetLimitExceeded)
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
      encodedStore: try await OriginalEncodedStore.open(
        root: root.appendingPathComponent("encoded")),
      recordStore: try await RepresentationRecordStore.open(
        root: root.appendingPathComponent("records")
      ),
      diagnostics: diagnostics,
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
