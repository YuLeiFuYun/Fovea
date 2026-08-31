import FoveaHTTP
import XCTest

final class T100HTTPCacheRecordMatchTests: XCTestCase {
    func testRecordMatchesRequestEqualsSingleCandidateSelection_CACHE_MATCH_PT_001() throws {
        let vary = try HTTPVarySelection(
            fieldNames: ["accept-language"],
            values: ["accept-language": .field("en-us")]
        )
        let record = makeRepresentationRecord(
            namespace: "public",
            baseKeyDigest: "cache-match-base",
            variantKeyDigest: "cache-match-variant",
            vary: vary
        )
        let matchingHeaders = ["accept-language": " EN-US "]
        let mismatchHeaders = ["accept-language": "fr-FR"]

        XCTAssertTrue(
            HTTPCachePolicy.recordMatchesRequest(
                record,
                requestHeaders: matchingHeaders,
                additionalSensitiveNames: [],
                sensitiveFingerprints: [:]
            )
        )
        XCTAssertEqual(
            HTTPCachePolicy.selectRecord(
                from: [record],
                requestHeaders: matchingHeaders,
                additionalSensitiveNames: [],
                sensitiveFingerprints: [:]
            ),
            record
        )

        XCTAssertFalse(
            HTTPCachePolicy.recordMatchesRequest(
                record,
                requestHeaders: mismatchHeaders,
                additionalSensitiveNames: [],
                sensitiveFingerprints: [:]
            )
        )
        XCTAssertNil(
            HTTPCachePolicy.selectRecord(
                from: [record],
                requestHeaders: mismatchHeaders,
                additionalSensitiveNames: [],
                sensitiveFingerprints: [:]
            )
        )
    }

    func testRecordMatchesRequestFailsClosedForNoStore_CACHE_MATCH_PT_002() {
        let record = makeRepresentationRecord(
            namespace: "public",
            baseKeyDigest: "cache-no-store-base",
            variantKeyDigest: "cache-no-store-variant",
            disposition: .noStore
        )

        XCTAssertFalse(
            HTTPCachePolicy.recordMatchesRequest(
                record,
                requestHeaders: [:],
                additionalSensitiveNames: [],
                sensitiveFingerprints: [:]
            )
        )
        XCTAssertNil(
            HTTPCachePolicy.selectRecord(
                from: [record],
                requestHeaders: [:],
                additionalSensitiveNames: [],
                sensitiveFingerprints: [:]
            )
        )
    }

    func testRecordMatchesRequestUsesExactSensitiveFingerprint_CACHE_MATCH_PT_003() throws {
        let digestA = String(repeating: "a", count: 64)
        let digestB = String(repeating: "b", count: 64)
        let vary = try HTTPVarySelection(
            fieldNames: ["authorization"],
            values: ["authorization": .fingerprint(digestA)]
        )
        let record = makeRepresentationRecord(
            namespace: "private",
            baseKeyDigest: "cache-sensitive-base",
            variantKeyDigest: "cache-sensitive-variant",
            vary: vary,
            disposition: .privateNamespace
        )
        let fingerprintA = try HeaderVariantFingerprint(sha256Hex: digestA)
        let fingerprintB = try HeaderVariantFingerprint(sha256Hex: digestB)

        XCTAssertTrue(
            HTTPCachePolicy.recordMatchesRequest(
                record,
                requestHeaders: [:],
                additionalSensitiveNames: ["authorization"],
                sensitiveFingerprints: ["authorization": fingerprintA]
            )
        )
        XCTAssertFalse(
            HTTPCachePolicy.recordMatchesRequest(
                record,
                requestHeaders: [:],
                additionalSensitiveNames: ["authorization"],
                sensitiveFingerprints: ["authorization": fingerprintB]
            )
        )
    }
}
