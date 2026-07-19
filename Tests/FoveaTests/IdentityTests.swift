import AkashicDisk
import FoveaCore
import FoveaHTTP
import ImageCraftCore
import XCTest

final class IdentityTests: XCTestCase {
  func testCanonicalVariantOrderIsStable_KEY_GV_001() {
    let base = makeBase(source: "https://example.com/a.png")
    let first = FetchVariantKey(
      base: base,
      requestVariants: ["Accept-Language": "v:zh-CN", "Accept": "v:image/png"]
    )
    let second = FetchVariantKey(
      base: base,
      requestVariants: ["Accept": "v:image/png", "Accept-Language": "v:zh-CN"]
    )

    XCTAssertEqual(first.canonicalBytes, second.canonicalBytes)
    XCTAssertEqual(first.digestHex, second.digestHex)
  }

  func testNamespaceChangesBaseAndVariantIdentity_CACHE_PT_003() {
    let source = LogicalSourceID("https://example.com/avatar")
    let firstBase = FetchBaseKey(
      source: source,
      namespace: SecurityNamespaceID("account-a")
    )
    let secondBase = FetchBaseKey(
      source: source,
      namespace: SecurityNamespaceID("account-b")
    )

    XCTAssertNotEqual(firstBase.digestHex, secondBase.digestHex)
    XCTAssertNotEqual(
      FetchVariantKey(base: firstBase).digestHex,
      FetchVariantKey(base: secondBase).digestHex
    )
  }

  func testCredentialRefreshChangesExecutionButNotBaseOrVariant_AUTH_PT_001() {
    let base = FetchBaseKey(
      source: LogicalSourceID("https://example.com/private"),
      namespace: SecurityNamespaceID("account-a"),
      authorizationContext: AuthorizationContextID("principal:v1")
    )
    let variant = FetchVariantKey(base: base)
    let old = FetchExecutionKey(
      base: base,
      selectedVariant: variant,
      resolvedLocator: "https://example.com/private",
      requestHeaderFingerprint: "headers-v1",
      credentialGeneration: CredentialGeneration(1)
    )
    let new = FetchExecutionKey(
      base: base,
      selectedVariant: variant,
      resolvedLocator: "https://example.com/private",
      requestHeaderFingerprint: "headers-v1",
      credentialGeneration: CredentialGeneration(2)
    )

    XCTAssertEqual(old.baseDigest, new.baseDigest)
    XCTAssertEqual(old.selectedVariantDigest, new.selectedVariantDigest)
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
      data: data,
      contentID: contentID.description,
      namespace: "public:tests"
    )

    XCTAssertFalse(stored.physicalID.description.contains(contentID.digestHex))
    XCTAssertNotEqual(stored.physicalID.description, contentID.digestHex)
  }

  func testHeadersOnlyEnterPersistentVariantWhenSelectedByVary_CACHE_PT_004() throws {
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.com/language.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    let localized = try ImageRequest(
      url: request.url,
      target: request.target,
      namespace: request.namespace,
      headers: ["Accept-Language": "zh-CN"]
    )

    XCTAssertEqual(request.fetchVariantKey, localized.fetchVariantKey)
    let selection = try XCTUnwrap(localized.varySelection(fieldNames: ["Accept-Language"]))
    let variant = localized.fetchVariantKey(for: selection)
    XCTAssertEqual(variant.requestVariants, ["accept-language": "v:zh-cn"])
    XCTAssertNotEqual(variant, localized.fetchVariantKey)
  }

  func testSensitiveHeadersDoNotEnterPersistentVariant_AUTH_PT_006() throws {
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
    XCTAssertTrue(request.fetchVariantKey.requestVariants.isEmpty)
    XCTAssertNil(request.varySelection(fieldNames: ["Authorization"]))
  }

  func testSensitiveVaryUsesExplicitFingerprintInsteadOfRawCredential_AUTH_PT_005() throws {
    let secret = "session=top-secret"
    let fingerprint = try HeaderVariantFingerprint(
      sha256Hex: String(repeating: "a", count: 64)
    )
    let request = try ImageRequest(
      url: try XCTUnwrap(URL(string: "https://example.com/cookie.png")),
      target: try TargetPixels(width: 20, height: 20),
      namespace: SecurityNamespaceID("account-a"),
      authorizationContext: AuthorizationContextID("principal-a"),
      credentialGeneration: CredentialGeneration(7),
      headers: ["Cookie": secret],
      headerVariantFingerprints: ["Cookie": fingerprint]
    )
    let selection = try XCTUnwrap(request.varySelection(fieldNames: ["Cookie"]))
    let variant = request.fetchVariantKey(for: selection)

    XCTAssertEqual(variant.requestVariants, ["cookie": "f:\(fingerprint.sha256Hex)"])
    XCTAssertNil(variant.canonicalBytes.range(of: Data(secret.utf8)))
  }

  func testFingerprintIsRejectedForNonCredentialHeader() throws {
    let fingerprint = try HeaderVariantFingerprint(
      sha256Hex: String(repeating: "b", count: 64)
    )

    XCTAssertThrowsError(
      try ImageRequest(
        url: XCTUnwrap(URL(string: "https://example.com/public.png")),
        target: TargetPixels(width: 20, height: 20),
        namespace: .publicNamespace(appID: "tests"),
        headers: ["Accept-Language": "zh-CN"],
        headerVariantFingerprints: ["Accept-Language": fingerprint]
      )
    ) { error in
      XCTAssertEqual(
        error as? ImageRequestError,
        .fingerprintForNonCredentialHeader("accept-language")
      )
    }
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

    XCTAssertEqual(first.fetchBaseKey, refreshed.fetchBaseKey)
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

    XCTAssertEqual(first.fetchBaseKey, second.fetchBaseKey)
    XCTAssertEqual(first.url.absoluteString, "https://example.com/a%2Fb?x=1&x=2")
    XCTAssertNotEqual(first.fetchBaseKey, reordered.fetchBaseKey)
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

    let locator = "https://user:credential@example.com/a.png"
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

  func testCustomCredentialHeaderIsExcludedFromPersistentIdentity_AUTH_PT_012() throws {
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
    XCTAssertTrue(request.fetchVariantKey.requestVariants.isEmpty)
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

    XCTAssertEqual(authorization.fetchBaseKey, custom.fetchBaseKey)
    XCTAssertEqual(authorization.fetchVariantKey, custom.fetchVariantKey)
    XCTAssertNotEqual(authorization.fetchExecutionKey, custom.fetchExecutionKey)
  }

  func testNonSensitiveHeaderValueChangesExactExecutionBeforeVaryIsKnown() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/language.png"))
    let chinese = try ImageRequest(
      url: url,
      target: try TargetPixels(width: 20, height: 20),
      namespace: .publicNamespace(appID: "tests"),
      headers: ["Accept-Language": "zh-CN"]
    )
    let english = try ImageRequest(
      url: url,
      target: try TargetPixels(width: 20, height: 20),
      namespace: .publicNamespace(appID: "tests"),
      headers: ["Accept-Language": "en-US"]
    )

    XCTAssertEqual(chinese.fetchVariantKey, english.fetchVariantKey)
    XCTAssertNotEqual(chinese.fetchExecutionKey, english.fetchExecutionKey)
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
      oldCredential.fetchExecutionKey(
        selectedVariant: nil,
        revalidationFingerprint: "etag-v1"
      ),
      oldCredential.fetchExecutionKey(
        selectedVariant: nil,
        revalidationFingerprint: "etag-v2"
      )
    )
  }

  func testRevalidationStateChangesFetchExecutionKey() {
    let base = makeBase(source: "https://example.com/revalidate")
    let variant = FetchVariantKey(base: base)
    let unconditional = FetchExecutionKey(
      base: base,
      selectedVariant: variant,
      resolvedLocator: "https://example.com/revalidate",
      requestHeaderFingerprint: "headers"
    )
    let conditional = FetchExecutionKey(
      base: base,
      selectedVariant: variant,
      resolvedLocator: "https://example.com/revalidate",
      requestHeaderFingerprint: "headers",
      revalidationFingerprint: "etag-v1"
    )

    XCTAssertNotEqual(unconditional.digestHex, conditional.digestHex)
  }

  func testTransportRetryPolicyChangesExactExecutionIdentityPipePt002() throws {
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/retry-policy-identity.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    let first = request.fetchExecutionKey(
      selectedVariant: nil,
      revalidationFingerprint: "unconditional",
      transportPolicyFingerprint: TransportRetryPolicy(maximumAttempts: 1).fingerprint
    )
    let second = request.fetchExecutionKey(
      selectedVariant: nil,
      revalidationFingerprint: "unconditional",
      transportPolicyFingerprint: TransportRetryPolicy(maximumAttempts: 3).fingerprint
    )

    XCTAssertNotEqual(first, second)
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

  private func makeBase(source: String) -> FetchBaseKey {
    FetchBaseKey(
      source: LogicalSourceID(source),
      namespace: .publicNamespace(appID: "tests")
    )
  }
}
