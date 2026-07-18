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
    XCTAssertEqual(try XCTUnwrap(expiration).timeIntervalSince(responseTime), 8, accuracy: 0.001)
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
    XCTAssertEqual(try XCTUnwrap(expiration).timeIntervalSince(responseTime), 10, accuracy: 0.001)
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

  func testVaryStarIsNeverReusable_HTTP_CONF_VARY_001() {
    let disposition = HTTPCachePolicy.disposition(
      headers: ["Cache-Control": "max-age=3600", "Vary": "Accept, *"],
      isPrivateNamespace: false
    )
    XCTAssertEqual(disposition, .noStore)
  }

}
