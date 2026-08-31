import AkashicDisk
import CryptoKit
import FoveaCore
import FoveaHTTP
import FoveaPersistence
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

    func testFetchBaseKeyDigestUsesStableSHA256AiqaMut013() {
        let key = FetchBaseKey(
            source: LogicalSourceID("https://example.test/golden.png"),
            namespace: SecurityNamespaceID("account-golden"),
            authorizationContext: AuthorizationContextID("principal-golden")
        )
        let expected = SHA256.hash(data: key.canonicalBytes)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(key.digestHex, expected)
        XCTAssertEqual(key.digestHex.count, 64)
    }

    func testPersistentIdentityGoldenVectorsAreArchitectureStable_CACHE_PT_017() {
        #if arch(arm64)
            let compiledArchitecture = "arm64"
        #elseif arch(x86_64)
            let compiledArchitecture = "x86_64"
        #else
            let compiledArchitecture = "unsupported"
        #endif
        let expectedArchitecture = ProcessInfo.processInfo.environment[
            "FOVEA_EXPECTED_TEST_ARCH"
        ]
        if let expectedArchitecture {
            XCTAssertEqual(compiledArchitecture, expectedArchitecture)
        }
        let base = FetchBaseKey(
            source: LogicalSourceID("asset:golden:42"),
            namespace: SecurityNamespaceID("private:account-golden"),
            authorizationContext: AuthorizationContextID("principal-golden:v7")
        )
        let variant = FetchVariantKey(
            base: base,
            requestVariants: [
                "Accept-Language": "v:zh-cn",
                "DPR": "v:2",
            ]
        )
        let execution = FetchExecutionKey(
            base: base,
            selectedVariant: variant,
            resolvedLocator: "https://cdn.example.test/avatar.png?sig=rotating",
            requestHeaderFingerprint: String(repeating: "a", count: 64),
            credentialGeneration: CredentialGeneration(7),
            revalidationFingerprint: "etag:abc",
            transportPolicyFingerprint: "secure-default-v1"
        )

        XCTAssertEqual(
            base.canonicalBytes.hexString,
            "00010000000f61737365743a676f6c64656e3a343200000016707269766174653a6163636f756e742d676f6c64656e000000137072696e636970616c2d676f6c64656e3a763700000003474554"
        )
        XCTAssertEqual(
            base.digestHex, "9f89bf82bcbf083044ca3b51b956b59d4815d0d7748232aa57072b74e22727a4")
        XCTAssertEqual(
            variant.canonicalBytes.hexString,
            "00020000004039663839626638326263626630383330343463613362353162393536623539643438313564306437373438323332616135373037326237346532323732376134000000020000000f6163636570742d6c616e677561676500000007763a7a682d636e0000000364707200000003763a32"
        )
        XCTAssertEqual(
            variant.digestHex, "7e70b364c0098e94b65146f7435fae2d0e8fa4920f1f9187957f6f10c79e9d12")
        XCTAssertEqual(
            execution.canonicalBytes.hexString,
            "000200000040396638396266383262636266303833303434636133623531623935366235396434383135643064373734383233326161353730373262373465323237323761340100000040376537306233363463303039386539346236353134366637343335666165326430653866613439323066316639313837393537663666313063373965396431320000003068747470733a2f2f63646e2e6578616d706c652e746573742f6176617461722e706e673f7369673d726f746174696e67000000406161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616101000000000000000700000008657461673a616263000000117365637572652d64656661756c742d7631"
        )
        XCTAssertEqual(
            execution.digestHex, "b230829ec35e249fa3a4f24a9db56c767ea63f749ec1295383bb0c884c2d3214")
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
        let store = try await AkashicOriginalEncodedStore.open(root: root, softLimitBytes: 1024)
        let data = Data("known-content".utf8)
        let contentID = ContentID(data: data)
        let stored = try await store.commit(
            data: data,
            contentID: contentID.description,
            namespace: "public:tests"
        )

        XCTAssertFalse(stored.physicalID.foveaStorageFileName.contains(contentID.digestHex))
        XCTAssertNotEqual(stored.physicalID.foveaStorageFileName, contentID.digestHex)
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

    func testImageRequestRejectsOversizedHeaderCollection() throws {
        let headers = Dictionary(
            uniqueKeysWithValues: (0..<65).map { index in
                ("X-Test-\(index)", "value")
            })

        XCTAssertThrowsError(
            try ImageRequest(
                url: XCTUnwrap(URL(string: "https://example.com/headers")),
                target: TargetPixels(width: 20, height: 20),
                namespace: .publicNamespace(appID: "tests"),
                headers: headers
            )
        ) { error in
            XCTAssertEqual(error as? ImageRequestError, .headerCollectionTooLarge)
        }
    }

    func testImageRequestRejectsOversizedURL() throws {
        let path = String(repeating: "a", count: 17 * 1024)
        let url = try XCTUnwrap(URL(string: "https://example.com/\(path)"))

        XCTAssertThrowsError(
            try ImageRequest.publicImage(
                url: url,
                target: TargetPixels(width: 20, height: 20),
                appID: "tests"
            )
        ) { error in
            XCTAssertEqual(error as? ImageRequestError, .urlTooLong)
        }
    }

    func testImageRequestBoundsIdentityComponentsBeforePipelineUse_RES_PT_016() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/identity-bounds.png"))
        let target = try TargetPixels(width: 20, height: 20)

        XCTAssertThrowsError(
            try ImageRequest(
                url: url,
                logicalSource: LogicalSourceID(""),
                target: target,
                namespace: .publicNamespace(appID: "tests")
            )
        ) { error in
            XCTAssertEqual(
                error as? ImageRequestError,
                .invalidIdentityComponent("logical-source")
            )
        }

        XCTAssertThrowsError(
            try ImageRequest(
                url: url,
                target: target,
                namespace: SecurityNamespaceID(String(repeating: "n", count: 4 * 1024 + 1))
            )
        ) { error in
            XCTAssertEqual(
                error as? ImageRequestError,
                .identityComponentTooLarge("namespace")
            )
        }

        XCTAssertThrowsError(
            try ImageRequest(
                url: url,
                target: target,
                geometryPolicyFingerprint: String(repeating: "g", count: 1025),
                namespace: .publicNamespace(appID: "tests")
            )
        ) { error in
            XCTAssertEqual(
                error as? ImageRequestError,
                .identityComponentTooLarge("geometry-policy-fingerprint")
            )
        }
    }

    func testImageRequestRejectsControlCharactersInIdentityComponents_RES_PT_016() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/identity-controls.png"))
        let target = try TargetPixels(width: 20, height: 20)

        for control in ["\n", "\u{001B}", "\u{007F}"] {
            XCTAssertThrowsError(
                try ImageRequest(
                    url: url,
                    logicalSource: LogicalSourceID("asset:\(control):42"),
                    target: target,
                    namespace: .publicNamespace(appID: "tests")
                )
            ) { error in
                XCTAssertEqual(
                    error as? ImageRequestError, .invalidIdentityComponent("logical-source"))
            }
            XCTAssertThrowsError(
                try ImageRequest(
                    url: url,
                    target: target,
                    namespace: SecurityNamespaceID("account\(control)value")
                )
            ) { error in
                XCTAssertEqual(error as? ImageRequestError, .invalidIdentityComponent("namespace"))
            }
            XCTAssertThrowsError(
                try ImageRequest(
                    url: url,
                    target: target,
                    namespace: .publicNamespace(appID: "tests"),
                    authorizationContext: AuthorizationContextID("principal\(control)value")
                )
            ) { error in
                XCTAssertEqual(
                    error as? ImageRequestError,
                    .invalidIdentityComponent("authorization-context")
                )
            }
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

    func testImageRequestRejectsRemoteCleartextButAllowsLoopback_SEC_CASE_033() throws {
        XCTAssertThrowsError(
            try ImageRequest.publicImage(
                url: XCTUnwrap(URL(string: "http://example.test/image.png")),
                target: TargetPixels(width: 20, height: 20),
                appID: "tests"
            )
        ) { error in
            XCTAssertEqual(error as? ImageRequestError, .insecureRemoteHTTP)
        }

        let ipv4 = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "http://127.0.0.1:8080/image.png")),
            target: TargetPixels(width: 20, height: 20),
            appID: "tests"
        )
        let ipv6 = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "http://[::1]:8080/image.png")),
            target: TargetPixels(width: 20, height: 20),
            appID: "tests"
        )

        XCTAssertEqual(ipv4.url.scheme, "http")
        XCTAssertEqual(ipv6.url.host, "::1")
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

    func testNetworkPolicyChangesExecutionButNotPersistentIdentity_RES_PT_008() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/network-policy.png"))
        let interactive = try ImageRequest.publicImage(
            url: url,
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests",
            networkPolicy: .interactive
        )
        let conservative = try ImageRequest.publicImage(
            url: url,
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests",
            networkPolicy: .conservative
        )

        XCTAssertEqual(interactive.fetchBaseKey, conservative.fetchBaseKey)
        XCTAssertEqual(interactive.fetchVariantKey, conservative.fetchVariantKey)
        XCTAssertNotEqual(interactive.fetchExecutionKey, conservative.fetchExecutionKey)
        XCTAssertNotEqual(interactive.displayIdentity, conservative.displayIdentity)
    }

    func testRetargetedRequestReusesValidatedFetchIdentity_GEO_PT_011() throws {
        let original = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.com/retarget.png")),
            logicalSource: LogicalSourceID("asset:retarget"),
            target: TargetPixels(width: 16, height: 16),
            appID: "tests",
            networkPolicy: .conservative
        )
        let target = ResolvedImageTarget(
            pixels: try TargetPixels(width: 320, height: 180),
            contentMode: .fill,
            geometryPolicyFingerprint: "geometry-v2:test",
            cacheAdmission: .transient
        )

        let retargeted = try original.retargeted(to: target)

        XCTAssertEqual(retargeted.fetchBaseKey, original.fetchBaseKey)
        XCTAssertEqual(original.fetchBaseDigest, original.fetchBaseKey.digestHex)
        XCTAssertEqual(retargeted.fetchBaseDigest, original.fetchBaseDigest)
        XCTAssertEqual(
            retargeted.storageNamespaceFingerprint,
            original.storageNamespaceFingerprint
        )
        XCTAssertEqual(retargeted.fetchVariantKey, original.fetchVariantKey)
        XCTAssertEqual(retargeted.fetchExecutionKey, original.fetchExecutionKey)
        XCTAssertEqual(retargeted.target, target.pixels)
        XCTAssertEqual(retargeted.contentMode, .fill)
        XCTAssertEqual(retargeted.renderCacheAdmission, .transient)
        XCTAssertNotEqual(retargeted.displayIdentity, original.displayIdentity)
    }

    func testReprioritizedRequestPreservesCachedPersistentIdentity_PIPE_PT_017() throws {
        let original = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.com/reprioritized.png")),
            logicalSource: LogicalSourceID("asset:reprioritized"),
            target: try TargetPixels(width: 48, height: 48),
            appID: "tests"
        )
        let reprioritized = original.reprioritized(.high)

        XCTAssertEqual(reprioritized.fetchBaseDigest, original.fetchBaseDigest)
        XCTAssertEqual(
            reprioritized.storageNamespaceFingerprint,
            original.storageNamespaceFingerprint
        )
        XCTAssertEqual(reprioritized.fetchBaseKey, original.fetchBaseKey)
        XCTAssertEqual(reprioritized.fetchVariantKey, original.fetchVariantKey)
        XCTAssertEqual(reprioritized.priority, .high)
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

    func testContentIDPersistentDescriptionRequiresCanonicalMatchingLength() throws {
        let digest = String(repeating: "a", count: 64)
        let restored = try XCTUnwrap(
            ContentID(persistentDescription: "sha256:\(digest):12", expectedByteCount: 12)
        )
        XCTAssertEqual(restored.digestHex, digest)
        XCTAssertEqual(restored.byteCount, 12)

        XCTAssertNil(ContentID(persistentDescription: "sha256:\(digest):12", expectedByteCount: 11))
        XCTAssertNil(
            ContentID(persistentDescription: "sha256:\(digest):012", expectedByteCount: 12))
        XCTAssertNil(ContentID(persistentDescription: "sha256:\(digest):-1", expectedByteCount: -1))
        XCTAssertNil(
            ContentID(
                persistentDescription: "sha256:\(String(repeating: "A", count: 64)):12",
                expectedByteCount: 12
            )
        )
        XCTAssertNil(ContentID(persistentDescription: "sha1:\(digest):12", expectedByteCount: 12))
        XCTAssertNil(ContentID(persistentDescription: "sha256:\(digest)", expectedByteCount: 12))
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

extension Data {
    fileprivate var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
