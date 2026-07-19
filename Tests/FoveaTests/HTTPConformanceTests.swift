import Foundation
import FoveaCore
import FoveaHTTP
import FoveaTesting
import ImageCraftCore
import XCTest

final class HTTPConformanceTests: XCTestCase {
  func testWPTFreshnessMatrix_HTTP_CONF_WPT_FRESHNESS() {
    let requestTime = Date(timeIntervalSince1970: 1_000_000)
    let responseTime = requestTime.addingTimeInterval(1)

    run("future Expires is fresh") {
      let expiration = HTTPCachePolicy.expiration(
        requestTime: requestTime,
        responseTime: responseTime,
        headers: ["Expires": httpDate(responseTime.addingTimeInterval(30 * 24 * 60 * 60))]
      )
      XCTAssertTrue(isFresh(expiration, at: responseTime.addingTimeInterval(2)))
    }
    run("past Expires is stale") {
      let expiration = HTTPCachePolicy.expiration(
        requestTime: requestTime,
        responseTime: responseTime,
        headers: ["Expires": httpDate(responseTime.addingTimeInterval(-30 * 24 * 60 * 60))]
      )
      XCTAssertFalse(isFresh(expiration, at: responseTime))
    }
    run("present Expires is stale") {
      let expiration = HTTPCachePolicy.expiration(
        requestTime: requestTime,
        responseTime: responseTime,
        headers: ["Expires": httpDate(responseTime)]
      )
      XCTAssertFalse(isFresh(expiration, at: responseTime))
    }
    for name in [
      "invalid Expires is stale",
      "invalid Expires plus current Last-Modified is stale",
      "invalid Expires plus past Last-Modified is stale",
    ] {
      run(name) {
        let expiration = HTTPCachePolicy.expiration(
          requestTime: requestTime,
          responseTime: responseTime,
          headers: ["Expires": "0", "Last-Modified": httpDate(requestTime)]
        )
        XCTAssertNil(expiration)
      }
    }
    run("positive max-age is fresh") {
      let expiration = expiration(
        "max-age=3600",
        requestTime: requestTime,
        responseTime: responseTime
      )
      XCTAssertTrue(isFresh(expiration, at: responseTime.addingTimeInterval(3_598)))
      XCTAssertFalse(isFresh(expiration, at: responseTime.addingTimeInterval(3_599)))
    }
    run("max-age zero is stale") {
      let expiration = expiration(
        "max-age=0",
        requestTime: requestTime,
        responseTime: responseTime
      )
      XCTAssertFalse(isFresh(expiration, at: responseTime))
    }
    run("max-age overrides past Expires") {
      let expiration = HTTPCachePolicy.expiration(
        requestTime: requestTime,
        responseTime: responseTime,
        headers: [
          "Cache-Control": "max-age=3600",
          "Expires": httpDate(responseTime.addingTimeInterval(-10_000)),
        ]
      )
      XCTAssertTrue(isFresh(expiration, at: responseTime.addingTimeInterval(100)))
    }
    run("max-age overrides invalid Expires") {
      let expiration = HTTPCachePolicy.expiration(
        requestTime: requestTime,
        responseTime: responseTime,
        headers: ["Cache-Control": "max-age=3600", "Expires": "0"]
      )
      XCTAssertTrue(isFresh(expiration, at: responseTime.addingTimeInterval(100)))
    }
    run("max-age zero overrides future Expires") {
      let expiration = HTTPCachePolicy.expiration(
        requestTime: requestTime,
        responseTime: responseTime,
        headers: [
          "Cache-Control": "max-age=0",
          "Expires": httpDate(responseTime.addingTimeInterval(10_000)),
        ]
      )
      XCTAssertFalse(isFresh(expiration, at: responseTime))
    }
    run("private cache ignores s-maxage") {
      let expiration = expiration(
        "max-age=1, s-maxage=3600",
        requestTime: requestTime,
        responseTime: responseTime
      )
      XCTAssertFalse(isFresh(expiration, at: responseTime.addingTimeInterval(2)))
    }
    run("Age greater than lifetime is stale") {
      let expiration = HTTPCachePolicy.expiration(
        requestTime: requestTime,
        responseTime: responseTime,
        headers: ["Cache-Control": "max-age=3600", "Age": "12000"]
      )
      XCTAssertFalse(isFresh(expiration, at: responseTime))
    }
    run("no-store is not reusable") {
      XCTAssertEqual(
        HTTPCachePolicy.disposition(
          headers: ["Cache-Control": "no-store"],
          isPrivateNamespace: false
        ),
        .noStore
      )
    }
    run("no-store overrides freshness metadata") {
      XCTAssertEqual(
        HTTPCachePolicy.disposition(
          headers: [
            "Cache-Control": "max-age=10000, no-store",
            "Expires": httpDate(responseTime.addingTimeInterval(10_000)),
          ],
          isPrivateNamespace: false
        ),
        .noStore
      )
    }
    for directive in ["no-cache", "max-age=10000, no-cache"] {
      run("\(directive) forces validation") {
        let expiration = expiration(
          directive,
          requestTime: requestTime,
          responseTime: responseTime
        )
        XCTAssertFalse(isFresh(expiration, at: responseTime))
        XCTAssertEqual(
          HTTPCachePolicy.disposition(
            headers: ["Cache-Control": directive],
            isPrivateNamespace: false
          ),
          .reusable
        )
      }
    }
  }

  func testWPTVaryMatrix_HTTP_CONF_WPT_VARY() throws {
    let fooOne = try request(headers: ["Foo": "1"])
    let fooTwo = try request(headers: ["Foo": "2"])
    let noHeaders = try request(headers: [:])
    let fooOneOtherTwo = try request(headers: ["Foo": "1", "Other": "2"])
    let fooOneOtherThree = try request(headers: ["Foo": "1", "Other": "3"])

    let fooRecord = try record(for: fooOne, fields: ["Foo"], contentID: "foo-one")
    run("matching Vary field reuses record") {
      XCTAssertEqual(select([fooRecord], for: fooOne)?.contentID, fooRecord.contentID)
    }
    run("mismatching Vary field misses") {
      XCTAssertNil(select([fooRecord], for: fooTwo))
    }
    run("omitted Vary field misses present field") {
      XCTAssertNil(select([fooRecord], for: noHeaders))
    }
    let fooTwoRecord = try record(for: fooTwo, fields: ["Foo"], contentID: "foo-two")
    run("different Vary records coexist") {
      XCTAssertEqual(
        select([fooRecord, fooTwoRecord], for: fooOne)?.contentID, fooRecord.contentID)
      XCTAssertEqual(
        select([fooRecord, fooTwoRecord], for: fooTwo)?.contentID, fooTwoRecord.contentID)
    }
    let ignoreOtherRecord = try record(
      for: fooOneOtherTwo,
      fields: ["Foo"],
      contentID: "ignore-other"
    )
    run("headers not named by Vary are ignored") {
      XCTAssertEqual(
        select([ignoreOtherRecord], for: fooOneOtherThree)?.contentID, ignoreOtherRecord.contentID)
    }

    let twoWay = try request(headers: ["Foo": "1", "Bar": "abc"])
    let twoWayMismatch = try request(headers: ["Foo": "2", "Bar": "abc"])
    let twoWayRecord = try record(for: twoWay, fields: ["Foo", "Bar"], contentID: "two-way")
    run("two-way Vary matches all fields") {
      XCTAssertEqual(select([twoWayRecord], for: twoWay)?.contentID, twoWayRecord.contentID)
    }
    run("two-way Vary rejects one mismatch") {
      XCTAssertNil(select([twoWayRecord], for: twoWayMismatch))
    }
    run("two-way Vary rejects omitted fields") {
      XCTAssertNil(select([twoWayRecord], for: noHeaders))
    }

    let threeWay = try request(headers: ["Foo": "1", "Bar": "abc", "Baz": "789"])
    let threeWayMismatch = try request(headers: ["Baz": "789", "Bar": "abc4", "Foo": "1"])
    let threeWayRecord = try record(
      for: threeWay,
      fields: ["Foo", "Bar", "Baz"],
      contentID: "three-way"
    )
    run("three-way Vary matches all fields") {
      XCTAssertEqual(select([threeWayRecord], for: threeWay)?.contentID, threeWayRecord.contentID)
    }
    run("three-way Vary rejects mismatch independent of header order") {
      XCTAssertNil(select([threeWayRecord], for: threeWayMismatch))
    }

    let sharedAbsence = try request(headers: ["Foo": "1", "Baz": "789"])
    let sharedAbsenceRecord = try record(
      for: sharedAbsence,
      fields: ["Foo", "Bar", "Baz"],
      contentID: "shared-absence"
    )
    run("shared absence of Vary field matches") {
      XCTAssertEqual(
        select([sharedAbsenceRecord], for: sharedAbsence)?.contentID,
        sharedAbsenceRecord.contentID
      )
    }
    run("Vary wildcard is not reusable") {
      XCTAssertEqual(
        HTTPCachePolicy.varyFieldNames(in: ["Vary": "*"]),
        .wildcard
      )
      XCTAssertEqual(
        HTTPCachePolicy.disposition(
          headers: ["Cache-Control": "max-age=3600", "Vary": "*"],
          isPrivateNamespace: false
        ),
        .noStore
      )
    }
  }

  func testWPT304StoredMetadataMatrix_HTTP_CONF_WPT_304() async throws {
    try await run304Scenario(
      initialHeaders: [
        "Content-Type": "image/png",
        "Cache-Control": "max-age=0",
        "Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT",
      ],
      updateHeaders: [
        "Cache-Control": "max-age=3600",
        "Last-Modified": "Thu, 22 Oct 2015 07:28:00 GMT",
      ]
    ) { record in
      XCTAssertEqual(record.lastModified, "Thu, 22 Oct 2015 07:28:00 GMT")
    }
    try await run304Scenario(
      initialHeaders: [
        "Content-Type": "image/png",
        "Cache-Control": "max-age=0",
        "ETag": "ABC",
      ],
      updateHeaders: ["Cache-Control": "max-age=3600", "ETag": "DEF"]
    ) { record in
      XCTAssertEqual(record.etag, "DEF")
    }
  }

  func testWPTStatus200Profile_HTTP_CONF_WPT_STATUS() async throws {
    let fresh = try await pipelineScenario(
      firstHeaders: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
      stubCount: 1,
      loadCount: 2
    )
    XCTAssertEqual(fresh, 1)

    let stale = try await pipelineScenario(
      firstHeaders: ["Content-Type": "image/png", "Cache-Control": "max-age=0"],
      stubCount: 2,
      loadCount: 2
    )
    XCTAssertEqual(stale, 2)
  }

  private func run304Scenario(
    initialHeaders: [String: String],
    updateHeaders: [String: String],
    verify: (RepresentationRecord) throws -> Void
  ) async throws {
    let body = try makePNG()
    let root = try makeTemporaryDirectory()
    let (pipeline, transport, _, records) = try await makePipeline(
      stubs: [
        .init(statusCode: 200, headers: initialHeaders, body: body),
        .init(statusCode: 304, headers: updateHeaders, body: Data()),
      ],
      root: root
    )
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/wpt-304-\(UUID().uuidString).png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    _ = try await pipeline.image(for: request)
    _ = try await pipeline.image(for: request)
    _ = try await pipeline.image(for: request)

    let candidates = await records.records(
      for: request.fetchBaseKey.digestHex,
      namespace: request.namespace.value,
      namespaceGeneration: 0
    )
    let record = try XCTUnwrap(candidates.first)
    try verify(record)
    XCTAssertTrue(record.isFresh(at: Date()))
    let requestCount = await transport.capturedRequests().count
    XCTAssertEqual(requestCount, 2)
  }

  private func pipelineScenario(
    firstHeaders: [String: String],
    stubCount: Int,
    loadCount: Int
  ) async throws -> Int {
    let body = try makePNG()
    let stubs = (0..<stubCount).map { _ in
      FakeHTTPTransport.Stub(statusCode: 200, headers: firstHeaders, body: body)
    }
    let (pipeline, transport, _, _) = try await makePipeline(stubs: stubs)
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/wpt-status-\(UUID().uuidString).png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    for _ in 0..<loadCount { _ = try await pipeline.image(for: request) }
    return await transport.capturedRequests().count
  }

  private func request(headers: [String: String]) throws -> ImageRequest {
    try ImageRequest(
      url: XCTUnwrap(URL(string: "https://example.test/wpt-vary.png")),
      target: TargetPixels(width: 20, height: 20),
      namespace: .publicNamespace(appID: "tests"),
      headers: headers
    )
  }

  private func record(
    for request: ImageRequest,
    fields: [String],
    contentID: String
  ) throws -> RepresentationRecord {
    let selection = try XCTUnwrap(request.varySelection(fieldNames: fields))
    let variant = request.fetchVariantKey(for: selection)
    return makeRepresentationRecord(
      namespace: request.namespace.value,
      baseKeyDigest: request.fetchBaseKey.digestHex,
      variantKeyDigest: variant.digestHex,
      vary: selection,
      responseDate: Date(),
      expiresAt: Date.distantFuture,
      contentID: contentID
    )
  }

  private func select(
    _ candidates: [RepresentationRecord],
    for request: ImageRequest
  ) -> RepresentationRecord? {
    HTTPCachePolicy.selectRecord(
      from: candidates,
      requestHeaders: request.headers,
      additionalSensitiveNames: request.credentialHeaderNames,
      sensitiveFingerprints: request.headerVariantFingerprints
    )
  }

  private func expiration(
    _ cacheControl: String,
    requestTime: Date,
    responseTime: Date
  ) -> Date? {
    HTTPCachePolicy.expiration(
      requestTime: requestTime,
      responseTime: responseTime,
      headers: ["Cache-Control": cacheControl]
    )
  }

  private func isFresh(_ expiration: Date?, at date: Date) -> Bool {
    expiration.map { date < $0 } ?? false
  }

  private func httpDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    return formatter.string(from: date)
  }

  private func run(_ name: String, _ body: () throws -> Void) {
    do {
      try body()
    } catch {
      XCTFail("\(name): \(error)")
    }
  }
}
