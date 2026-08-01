import AkashicDisk
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class VaryCacheTests: XCTestCase {
    func testVarySelectionAndFingerprintCodableRoundTripPreservesCanonicalForm() throws {
        let digest = String(repeating: "a", count: 64)
        let selection = try HTTPVarySelection(
            fieldNames: ["Accept-Language", "accept-encoding", "ACCEPT-LANGUAGE"],
            values: [
                "accept-language": .field("zh-CN"),
                "accept-encoding": .fingerprint(digest),
            ]
        )
        let fingerprint = try HeaderVariantFingerprint(sha256Hex: digest)

        let selectionData = try JSONEncoder().encode(selection)
        let fingerprintData = try JSONEncoder().encode(fingerprint)

        XCTAssertEqual(selection.values["accept-language"], .field("zh-cn"))
        XCTAssertEqual(
            try JSONDecoder().decode(HTTPVarySelection.self, from: selectionData), selection)
        XCTAssertEqual(
            try JSONDecoder().decode(HeaderVariantFingerprint.self, from: fingerprintData),
            fingerprint
        )
        XCTAssertEqual(fingerprint.description, digest)
    }

    func testVarySelectionNormalizesSemanticFieldValues() throws {
        let selection = try HTTPVarySelection(
            fieldNames: ["Accept-Language", "X-Custom"],
            values: [
                "accept-language": .field(" ZH-CN , EN-US "),
                "x-custom": .field("  Case-Sensitive  "),
            ]
        )

        XCTAssertEqual(selection.fieldNames, ["accept-language", "x-custom"])
        XCTAssertEqual(selection.values["accept-language"], .field("zh-cn,en-us"))
        XCTAssertEqual(selection.values["x-custom"], .field("Case-Sensitive"))
    }

    func testVarySelectionRejectsNoncanonicalPersistentRepresentation() throws {
        let malformed = Data(
            #"{"fieldNames":["Accept-Language"],"values":{"Accept-Language":{"field":{"_0":"en"}}}}"#
                .utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(HTTPVarySelection.self, from: malformed))

        let noncanonicalValue = Data(
            #"{"fieldNames":["accept-language"],"values":{"accept-language":{"field":{"_0":"ZH-CN"}}}}"#
                .utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(HTTPVarySelection.self, from: noncanonicalValue))
    }

    func testAcceptLanguageVariantsCoexistAndHitCorrectBodies_CACHE_PT_004() async throws {
        let root = try makeTemporaryDirectory()
        let chineseBody = try makePNG(red: 220)
        let englishBody = try makePNG(red: 30)
        let transport = FakeHTTPTransport(stubs: [
            .init(
                statusCode: 200,
                headers: cacheableHeaders(vary: "Accept-Language"),
                body: chineseBody
            ),
            .init(
                statusCode: 200,
                headers: cacheableHeaders(vary: "accept-language"),
                body: englishBody
            ),
        ])
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let pipeline = makePipeline(transport: transport, encoded: encoded, records: records)
        let chinese = try languageRequest("zh-CN")
        let english = try languageRequest("en-US")

        let chineseImage = try await pipeline.image(for: chinese)
        let englishImage = try await pipeline.image(for: english)
        XCTAssertGreaterThan(try centerRedComponent(of: chineseImage.cgImage), 180)
        XCTAssertLessThan(try centerRedComponent(of: englishImage.cgImage), 80)

        let candidates = await records.records(
            for: chinese.fetchBaseKey.digestHex,
            namespace: chinese.namespace.value,
            namespaceGeneration: 0
        )
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(Set(candidates.map(\.vary.fieldNames)), [["accept-language"]])

        let coldTransport = FakeHTTPTransport(stubs: [])
        let coldPipeline = makePipeline(
            transport: coldTransport,
            encoded: encoded,
            records: records
        )
        let coldChinese = try await coldPipeline.image(for: chinese)
        let coldEnglish = try await coldPipeline.image(for: english)
        XCTAssertGreaterThan(try centerRedComponent(of: coldChinese.cgImage), 180)
        XCTAssertLessThan(try centerRedComponent(of: coldEnglish.cgImage), 80)
        let coldRequestCount = await coldTransport.capturedRequests().count
        XCTAssertEqual(coldRequestCount, 0)
    }

    func testSensitiveVaryWithoutFingerprintNeverPersists_AUTH_PT_005() async throws {
        let root = try makeTemporaryDirectory()
        let body = try makePNG(red: 120)
        let transport = FakeHTTPTransport(stubs: [
            .init(statusCode: 200, headers: cacheableHeaders(vary: "Cookie"), body: body),
            .init(statusCode: 200, headers: cacheableHeaders(vary: "Cookie"), body: body),
        ])
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let pipeline = makePipeline(transport: transport, encoded: encoded, records: records)
        let request = try cookieRequest(value: "session=one", fingerprint: nil)

        _ = try await pipeline.image(for: request)
        _ = try await pipeline.image(for: request)

        let requestCount = await transport.capturedRequests().count
        let candidates = await records.records(
            for: request.fetchBaseKey.digestHex,
            namespace: request.namespace.value,
            namespaceGeneration: 0
        )
        let physicalID = await encoded.physicalID(
            contentID: ContentID(data: body).description,
            namespace: request.namespace.value
        )
        XCTAssertEqual(requestCount, 2)
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertNil(physicalID)
    }

    func testAuthLikeCustomVaryHeaderFailsClosedWithoutDeclaration_AUTH_PT_012() async throws {
        let root = try makeTemporaryDirectory()
        let body = try makePNG(red: 100)
        let transport = FakeHTTPTransport(stubs: [
            .init(statusCode: 200, headers: cacheableHeaders(vary: "X-Session-ID"), body: body),
            .init(statusCode: 200, headers: cacheableHeaders(vary: "X-Session-ID"), body: body),
        ])
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let pipeline = makePipeline(transport: transport, encoded: encoded, records: records)
        let request = try ImageRequest(
            url: XCTUnwrap(URL(string: "https://example.com/private-session.png")),
            target: TargetPixels(width: 20, height: 20),
            namespace: SecurityNamespaceID("account-session"),
            authorizationContext: AuthorizationContextID("principal-session"),
            credentialGeneration: CredentialGeneration(1),
            headers: ["X-Session-ID": "private-session-value"]
        )

        XCTAssertTrue(request.containsCredentialHeaders)
        _ = try await pipeline.image(for: request)
        _ = try await pipeline.image(for: request)

        let requestCount = await transport.capturedRequests().count
        let candidates = await records.records(
            for: request.fetchBaseKey.digestHex,
            namespace: request.namespace.value,
            namespaceGeneration: 0
        )
        let manifestURL = root.appendingPathComponent("records/representation-records.json")
        let manifest = (try? String(contentsOf: manifestURL, encoding: .utf8)) ?? ""
        XCTAssertEqual(requestCount, 2)
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertFalse(manifest.contains("private-session-value"))
    }

    func testSensitiveVaryFingerprintsIsolatePersistentVariants_AUTH_PT_005() async throws {
        let root = try makeTemporaryDirectory()
        let firstBody = try makePNG(red: 210)
        let secondBody = try makePNG(red: 25)
        let transport = FakeHTTPTransport(stubs: [
            .init(statusCode: 200, headers: cacheableHeaders(vary: "Cookie"), body: firstBody),
            .init(statusCode: 200, headers: cacheableHeaders(vary: "Cookie"), body: secondBody),
        ])
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let pipeline = makePipeline(transport: transport, encoded: encoded, records: records)
        let first = try cookieRequest(
            value: "session=one",
            fingerprint: String(repeating: "1", count: 64)
        )
        let second = try cookieRequest(
            value: "session=two",
            fingerprint: String(repeating: "2", count: 64)
        )

        _ = try await pipeline.image(for: first)
        _ = try await pipeline.image(for: second)
        let candidates = await records.records(
            for: first.fetchBaseKey.digestHex,
            namespace: first.namespace.value,
            namespaceGeneration: 0
        )
        XCTAssertEqual(candidates.count, 2)

        let manifest = try String(
            contentsOf: root.appendingPathComponent("records/representation-records.json"),
            encoding: .utf8
        )
        XCTAssertFalse(manifest.contains("session=one"))
        XCTAssertFalse(manifest.contains("session=two"))

        let coldTransport = FakeHTTPTransport(stubs: [])
        let coldPipeline = makePipeline(
            transport: coldTransport,
            encoded: encoded,
            records: records
        )
        let coldFirst = try await coldPipeline.image(for: first)
        let coldSecond = try await coldPipeline.image(for: second)
        let coldRequestCount = await coldTransport.capturedRequests().count
        XCTAssertGreaterThan(try centerRedComponent(of: coldFirst.cgImage), 180)
        XCTAssertLessThan(try centerRedComponent(of: coldSecond.cgImage), 80)
        XCTAssertEqual(coldRequestCount, 0)
    }

    func testNoStoreRevalidationRemovesOnlySelectedVariant_CACHE_PT_005() async throws {
        let root = try makeTemporaryDirectory()
        let sharedBody = try makePNG(red: 140)
        let transport = FakeHTTPTransport(stubs: [
            .init(
                statusCode: 200,
                headers: [
                    "Content-Type": "image/png",
                    "Cache-Control": "max-age=0",
                    "Vary": "Accept-Language",
                    "ETag": "zh-v1",
                ],
                body: sharedBody
            ),
            .init(
                statusCode: 200,
                headers: cacheableHeaders(vary: "Accept-Language"),
                body: sharedBody
            ),
            .init(statusCode: 304, headers: ["Cache-Control": "no-store"], body: Data()),
        ])
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let pipeline = makePipeline(transport: transport, encoded: encoded, records: records)
        let chinese = try languageRequest("zh-CN")
        let english = try languageRequest("en-US")

        _ = try await pipeline.image(for: chinese)
        _ = try await pipeline.image(for: english)
        _ = try await pipeline.image(for: chinese)

        let remaining = await records.records(
            for: english.fetchBaseKey.digestHex,
            namespace: english.namespace.value,
            namespaceGeneration: 0
        )
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.vary.values["accept-language"], .field("en-us"))
        let physicalID = await encoded.physicalID(
            contentID: ContentID(data: sharedBody).description,
            namespace: english.namespace.value
        )
        XCTAssertNotNil(physicalID)

        let coldTransport = FakeHTTPTransport(stubs: [])
        let coldPipeline = makePipeline(
            transport: coldTransport,
            encoded: encoded,
            records: records
        )
        _ = try await coldPipeline.image(for: english)
        let coldRequestCount = await coldTransport.capturedRequests().count
        XCTAssertEqual(coldRequestCount, 0)
    }

    private func makePipeline(
        transport: FakeHTTPTransport,
        encoded: AkashicOriginalEncodedStore,
        records: RepresentationRecordStore
    ) -> FoveaPipeline {
        FoveaPipeline(
            transport: transport,
            encodedStore: encoded,
            recordStore: records,
            profileAccessPolicy: .unrestricted,
            decoder: ImageIOImageDecoder()
        )
    }

    private func languageRequest(_ value: String) throws -> ImageRequest {
        try ImageRequest(
            url: XCTUnwrap(URL(string: "https://example.com/localized.png")),
            target: TargetPixels(width: 20, height: 20),
            namespace: .publicNamespace(appID: "tests"),
            headers: ["Accept-Language": value]
        )
    }

    private func cookieRequest(value: String, fingerprint: String?) throws -> ImageRequest {
        let fingerprints: [String: HeaderVariantFingerprint]
        if let fingerprint {
            fingerprints = ["Cookie": try HeaderVariantFingerprint(sha256Hex: fingerprint)]
        } else {
            fingerprints = [:]
        }
        return try ImageRequest(
            url: XCTUnwrap(URL(string: "https://example.com/private-cookie.png")),
            target: TargetPixels(width: 20, height: 20),
            namespace: SecurityNamespaceID("account-cookie"),
            authorizationContext: AuthorizationContextID("principal-cookie"),
            credentialGeneration: CredentialGeneration(1),
            headers: ["Cookie": value],
            headerVariantFingerprints: fingerprints
        )
    }

    private func cacheableHeaders(vary: String) -> [String: String] {
        [
            "Content-Type": "image/png",
            "Cache-Control": "max-age=3600",
            "Vary": vary,
        ]
    }
}
