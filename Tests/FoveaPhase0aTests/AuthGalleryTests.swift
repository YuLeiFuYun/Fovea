import AkashicDisk
import CoreGraphics
import CryptoKit
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaTesting
import ImageCraftCore
import XCTest

final class AuthGalleryTests: XCTestCase {
  func testSameURLIsolatedAcrossAccountsAndLogoutPreservesOtherAccount() async throws {
    let bodyA = try makePNG(red: 230)
    let bodyB = try makePNG(red: 20)
    let origin = CredentialImageOrigin(responses: [
      "Bearer account-a": .init(
        body: bodyA,
        headers: ["Content-Type": "image/png", "Cache-Control": "private, max-age=3600"]
      ),
      "Bearer account-b": .init(
        body: bodyB,
        headers: ["Content-Type": "image/png", "Cache-Control": "private, max-age=3600"]
      ),
    ])
    let root = try makeTemporaryDirectory()
    let encoded = try OriginalEncodedStore(root: root.appendingPathComponent("encoded"))
    let records = try RepresentationRecordStore(root: root.appendingPathComponent("records"))
    let pipeline = FoveaPipeline(
      transport: origin,
      encodedStore: encoded,
      recordStore: records
    )
    let url = try XCTUnwrap(URL(string: "https://images.example.test/avatar"))
    let target = try TargetPixels(width: 40, height: 40)
    let accountA = authenticatedRequest(
      url: url,
      target: target,
      namespace: "account-a",
      principal: "principal-a",
      token: "Bearer account-a"
    )
    let accountB = authenticatedRequest(
      url: url,
      target: target,
      namespace: "account-b",
      principal: "principal-b",
      token: "Bearer account-b"
    )

    let imageA = try await pipeline.image(for: accountA)
    let imageB = try await pipeline.image(for: accountB)
    let warmA = try await pipeline.image(for: accountA)
    let warmB = try await pipeline.image(for: accountB)

    XCTAssertGreaterThan(try centerRed(imageA.cgImage), 180)
    XCTAssertLessThan(try centerRed(imageB.cgImage), 80)
    XCTAssertGreaterThan(try centerRed(warmA.cgImage), 180)
    XCTAssertLessThan(try centerRed(warmB.cgImage), 80)
    let counts = await origin.requestCounts()
    XCTAssertEqual(counts["Bearer account-a"], 1)
    XCTAssertEqual(counts["Bearer account-b"], 1)

    let recordAValue = await records.record(for: accountA.fetchVariantKey.digestHex)
    let recordBValue = await records.record(for: accountB.fetchVariantKey.digestHex)
    let recordA = try XCTUnwrap(recordAValue)
    let recordB = try XCTUnwrap(recordBValue)
    XCTAssertEqual(recordA.securityNamespace, "account-a")
    XCTAssertEqual(recordB.securityNamespace, "account-b")
    let physicalAValue = await encoded.physicalID(
      contentID: recordA.contentID,
      namespace: "account-a"
    )
    let physicalBValue = await encoded.physicalID(
      contentID: recordB.contentID,
      namespace: "account-b"
    )
    let physicalA = try XCTUnwrap(physicalAValue)
    let physicalB = try XCTUnwrap(physicalBValue)
    XCTAssertNotEqual(physicalA, physicalB)

    try await pipeline.revoke(namespace: SecurityNamespaceID("account-a"))
    let revokedRecordA = await records.record(for: accountA.fetchVariantKey.digestHex)
    let revokedPhysicalA = await encoded.physicalID(
      contentID: recordA.contentID,
      namespace: "account-a"
    )
    let preservedRecordB = await records.record(for: accountB.fetchVariantKey.digestHex)
    let preservedPhysicalB = await encoded.physicalID(
      contentID: recordB.contentID,
      namespace: "account-b"
    )
    XCTAssertNil(revokedRecordA)
    XCTAssertNil(revokedPhysicalA)
    XCTAssertNotNil(preservedRecordB)
    XCTAssertNotNil(preservedPhysicalB)

    let afterLogoutB = try await pipeline.image(for: accountB)
    XCTAssertLessThan(try centerRed(afterLogoutB.cgImage), 80)
    let finalCounts = await origin.requestCounts()
    XCTAssertEqual(finalCounts["Bearer account-b"], 1)
  }

  func testPrivateNoStoreNeverCreatesReusableResidue() async throws {
    let body = try makePNG(red: 170)
    let origin = CredentialImageOrigin(responses: [
      "Bearer no-store": .init(
        body: body,
        headers: ["Content-Type": "image/png", "Cache-Control": "private, no-store"]
      )
    ])
    let root = try makeTemporaryDirectory()
    let encoded = try OriginalEncodedStore(root: root.appendingPathComponent("encoded"))
    let records = try RepresentationRecordStore(root: root.appendingPathComponent("records"))
    let pipeline = FoveaPipeline(
      transport: origin,
      encodedStore: encoded,
      recordStore: records
    )
    let request = authenticatedRequest(
      url: try XCTUnwrap(URL(string: "https://images.example.test/no-store")),
      target: try TargetPixels(width: 40, height: 40),
      namespace: "account-no-store",
      principal: "principal-no-store",
      token: "Bearer no-store"
    )

    _ = try await pipeline.image(for: request)
    _ = try await pipeline.image(for: request)

    let noStoreCounts = await origin.requestCounts()
    let noStoreRecord = await records.record(for: request.fetchVariantKey.digestHex)
    let contentID = ContentID(data: body).description
    let noStorePhysicalID = await encoded.physicalID(
      contentID: contentID,
      namespace: request.namespace.value
    )
    XCTAssertEqual(noStoreCounts["Bearer no-store"], 2)
    XCTAssertNil(noStoreRecord)
    XCTAssertNil(noStorePhysicalID)
  }

  func testLogoutCancelsInFlightFetchAndLeavesNoBlobOrRecord() async throws {
    let body = try makePNG(red: 100)
    let origin = CredentialImageOrigin(responses: [
      "Bearer delayed": .init(
        body: body,
        headers: ["Content-Type": "image/png", "Cache-Control": "private, max-age=3600"],
        delayNanoseconds: 150_000_000
      )
    ])
    let root = try makeTemporaryDirectory()
    let encoded = try OriginalEncodedStore(root: root.appendingPathComponent("encoded"))
    let records = try RepresentationRecordStore(root: root.appendingPathComponent("records"))
    let pipeline = FoveaPipeline(
      transport: origin,
      encodedStore: encoded,
      recordStore: records
    )
    let request = authenticatedRequest(
      url: try XCTUnwrap(URL(string: "https://images.example.test/delayed")),
      target: try TargetPixels(width: 40, height: 40),
      namespace: "account-delayed",
      principal: "principal-delayed",
      token: "Bearer delayed"
    )

    let task = Task { try await pipeline.image(for: request) }
    try await Task.sleep(for: .milliseconds(20))
    try await pipeline.revoke(namespace: request.namespace)

    do {
      _ = try await task.value
      XCTFail("A revoked namespace must not receive a final image")
    } catch let error as FoveaError {
      XCTAssertEqual(error, .namespaceRevoked)
    }

    let delayedRecord = await records.record(for: request.fetchVariantKey.digestHex)
    let delayedPhysicalID = await encoded.physicalID(
      contentID: ContentID(data: body).description,
      namespace: request.namespace.value
    )
    XCTAssertNil(delayedRecord)
    XCTAssertNil(delayedPhysicalID)
  }

  func testRevokeDuringBlobCommitRemovesLateBlobAndRecord() async throws {
    let body = try makePNG(red: 120)
    let origin = CredentialImageOrigin(responses: [
      "Bearer commit-race": .init(
        body: body,
        headers: ["Content-Type": "image/png", "Cache-Control": "private, max-age=3600"]
      )
    ])
    let root = try makeTemporaryDirectory()
    let baseStore = try OriginalEncodedStore(root: root.appendingPathComponent("encoded"))
    let barrierStore = CommitBarrierEncodedStore(base: baseStore)
    let records = try RepresentationRecordStore(root: root.appendingPathComponent("records"))
    let pipeline = FoveaPipeline(
      transport: origin,
      encodedStore: barrierStore,
      recordStore: records
    )
    let request = authenticatedRequest(
      url: try XCTUnwrap(URL(string: "https://images.example.test/commit-race")),
      target: try TargetPixels(width: 40, height: 40),
      namespace: "account-commit-race",
      principal: "principal-commit-race",
      token: "Bearer commit-race"
    )

    let task = Task { try await pipeline.image(for: request) }
    await barrierStore.waitUntilCommitStarts()
    try await pipeline.revoke(namespace: request.namespace)
    await barrierStore.releaseCommit()

    do {
      _ = try await task.value
      XCTFail("A revoked namespace must not survive a late blob commit")
    } catch let error as FoveaError {
      XCTAssertEqual(error, .namespaceRevoked)
    }

    let record = await records.record(for: request.fetchVariantKey.digestHex)
    let physicalID = await baseStore.physicalID(
      contentID: ContentID(data: body).description,
      namespace: request.namespace.value
    )
    XCTAssertNil(record)
    XCTAssertNil(physicalID)
  }

  func testCrossOriginRedirectStripsCredentialsButSameOriginPreservesThem() throws {
    var original = URLRequest(
      url: try XCTUnwrap(URL(string: "https://a.example.test/private"))
    )
    original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    original.setValue("session=secret", forHTTPHeaderField: "Cookie")
    original.setValue("api-secret", forHTTPHeaderField: "X-API-Key")
    original.setValue("image/avif", forHTTPHeaderField: "Accept")

    var crossOrigin = URLRequest(
      url: try XCTUnwrap(URL(string: "https://b.example.test/redirected"))
    )
    crossOrigin.allHTTPHeaderFields = original.allHTTPHeaderFields
    let sanitized = RedirectCredentialPolicy.sanitizedRedirectRequest(
      original: original,
      proposed: crossOrigin
    )
    XCTAssertNil(sanitized.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(sanitized.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(sanitized.value(forHTTPHeaderField: "X-API-Key"))
    XCTAssertEqual(sanitized.value(forHTTPHeaderField: "Accept"), "image/avif")

    var sameOrigin = URLRequest(
      url: try XCTUnwrap(URL(string: "https://a.example.test:443/redirected"))
    )
    sameOrigin.allHTTPHeaderFields = original.allHTTPHeaderFields
    let preserved = RedirectCredentialPolicy.sanitizedRedirectRequest(
      original: original,
      proposed: sameOrigin
    )
    XCTAssertEqual(preserved.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    XCTAssertEqual(preserved.value(forHTTPHeaderField: "Cookie"), "session=secret")
  }
}

private func authenticatedRequest(
  url: URL,
  target: TargetPixels,
  namespace: String,
  principal: String,
  token: String
) -> ImageRequest {
  ImageRequest(
    url: url,
    target: target,
    namespace: SecurityNamespaceID(namespace),
    authorizationContext: AuthorizationContextID(principal),
    credentialGeneration: CredentialGeneration(1),
    headers: ["Authorization": token]
  )
}

private func centerRed(_ image: CGImage) throws -> UInt8 {
  var pixel = [UInt8](repeating: 0, count: 4)
  let rendered = pixel.withUnsafeMutableBytes { bytes -> Bool in
    guard let baseAddress = bytes.baseAddress,
      let context = CGContext(
        data: baseAddress,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      return false
    }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return true
  }
  guard rendered else { throw NSError(domain: "FoveaAuthGalleryTests", code: 1) }
  return pixel[0]
}

private actor CredentialImageOrigin: HTTPTransporting {
  struct Response: Sendable {
    let body: Data
    let headers: [String: String]
    let delayNanoseconds: UInt64

    init(body: Data, headers: [String: String], delayNanoseconds: UInt64 = 0) {
      self.body = body
      self.headers = headers
      self.delayNanoseconds = delayNanoseconds
    }
  }

  private let responses: [String: Response]
  private var counts: [String: Int] = [:]

  init(responses: [String: Response]) {
    self.responses = responses
  }

  func execute(_ request: TransportRequest) async throws -> TransportResponse {
    guard let credential = request.request.value(forHTTPHeaderField: "Authorization"),
      let response = responses[credential]
    else {
      throw URLError(.userAuthenticationRequired)
    }
    counts[credential, default: 0] += 1
    if response.delayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: response.delayNanoseconds)
    }
    try Task.checkCancellation()
    let digest = SHA256.hash(data: response.body).map { String(format: "%02x", $0) }.joined()
    return TransportResponse(
      head: TransportResponseHead(
        statusCode: 200,
        headers: response.headers,
        url: request.request.url
      ),
      body: response.body,
      digestHex: digest,
      metrics: TransportMetrics(receivedBytes: response.body.count, spilledToDisk: false)
    )
  }

  func requestCounts() -> [String: Int] { counts }
}
