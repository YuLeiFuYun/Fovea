import Foundation
import FoveaHTTP
import XCTest

final class HTTPCachePolicyTests: XCTestCase {
    func testAgeConsumesFreshness_HTTP_CONF_AGE_001() throws {
        let requestTime = Date(timeIntervalSince1970: 1_000)
        let responseTime = requestTime.addingTimeInterval(2)
        let expiration = HTTPCachePolicy.expiration(
            requestTime: requestTime,
            responseTime: responseTime,
            headers: ["Cache-Control": "max-age=60", "Age": "50"]
        )
        XCTAssertEqual(
            try XCTUnwrap(expiration).timeIntervalSince(responseTime), 8, accuracy: 0.001)
    }

    func testMalformedAgeFailsConservativelyStale_HTTP_CONF_AGE_003() throws {
        let responseTime = Date(timeIntervalSince1970: 10_000)
        let expiration = HTTPCachePolicy.expiration(
            requestTime: responseTime,
            responseTime: responseTime,
            headers: ["Cache-Control": "max-age=3600", "Age": "not-a-number"]
        )
        XCTAssertEqual(expiration, responseTime)
    }

    func testDeltaSecondsRejectsFractionalAndScientificNotation() {
        let responseTime = Date(timeIntervalSince1970: 10_000)
        for value in ["1.5", "1e3", "+10", "-1"] {
            let expiration = HTTPCachePolicy.expiration(
                requestTime: responseTime,
                responseTime: responseTime,
                headers: ["Cache-Control": "max-age=3600", "Age": value]
            )
            XCTAssertEqual(expiration, responseTime)
            XCTAssertNil(
                HTTPCachePolicy.retryAfterNanoseconds(
                    in: ["Retry-After": value],
                    now: responseTime,
                    maximum: 10_000_000_000
                )
            )
        }

        XCTAssertEqual(
            HTTPCachePolicy.expiration(
                requestTime: responseTime,
                responseTime: responseTime,
                headers: ["Cache-Control": "max-age=1e3"]
            ),
            responseTime
        )
    }

    func testCacheControlQuotedCommaDoesNotCreatePhantomDirective() throws {
        let responseTime = Date(timeIntervalSince1970: 20_000)
        let expiration = HTTPCachePolicy.expiration(
            requestTime: responseTime,
            responseTime: responseTime,
            headers: ["Cache-Control": "private=\"field-a,no-cache\", max-age=60"]
        )
        let interval = try XCTUnwrap(expiration).timeIntervalSince(responseTime)
        XCTAssertEqual(interval, 60, accuracy: 0.001)
    }

    func testAmbiguousCacheControlFailsConservatively() {
        let responseTime = Date(timeIntervalSince1970: 30_000)
        for value in [
            "max-age=3600, max-age=1",
            "max-age=3600, private=\"unterminated",
            "max-age=3600, bad directive=value",
        ] {
            XCTAssertEqual(
                HTTPCachePolicy.expiration(
                    requestTime: responseTime,
                    responseTime: responseTime,
                    headers: ["Cache-Control": value]
                ),
                responseTime
            )
            XCTAssertEqual(
                HTTPCachePolicy.disposition(
                    headers: ["Cache-Control": value],
                    isPrivateNamespace: false
                ),
                .noStore
            )
        }
    }

    func testHTTPDateParserAcceptsObsoleteWireFormats() throws {
        let expected = try XCTUnwrap(HTTPDateParser.date(from: "Sun, 06 Nov 1994 08:49:37 GMT"))
        let rfc850 = try XCTUnwrap(HTTPDateParser.date(from: "Sunday, 06-Nov-94 08:49:37 GMT"))
        let asctime = try XCTUnwrap(HTTPDateParser.date(from: "Sun Nov 6 08:49:37 1994"))
        XCTAssertEqual(rfc850, expected)
        XCTAssertEqual(asctime, expected)
    }

    func testDateApparentAgeCannotIncreaseFreshness_HTTP_CONF_AGE_002() throws {
        let responseTime = Date(timeIntervalSince1970: 10_000)
        let requestTime = responseTime.addingTimeInterval(-1)
        let serverDate = Date(timeIntervalSince1970: 9_970)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"

        let expiration = HTTPCachePolicy.expiration(
            requestTime: requestTime,
            responseTime: responseTime,
            headers: [
                "Cache-Control": "max-age=40",
                "Date": formatter.string(from: serverDate),
            ]
        )
        XCTAssertEqual(
            try XCTUnwrap(expiration).timeIntervalSince(responseTime), 10, accuracy: 0.001)
    }
    func testNoCacheOverridesPositiveMaxAge_HTTP_CONF_NO_CACHE_001() {
        let responseTime = Date(timeIntervalSince1970: 20_000)
        let expiration = HTTPCachePolicy.expiration(
            requestTime: responseTime,
            responseTime: responseTime,
            headers: ["Cache-Control": "max-age=3600, no-cache"]
        )
        XCTAssertEqual(expiration, responseTime)
    }

    func testCacheDecisionTableExhaustsFiniteInteractionDomain_MATH_PT_003() throws {
        let domain = try loadCacheDecisionDomain()
        var executed = 0

        for namespace in domain.factors.namespace {
            for cacheControl in domain.factors.cacheControl {
                for vary in domain.factors.vary {
                    for varySelection in domain.factors.varySelection {
                        executed += 1
                        let headers = cacheDecisionHeaders(
                            cacheControl: cacheControl,
                            vary: vary
                        )
                        let isPrivate = namespace == "private"
                        let selectionAvailable = varySelection == "available"
                        let actual = HTTPCachePolicy.disposition(
                            headers: headers,
                            isPrivateNamespace: isPrivate,
                            varySelectionAvailable: selectionAvailable
                        )
                        XCTAssertEqual(
                            actual,
                            expectedCacheDisposition(
                                cacheControl: cacheControl,
                                vary: vary,
                                selectionAvailable: selectionAvailable,
                                isPrivate: isPrivate
                            ),
                            "组合失败：namespace=\(namespace), cacheControl=\(cacheControl), "
                                + "vary=\(vary), selection=\(varySelection)"
                        )

                        let requiresRevalidation = HTTPCachePolicy.requiresRevalidation(
                            headers: headers
                        )
                        XCTAssertEqual(
                            requiresRevalidation,
                            cacheControl == "no-cache"
                                || cacheControl == "must-revalidate"
                                || cacheControl == "malformed"
                        )
                    }
                }
            }
        }

        XCTAssertEqual(executed, domain.expectedCombinationCount)
    }

    func testVaryStarIsNeverReusable_HTTP_CONF_VARY_001() {
        let disposition = HTTPCachePolicy.disposition(
            headers: ["Cache-Control": "max-age=3600", "Vary": "Accept, *"],
            isPrivateNamespace: false
        )
        XCTAssertEqual(disposition, .noStore)
    }

    private func loadCacheDecisionDomain() throws -> CacheDecisionDomain {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "cache-decision-domain",
                withExtension: "json",
                subdirectory: "Conformance/Mathematics"
            )
        )
        return try JSONDecoder().decode(CacheDecisionDomain.self, from: Data(contentsOf: url))
    }

    private func cacheDecisionHeaders(
        cacheControl: String,
        vary: String
    ) -> [String: String] {
        var headers: [String: String] = [:]
        switch cacheControl {
        case "absent":
            break
        case "max-age":
            headers["Cache-Control"] = "max-age=60"
        case "no-store":
            headers["Cache-Control"] = "no-store, max-age=60"
        case "no-cache":
            headers["Cache-Control"] = "no-cache, max-age=60"
        case "must-revalidate":
            headers["Cache-Control"] = "must-revalidate, max-age=60"
        case "private":
            headers["Cache-Control"] = "private, max-age=60"
        case "duplicate-max-age":
            headers["Cache-Control"] = "max-age=60, max-age=30"
        case "malformed":
            headers["Cache-Control"] = "private=\"unterminated"
        default:
            XCTFail("未识别的 Cache-Control 因子：\(cacheControl)")
        }

        switch vary {
        case "absent":
            break
        case "field":
            headers["Vary"] = "Accept-Language"
        case "wildcard":
            headers["Vary"] = "*"
        case "invalid":
            headers["Vary"] = "bad field"
        default:
            XCTFail("未识别的 Vary 因子：\(vary)")
        }
        return headers
    }

    private func expectedCacheDisposition(
        cacheControl: String,
        vary: String,
        selectionAvailable: Bool,
        isPrivate: Bool
    ) -> CacheDisposition {
        let invalidControl = cacheControl == "duplicate-max-age" || cacheControl == "malformed"
        let forbidsStorage = cacheControl == "no-store"
        let invalidVary = vary == "wildcard" || vary == "invalid"
        if invalidControl || forbidsStorage || invalidVary || !selectionAvailable {
            return .noStore
        }
        return isPrivate ? .privateNamespace : .reusable
    }
}

private struct CacheDecisionDomain: Decodable {
    let schemaVersion: Int
    let factors: Factors
    let expectedCombinationCount: Int

    struct Factors: Decodable {
        let namespace: [String]
        let cacheControl: [String]
        let vary: [String]
        let varySelection: [String]
    }
}
