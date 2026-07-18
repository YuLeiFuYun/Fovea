import AkashicDisk
import FoveaCore
import ImageCraftCore
import XCTest

final class IdentityTests: XCTestCase {
  func testCanonicalVariantOrderIsStable_KEY_GV_001() throws {
    let source = LogicalSourceID("https://example.com/a.png")
    let namespace = SecurityNamespaceID.publicNamespace(appID: "tests")
    let first = FetchVariantKey(
      source: source,
      namespace: namespace,
      requestVariants: ["Accept-Language": "zh-CN", "Accept": "image/png"]
    )
    let second = FetchVariantKey(
      source: source,
      namespace: namespace,
      requestVariants: ["Accept": "image/png", "Accept-Language": "zh-CN"]
    )
    XCTAssertEqual(first.canonicalBytes, second.canonicalBytes)
    XCTAssertEqual(first.digestHex, second.digestHex)
  }

  func testNamespaceChangesVariantIdentity_CACHE_PT_003() {
    let source = LogicalSourceID("https://example.com/avatar")
    let a = FetchVariantKey(source: source, namespace: SecurityNamespaceID("account-a"))
    let b = FetchVariantKey(source: source, namespace: SecurityNamespaceID("account-b"))
    XCTAssertNotEqual(a.digestHex, b.digestHex)
  }

  func testCredentialRefreshChangesExecutionButNotVariant_AUTH_PT_001() {
    let variant = FetchVariantKey(
      source: LogicalSourceID("https://example.com/private"),
      namespace: SecurityNamespaceID("account-a"),
      authorizationContext: AuthorizationContextID("principal:v1")
    )
    let old = FetchExecutionKey(
      variant: variant,
      resolvedLocator: "https://example.com/private",
      credentialGeneration: CredentialGeneration(1)
    )
    let new = FetchExecutionKey(
      variant: variant,
      resolvedLocator: "https://example.com/private",
      credentialGeneration: CredentialGeneration(2)
    )
    XCTAssertEqual(old.variantDigest, new.variantDigest)
    XCTAssertNotEqual(old.digestHex, new.digestHex)
  }

  func testPublicRequestNeedsNoCredentialGeneration_AUTH_PT_010() throws {
    let request = ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.com/public.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    XCTAssertEqual(request.authorizationContext, .public)
    XCTAssertNil(request.credentialGeneration)
  }

  func testPhysicalBlobIDDoesNotExposeContentDigest_CACHE_PT_031_GC_PT_005() async throws {
    let root = try makeTemporaryDirectory()
    let store = try OriginalEncodedStore(root: root, softLimitBytes: 1024)
    let data = Data("known-content".utf8)
    let contentID = ContentID(data: data)
    let stored = try await store.commit(
      data: data, contentID: contentID.description, namespace: "public:tests")
    XCTAssertFalse(stored.physicalID.description.contains(contentID.digestHex))
    XCTAssertNotEqual(stored.physicalID.description, contentID.digestHex)
  }

  func testSensitiveHeadersDoNotEnterStableVariant_AUTH_PT_006() throws {
    let secret = "Bearer top-secret-token"
    let request = ImageRequest(
      url: try XCTUnwrap(URL(string: "https://example.com/private.png")),
      target: try TargetPixels(width: 20, height: 20),
      namespace: SecurityNamespaceID("account-a"),
      authorizationContext: AuthorizationContextID("principal-a"),
      credentialGeneration: CredentialGeneration(7),
      headers: [
        "Authorization": secret,
        "Accept-Language": "zh-CN",
      ]
    )
    XCTAssertNil(request.fetchVariantKey.canonicalBytes.range(of: Data(secret.utf8)))
    XCTAssertEqual(request.fetchVariantKey.requestVariants, ["accept-language": "zh-CN"])
  }

  func testZeroTargetIsRejected_GEO_PT_002() {
    XCTAssertThrowsError(try TargetPixels(width: 0, height: 10))
    XCTAssertThrowsError(try TargetPixels(width: 10, height: 0))
  }
}
