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
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.com/public.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    XCTAssertEqual(request.authorizationContext, .public)
    XCTAssertNil(request.credentialGeneration)
  }

  func testPhysicalBlobIDDoesNotExposeContentDigest_CACHE_PT_031_GC_PT_005() async throws {
    let root = try makeTemporaryDirectory()
    let store = try await OriginalEncodedStore.open(root: root, softLimitBytes: 1024)
    let data = Data("known-content".utf8)
    let contentID = ContentID(data: data)
    let stored = try await store.commit(
      data: data, contentID: contentID.description, namespace: "public:tests")
    XCTAssertFalse(stored.physicalID.description.contains(contentID.digestHex))
    XCTAssertNotEqual(stored.physicalID.description, contentID.digestHex)
  }

  func testSensitiveHeadersDoNotEnterStableVariant_AUTH_PT_006() throws {
    let secret = "Bearer top-secret-token"
    let request = try ImageRequest(
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

  func testImageRequestRejectsCaseInsensitiveDuplicateHeaders() throws {
    XCTAssertThrowsError(
      try ImageRequest(
        url: XCTUnwrap(URL(string: "https://example.com/headers")),
        target: TargetPixels(width: 20, height: 20),
        namespace: .publicNamespace(appID: "tests"),
        headers: ["Accept": "image/png", "accept": "image/jpeg"]
      )
    ) { error in
      XCTAssertEqual(error as? ImageRequestError, .duplicateHeaderName("accept"))
    }
  }

  func testImageRequestRejectsHeaderInjection() throws {
    XCTAssertThrowsError(
      try ImageRequest(
        url: XCTUnwrap(URL(string: "https://example.com/headers")),
        target: TargetPixels(width: 20, height: 20),
        namespace: .publicNamespace(appID: "tests"),
        headers: ["X-Test": "safe\r\nAuthorization: injected"]
      )
    ) { error in
      XCTAssertEqual(error as? ImageRequestError, .invalidHeaderValue("X-Test"))
    }
  }

  func testSignedLocatorRefreshKeepsVariantButChangesExecution_CACHE_PT_014() throws {
    let logicalSource = LogicalSourceID("asset:avatar:42")
    let first = try ImageRequest.publicImage(
      url: XCTUnwrap(URL(string: "https://cdn.example.com/avatar.png?sig=old&exp=1")),
      logicalSource: logicalSource,
      target: TargetPixels(width: 40, height: 40),
      appID: "tests"
    )
    let refreshed = try ImageRequest.publicImage(
      url: XCTUnwrap(URL(string: "https://cdn.example.com/avatar.png?sig=new&exp=2")),
      logicalSource: logicalSource,
      target: TargetPixels(width: 40, height: 40),
      appID: "tests"
    )

    XCTAssertEqual(first.fetchVariantKey, refreshed.fetchVariantKey)
    XCTAssertNotEqual(first.fetchExecutionKey, refreshed.fetchExecutionKey)
  }

  func testURLNormalizationIsConservativeAndFragmentFree_CACHE_PT_027() throws {
    let first = try ImageRequest.publicImage(
      url: XCTUnwrap(URL(string: "HTTPS://EXAMPLE.COM:443/a%2Fb?x=1&x=2#first")),
      target: TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    let second = try ImageRequest.publicImage(
      url: XCTUnwrap(URL(string: "https://example.com/a%2Fb?x=1&x=2#second")),
      target: TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    let reordered = try ImageRequest.publicImage(
      url: XCTUnwrap(URL(string: "https://example.com/a%2Fb?x=2&x=1")),
      target: TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    XCTAssertEqual(first.fetchVariantKey, second.fetchVariantKey)
    XCTAssertEqual(first.url.absoluteString, "https://example.com/a%2Fb?x=1&x=2")
    XCTAssertNotEqual(first.fetchVariantKey, reordered.fetchVariantKey)
  }

  func testImageRequestRejectsUnsupportedSchemeAndEmbeddedCredentials() throws {
    XCTAssertThrowsError(
      try ImageRequest.publicImage(
        url: XCTUnwrap(URL(string: "file:///tmp/a.png")),
        target: TargetPixels(width: 20, height: 20),
        appID: "tests"
      )
    ) { error in
      XCTAssertEqual(error as? ImageRequestError, .unsupportedURLScheme("file"))
    }

    let user = "user"
    let secret = "credential"
    let locator = "https://" + user + ":" + secret + "@example.com/a.png"
    XCTAssertThrowsError(
      try ImageRequest.publicImage(
        url: XCTUnwrap(URL(string: locator)),
        target: TargetPixels(width: 20, height: 20),
        appID: "tests"
      )
    ) { error in
      XCTAssertEqual(error as? ImageRequestError, .embeddedURLCredentials)
    }
  }

  func testCustomCredentialHeaderIsExcludedFromStableIdentity_AUTH_PT_012() throws {
    let secret = "tenant-secret"
    let request = try ImageRequest(
      url: try XCTUnwrap(URL(string: "https://example.com/custom-credential.png")),
      target: try TargetPixels(width: 20, height: 20),
      namespace: SecurityNamespaceID("account-custom"),
      authorizationContext: AuthorizationContextID("principal-custom"),
      credentialGeneration: CredentialGeneration(1),
      headers: [
        "X-Tenant-Credential": secret,
        "Accept-Language": "zh-CN",
      ],
      credentialHeaderNames: ["X-Tenant-Credential"]
    )

    XCTAssertTrue(request.containsCredentialHeaders)
    XCTAssertEqual(request.credentialHeaderNames, ["x-tenant-credential"])
    XCTAssertNil(request.fetchVariantKey.canonicalBytes.range(of: Data(secret.utf8)))
    XCTAssertEqual(request.fetchVariantKey.requestVariants, ["accept-language": "zh-CN"])
  }

  func testCredentialHeaderSetChangesExactExecutionIdentity_AUTH_PT_012() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/credential-shape.png"))
    let authorization = try ImageRequest(
      url: url,
      target: try TargetPixels(width: 20, height: 20),
      namespace: SecurityNamespaceID("account-shape"),
      authorizationContext: AuthorizationContextID("principal-shape"),
      credentialGeneration: CredentialGeneration(1),
      headers: ["Authorization": "Bearer secret"]
    )
    let custom = try ImageRequest(
      url: url,
      target: try TargetPixels(width: 20, height: 20),
      namespace: SecurityNamespaceID("account-shape"),
      authorizationContext: AuthorizationContextID("principal-shape"),
      credentialGeneration: CredentialGeneration(1),
      headers: ["X-Tenant-Credential": "secret"],
      credentialHeaderNames: ["X-Tenant-Credential"]
    )

    XCTAssertEqual(authorization.fetchVariantKey, custom.fetchVariantKey)
    XCTAssertNotEqual(authorization.fetchExecutionKey, custom.fetchExecutionKey)
  }

  func testImageRequestExecutionKeyIncludesCredentialAndRevalidation() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/exact-fetch"))
    let oldCredential = try ImageRequest(
      url: url,
      target: try TargetPixels(width: 20, height: 20),
      namespace: SecurityNamespaceID("account-a"),
      authorizationContext: AuthorizationContextID("principal-a"),
      credentialGeneration: CredentialGeneration(1)
    )
    let newCredential = try ImageRequest(
      url: url,
      target: try TargetPixels(width: 20, height: 20),
      namespace: SecurityNamespaceID("account-a"),
      authorizationContext: AuthorizationContextID("principal-a"),
      credentialGeneration: CredentialGeneration(2)
    )

    XCTAssertNotEqual(oldCredential.fetchExecutionKey, newCredential.fetchExecutionKey)
    XCTAssertNotEqual(
      oldCredential.fetchExecutionKey(revalidationFingerprint: "etag-v1"),
      oldCredential.fetchExecutionKey(revalidationFingerprint: "etag-v2")
    )
  }

  func testRevalidationStateChangesFetchExecutionKey() {
    let variant = FetchVariantKey(
      source: LogicalSourceID("https://example.com/revalidate"),
      namespace: SecurityNamespaceID.publicNamespace(appID: "tests")
    )
    let unconditional = FetchExecutionKey(
      variant: variant,
      resolvedLocator: "https://example.com/revalidate"
    )
    let conditional = FetchExecutionKey(
      variant: variant,
      resolvedLocator: "https://example.com/revalidate",
      revalidationFingerprint: "etag-v1"
    )
    XCTAssertNotEqual(unconditional.digestHex, conditional.digestHex)
  }

  func testTargetChangesDisplayIdentityWithoutChangingFetchIdentity() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/target.png"))
    let small = try ImageRequest.publicImage(
      url: url,
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    let large = try ImageRequest.publicImage(
      url: url,
      target: try TargetPixels(width: 80, height: 80),
      appID: "tests"
    )
    XCTAssertEqual(small.fetchExecutionKey, large.fetchExecutionKey)
    XCTAssertNotEqual(small.displayIdentity, large.displayIdentity)
  }

  func testContentIDRejectsNonCanonicalDigestAndNegativeLength() throws {
    XCTAssertThrowsError(try ContentID(digestHex: "abc", byteCount: 3))
    XCTAssertThrowsError(
      try ContentID(digestHex: String(repeating: "A", count: 64), byteCount: 3)
    )
    XCTAssertThrowsError(
      try ContentID(digestHex: String(repeating: "a", count: 64), byteCount: -1)
    )
    let valid = try ContentID(digestHex: String(repeating: "a", count: 64), byteCount: 0)
    XCTAssertEqual(valid.description, "sha256:\(String(repeating: "a", count: 64)):0")
  }

  func testZeroTargetIsRejected_GEO_PT_002() {
    XCTAssertThrowsError(try TargetPixels(width: 0, height: 10))
    XCTAssertThrowsError(try TargetPixels(width: 10, height: 0))
  }
}
