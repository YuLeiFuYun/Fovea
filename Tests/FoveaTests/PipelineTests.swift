import AkashicDisk
import FoveaCore
import FoveaHTTP
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class PipelineTests: XCTestCase {
  func testTransformFailureRetainsOriginalAndPublishesNoRendered_CACHE_PT_030() async throws {
    let root = try makeTemporaryDirectory()
    let body = try makePNG()
    let transport = FakeHTTPTransport(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
        body: body
      )
    ])
    let encoded = try await OriginalEncodedStore.open(root: root.appendingPathComponent("encoded"))
    let records = try await RepresentationRecordStore.open(
      root: root.appendingPathComponent("records")
    )
    let transformer = FailingImageTransformer()
    let pipeline = FoveaPipeline(
      transport: transport,
      encodedStore: encoded,
      recordStore: records,
      decoder: ImageIOImageDecoder(),
      transformer: transformer
    )
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/transform-failure.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    for _ in 0..<2 {
      do {
        _ = try await pipeline.image(for: request)
        XCTFail("失败的 transform 不得交付 final")
      } catch let failure as PipelineFailure {
        XCTAssertEqual(failure.category, .transform)
        XCTAssertEqual(failure.stage, .transform)
        XCTAssertEqual(failure.reasonCode, "transform-failed")
      }
    }

    let storedRecords = await records.records(
      for: request.fetchBaseKey.digestHex,
      namespace: request.namespace.value,
      namespaceGeneration: 0
    )
    let physicalID = await encoded.physicalID(
      contentID: ContentID(data: body).description,
      namespace: request.namespace.value
    )
    let requestCount = await transport.capturedRequests().count
    let transformCount = await transformer.transformCount
    XCTAssertEqual(storedRecords.count, 1)
    XCTAssertNotNil(physicalID)
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(transformCount, 2)
  }

  func testEncodedDataRequestDoesNotProbeDecodeOrPersist_GEO_PT_008() async throws {
    let root = try makeTemporaryDirectory()
    let body = try makePNG()
    let transport = FakeHTTPTransport(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
        body: body
      )
    ])
    let encoded = try await OriginalEncodedStore.open(root: root.appendingPathComponent("encoded"))
    let records = try await RepresentationRecordStore.open(
      root: root.appendingPathComponent("records")
    )
    let pipeline = FoveaPipeline(
      transport: transport,
      encodedStore: encoded,
      recordStore: records,
      decoder: RejectingDecoder()
    )
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/encoded-data.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    let received = try await pipeline.encodedData(for: request)

    let requestCount = await transport.capturedRequests().count
    let storedRecords = await records.records(
      for: request.fetchBaseKey.digestHex,
      namespace: request.namespace.value,
      namespaceGeneration: 0
    )
    let storedBlob = await encoded.physicalID(
      contentID: ContentID(data: body).description,
      namespace: request.namespace.value
    )
    XCTAssertEqual(received, body)
    XCTAssertEqual(requestCount, 1)
    XCTAssertTrue(storedRecords.isEmpty)
    XCTAssertNil(storedBlob)
  }

  func testOnlyIfCachedMissIsExplicitAndNeverStartsNetwork_ERR_PT_002() async throws {
    let body = try makePNG()
    let (pipeline, transport, _, _) = try await makePipeline(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
        body: body
      )
    ])
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/only-if-cached.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests",
      cachePolicy: .onlyIfCached
    )

    do {
      _ = try await pipeline.image(for: request)
      XCTFail("onlyIfCached 未命中必须返回明确失败")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .cacheRead)
      XCTAssertEqual(failure.stage, .cacheLookup)
      XCTAssertEqual(failure.disposition, .terminal)
      XCTAssertEqual(failure.reasonCode, "only-if-cached-miss")
    }

    let requestCount = await transport.capturedRequests().count
    XCTAssertEqual(requestCount, 0)
  }

  func testTaskLocalTransportBypassesCacheAndCrossRequestSingleFlight_AUTH_PT_008() async throws {
    let root = try makeTemporaryDirectory()
    let body = try makePNG()
    let transport = FakeHTTPTransport(
      stubs: [
        .init(
          statusCode: 200,
          headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
          body: body,
          delayNanoseconds: 30_000_000
        ),
        .init(
          statusCode: 200,
          headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
          body: body,
          delayNanoseconds: 30_000_000
        ),
        .init(
          statusCode: 200,
          headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
          body: body
        ),
      ],
      reusePolicy: .taskLocal
    )
    let encoded = try await OriginalEncodedStore.open(root: root.appendingPathComponent("encoded"))
    let records = try await RepresentationRecordStore.open(
      root: root.appendingPathComponent("records")
    )
    let pipeline = FoveaPipeline(
      transport: transport,
      encodedStore: encoded,
      recordStore: records,
      decoder: ImageIOImageDecoder()
    )
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/opaque-session.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    async let first = pipeline.image(for: request)
    async let second = pipeline.image(for: request)
    _ = try await (first, second)
    _ = try await pipeline.image(for: request)

    let requestCount = await transport.capturedRequests().count
    let storedRecords = await records.records(
      for: request.fetchBaseKey.digestHex,
      namespace: request.namespace.value,
      namespaceGeneration: 0
    )
    let storedBlob = await encoded.physicalID(
      contentID: ContentID(data: body).description,
      namespace: request.namespace.value
    )
    XCTAssertEqual(requestCount, 3)
    XCTAssertTrue(storedRecords.isEmpty)
    XCTAssertNil(storedBlob)
  }

  func testCredentialHeaderWithoutContextFailsBeforeNetwork_AUTH_PT_006() async throws {
    let body = try makePNG()
    let (pipeline, transport, _, _) = try await makePipeline(stubs: [
      .init(statusCode: 200, headers: ["Content-Type": "image/png"], body: body)
    ])
    let request = try ImageRequest(
      url: try XCTUnwrap(URL(string: "https://example.com/credential.png")),
      target: try TargetPixels(width: 20, height: 20),
      namespace: SecurityNamespaceID.publicNamespace(appID: "tests"),
      headers: ["Authorization": "Bearer secret"]
    )
    do {
      _ = try await pipeline.image(for: request)
      XCTFail("Expected fail-closed authorization error")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .authorization)
      XCTAssertEqual(failure.stage, .requestValidation)
      XCTAssertEqual(failure.disposition, .terminal)
      XCTAssertEqual(failure.reasonCode, "missing-authorization-context")
    }
    let requestCount = await transport.capturedRequests().count
    XCTAssertEqual(requestCount, 0)
  }

  func testInjectedClockControlsFreshnessWithoutSleeping() async throws {
    let root = try makeTemporaryDirectory()
    let body = try makePNG()
    let encoded = try await OriginalEncodedStore.open(root: root.appendingPathComponent("encoded"))
    let records = try await RepresentationRecordStore.open(
      root: root.appendingPathComponent("records"))
    let transport = FakeHTTPTransport(stubs: [])
    let now = Date(timeIntervalSince1970: 20_000)
    let clock = TestWallClock(now)
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.com/clock.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    let contentID = ContentID(data: body)
    _ = try await encoded.commit(
      data: body,
      contentID: contentID.description,
      namespace: request.namespace.value
    )
    try await records.put(
      makeRepresentationRecord(
        namespace: request.namespace.value,
        baseKeyDigest: request.fetchBaseKey.digestHex,
        variantKeyDigest: request.fetchVariantKey.digestHex,
        requestTime: now,
        responseTime: now,
        responseDate: now,
        expiresAt: now.addingTimeInterval(10),
        contentID: contentID.description,
        payloadLength: body.count
      )
    )
    let pipeline = FoveaPipeline(
      configuration: PipelineConfiguration(
        transportRetryPolicy: TransportRetryPolicy(maximumAttempts: 1)
      ),
      transport: transport,
      encodedStore: encoded,
      recordStore: records,
      namespaceRegistry: NamespaceRegistry(),
      decoder: ImageIOImageDecoder(),
      clock: clock
    )

    _ = try await pipeline.image(for: request)
    let freshRequestCount = await transport.capturedRequests().count
    XCTAssertEqual(freshRequestCount, 0)

    await clock.set(now.addingTimeInterval(11))
    await assertThrowsErrorAsync { try await pipeline.image(for: request) }
    let staleRequestCount = await transport.capturedRequests().count
    XCTAssertEqual(staleRequestCount, 1)
  }

  func testCachedDecodeFailureDoesNotDeleteRecordOrRetryNetwork() async throws {
    let root = try makeTemporaryDirectory()
    let body = try makePNG()
    let encoded = try await OriginalEncodedStore.open(root: root.appendingPathComponent("encoded"))
    let records = try await RepresentationRecordStore.open(
      root: root.appendingPathComponent("records"))
    let transport = FakeHTTPTransport(stubs: [])
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.com/cached-decode-failure.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    let contentID = ContentID(data: body)
    _ = try await encoded.commit(
      data: body,
      contentID: contentID.description,
      namespace: request.namespace.value
    )
    let record = makeRepresentationRecord(
      namespace: request.namespace.value,
      baseKeyDigest: request.fetchBaseKey.digestHex,
      variantKeyDigest: request.fetchVariantKey.digestHex,
      expiresAt: Date().addingTimeInterval(3600),
      contentID: contentID.description,
      payloadLength: body.count
    )
    try await records.put(record)
    let pipeline = FoveaPipeline(
      transport: transport,
      encodedStore: encoded,
      recordStore: records,
      decoder: AlwaysFailingDecoder()
    )

    await assertThrowsErrorAsync { try await pipeline.image(for: request) }

    let capturedRequestCount = await transport.capturedRequests().count
    let preservedRecord = await records.records(
      for: request.fetchBaseKey.digestHex,
      namespace: request.namespace.value,
      namespaceGeneration: 0
    ).first
    XCTAssertEqual(capturedRequestCount, 0)
    XCTAssertNotNil(preservedRecord)
  }

  func testCancellationDuringDecodeDoesNotCommitCache() async throws {
    let root = try makeTemporaryDirectory()
    let body = try makePNG()
    let encoded = try await OriginalEncodedStore.open(root: root.appendingPathComponent("encoded"))
    let records = try await RepresentationRecordStore.open(
      root: root.appendingPathComponent("records"))
    let transport = FakeHTTPTransport(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
        body: body
      )
    ])
    let request = try ImageRequest.publicImage(
      url: XCTUnwrap(URL(string: "https://example.com/cancel-decode.png")),
      target: TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    let pipeline = FoveaPipeline(
      transport: transport,
      encodedStore: encoded,
      recordStore: records,
      decoder: SlowDecoder(delay: 0.15)
    )

    let task = Task { try await pipeline.image(for: request) }
    try await Task.sleep(for: .milliseconds(25))
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancelled decode must not deliver or commit")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .cancelled)
      XCTAssertEqual(failure.disposition, .cancelled)
      XCTAssertTrue([.decode, .pipeline].contains(failure.stage))
    }

    let record = await records.records(
      for: request.fetchBaseKey.digestHex,
      namespace: request.namespace.value,
      namespaceGeneration: 0
    ).first
    XCTAssertNil(record)
    let physicalID = await encoded.physicalID(
      contentID: ContentID(data: body).description,
      namespace: request.namespace.value
    )
    XCTAssertNil(physicalID)
  }

  func testCorruptFreshBlobFallsBackToNetwork() async throws {
    let root = try makeTemporaryDirectory()
    let firstBody = try makePNG(red: 200)
    let replacementBody = try makePNG(red: 10)
    let (pipeline, transport, encoded, records) = try await makePipeline(
      stubs: [
        .init(
          statusCode: 200,
          headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
          body: firstBody
        ),
        .init(
          statusCode: 200,
          headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
          body: replacementBody
        ),
      ],
      root: root
    )
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.com/corrupt-fresh.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    _ = try await pipeline.image(for: request)
    let recordValue = await records.record(for: variantKey(for: request).digestHex)
    let record = try XCTUnwrap(recordValue)
    let physicalIDValue = await encoded.physicalID(
      contentID: record.contentID, namespace: request.namespace.value)
    let physicalID = try XCTUnwrap(physicalIDValue)
    let blobURL = root.appendingPathComponent("encoded/blobs/\(physicalID.description)")
    try Data("corrupt".utf8).write(to: blobURL, options: [.atomic])

    _ = try await pipeline.image(for: request)
    let requestCount = await transport.capturedRequests().count
    XCTAssertEqual(requestCount, 2)
  }

  func test304NoStoreRevokesExistingReusableState() async throws {
    let body = try makePNG()
    let (pipeline, transport, encoded, records) = try await makePipeline(stubs: [
      .init(
        statusCode: 200,
        headers: [
          "Content-Type": "image/png",
          "Cache-Control": "max-age=0",
          "ETag": "v1",
        ],
        body: body
      ),
      .init(
        statusCode: 304,
        headers: ["Cache-Control": "no-store", "ETag": "v1"],
        body: Data()
      ),
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
        body: body
      ),
    ])
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.com/304-no-store.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    _ = try await pipeline.image(for: request)
    let contentID = ContentID(data: body).description
    let initialRecord = await records.record(for: request.fetchVariantKey.digestHex)
    let initialBlob = await encoded.physicalID(
      contentID: contentID,
      namespace: request.namespace.value
    )
    XCTAssertNotNil(initialRecord)
    XCTAssertNotNil(initialBlob)

    _ = try await pipeline.image(for: request)
    let revokedRecord = await records.record(for: request.fetchVariantKey.digestHex)
    let revokedBlob = await encoded.physicalID(
      contentID: contentID,
      namespace: request.namespace.value
    )
    XCTAssertNil(revokedRecord)
    XCTAssertNil(revokedBlob)

    _ = try await pipeline.image(for: request)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.count, 3)
  }

  func test304WithMissingBodyRetriesUnconditionalGET() async throws {
    let root = try makeTemporaryDirectory()
    let firstBody = try makePNG(red: 150)
    let replacementBody = try makePNG(red: 20)
    let (pipeline, transport, encoded, records) = try await makePipeline(
      stubs: [
        .init(
          statusCode: 200,
          headers: ["Content-Type": "image/png", "Cache-Control": "max-age=0", "ETag": "\"v1\""],
          body: firstBody
        ),
        .init(statusCode: 304, headers: ["Cache-Control": "max-age=3600", "ETag": "\"v1\""]),
        .init(
          statusCode: 200,
          headers: [
            "Content-Type": "image/png", "Cache-Control": "max-age=3600", "ETag": "\"v2\"",
          ],
          body: replacementBody
        ),
      ],
      root: root
    )
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.com/missing-body.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    _ = try await pipeline.image(for: request)
    let recordValue = await records.record(for: variantKey(for: request).digestHex)
    let record = try XCTUnwrap(recordValue)
    let physicalIDValue = await encoded.physicalID(
      contentID: record.contentID, namespace: request.namespace.value)
    let physicalID = try XCTUnwrap(physicalIDValue)
    try FileManager.default.removeItem(
      at: root.appendingPathComponent("encoded/blobs/\(physicalID.description)"))

    _ = try await pipeline.image(for: request)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.count, 3)
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
    XCTAssertNil(requests[2].value(forHTTPHeaderField: "If-None-Match"))
  }

  func testCancellingOneSubscriberDoesNotCancelSharedFetch() async throws {
    let body = try makePNG(width: 100, height: 50)
    let (pipeline, transport, _, _) = try await makePipeline(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
        body: body,
        delayNanoseconds: 100_000_000
      )
    ])
    let url = try XCTUnwrap(URL(string: "https://example.com/shared-cancel.png"))
    let firstRequest = try ImageRequest.publicImage(
      url: url,
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    let secondRequest = try ImageRequest.publicImage(
      url: url,
      target: try TargetPixels(width: 80, height: 80),
      appID: "tests"
    )

    let cancelled = Task { try await pipeline.image(for: firstRequest) }
    let survivor = Task { try await pipeline.image(for: secondRequest) }
    try await Task.sleep(for: .milliseconds(20))
    cancelled.cancel()

    do {
      _ = try await cancelled.value
      XCTFail("Cancelled subscriber must not receive a final image")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .cancelled)
      XCTAssertEqual(failure.stage, .transport)
      XCTAssertEqual(failure.disposition, .cancelled)
    }

    let final = try await survivor.value
    XCTAssertEqual(final.pixelWidth, 80)
    XCTAssertEqual(final.pixelHeight, 40)
    let requestCount = await transport.capturedRequests().count
    XCTAssertEqual(requestCount, 1)
  }

  func testCustomCredentialHeaderWithoutContextFailsBeforeNetwork_AUTH_PT_012() async throws {
    let (pipeline, transport, _, _) = try await makePipeline(stubs: [])
    let request = try ImageRequest(
      url: try XCTUnwrap(URL(string: "https://example.com/custom-private.png")),
      target: try TargetPixels(width: 20, height: 20),
      namespace: .publicNamespace(appID: "tests"),
      headers: ["X-Tenant-Credential": "secret"],
      credentialHeaderNames: ["X-Tenant-Credential"]
    )

    do {
      _ = try await pipeline.image(for: request)
      XCTFail("Custom credential-bearing request must fail closed")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .authorization)
      XCTAssertEqual(failure.stage, .requestValidation)
    }
    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testDifferentTargetsShareFetchButDecodeIndependently() async throws {
    let body = try makePNG(width: 100, height: 50)
    let (pipeline, transport, _, _) = try await makePipeline(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
        body: body,
        delayNanoseconds: 100_000_000
      )
    ])
    let url = try XCTUnwrap(URL(string: "https://example.com/shared-fetch.png"))
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

    async let smallImage = pipeline.image(for: small)
    async let largeImage = pipeline.image(for: large)
    let images = try await (smallImage, largeImage)

    XCTAssertEqual(images.0.pixelWidth, 20)
    XCTAssertEqual(images.0.pixelHeight, 10)
    XCTAssertEqual(images.1.pixelWidth, 80)
    XCTAssertEqual(images.1.pixelHeight, 40)
    let requestCount = await transport.capturedRequests().count
    XCTAssertEqual(requestCount, 1)
  }

  func testFreshRecordSurvivesSignedLocatorRefresh_CACHE_PT_014() async throws {
    let body = try makePNG()
    let (pipeline, transport, _, _) = try await makePipeline(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
        body: body
      )
    ])
    let logicalSource = LogicalSourceID("asset:private-avatar:42")
    let first = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://cdn.example.com/avatar.png?sig=old&exp=1")),
      logicalSource: logicalSource,
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    let refreshed = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://cdn.example.com/avatar.png?sig=new&exp=2")),
      logicalSource: logicalSource,
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    _ = try await pipeline.image(for: first)
    _ = try await pipeline.image(for: refreshed)

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests[0].url, first.url)
  }

  func testFreshRecordAvoidsNetwork_CACHE_PT_006() async throws {
    let body = try makePNG()
    let (pipeline, transport, _, _) = try await makePipeline(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
        body: body
      )
    ])
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.com/fresh.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    _ = try await pipeline.image(for: request)
    _ = try await pipeline.image(for: request)
    let requestCount = await transport.capturedRequests().count
    XCTAssertEqual(requestCount, 1)
  }

  func test304ReusesContentID_CACHE_PT_008() async throws {
    let body = try makePNG()
    let (pipeline, transport, _, records) = try await makePipeline(stubs: [
      .init(
        statusCode: 200,
        headers: [
          "Content-Type": "image/png",
          "Cache-Control": "max-age=0",
          "ETag": "\"v1\"",
        ],
        body: body
      ),
      .init(statusCode: 304, headers: ["Cache-Control": "max-age=3600", "ETag": "\"v1\""]),
    ])
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.com/revalidate.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    _ = try await pipeline.image(for: request)
    let digest = variantKey(for: request).digestHex
    let beforeRecord = await records.record(for: digest)
    let before = try XCTUnwrap(beforeRecord)
    _ = try await pipeline.image(for: request)
    let afterRecord = await records.record(for: digest)
    let after = try XCTUnwrap(afterRecord)
    XCTAssertEqual(before.contentID, after.contentID)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
  }

  func testVaryStarNeverSatisfiesNewRequest() async throws {
    let body = try makePNG()
    let (pipeline, transport, _, records) = try await makePipeline(stubs: [
      .init(
        statusCode: 200,
        headers: [
          "Content-Type": "image/png",
          "Cache-Control": "max-age=3600",
          "Vary": "*",
        ],
        body: body
      ),
      .init(
        statusCode: 200,
        headers: [
          "Content-Type": "image/png",
          "Cache-Control": "max-age=3600",
          "Vary": "*",
        ],
        body: body
      ),
    ])
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.com/vary-star.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    _ = try await pipeline.image(for: request)
    _ = try await pipeline.image(for: request)

    let requestCount = await transport.capturedRequests().count
    let record = await records.record(for: request.fetchVariantKey.digestHex)
    XCTAssertEqual(requestCount, 2)
    XCTAssertNil(record)
  }

  func testNoStoreNeverSatisfiesNewRequest_CACHE_PT_026() async throws {
    let body = try makePNG()
    let (pipeline, transport, _, records) = try await makePipeline(stubs: [
      .init(
        statusCode: 200, headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
        body: body),
      .init(
        statusCode: 200, headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
        body: body),
    ])
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.com/no-store.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    _ = try await pipeline.image(for: request)
    _ = try await pipeline.image(for: request)
    let requestCount = await transport.capturedRequests().count
    XCTAssertEqual(requestCount, 2)
    let storedRecord = await records.record(for: variantKey(for: request).digestHex)
    XCTAssertNil(storedRecord)
  }

  func testRevokedGenerationCannotCommit_CACHE_PT_015_AIQA_MUT_008() async throws {
    let body = try makePNG()
    let registry = NamespaceRegistry()
    let (pipeline, _, _, records) = try await makePipeline(
      stubs: [
        .init(
          statusCode: 200,
          headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
          body: body,
          delayNanoseconds: 100_000_000
        )
      ],
      namespaceRegistry: registry
    )
    let namespace = SecurityNamespaceID("account-a")
    let request = try ImageRequest(
      url: try XCTUnwrap(URL(string: "https://example.com/private.png")),
      target: try TargetPixels(width: 20, height: 20),
      namespace: namespace,
      authorizationContext: AuthorizationContextID("principal-a")
    )
    let task = Task { try await pipeline.image(for: request) }
    try await Task.sleep(for: .milliseconds(20))
    try await pipeline.revoke(namespace: namespace)
    do {
      _ = try await task.value
      XCTFail("Expected namespace revocation")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .namespaceRevoked)
      XCTAssertEqual(failure.disposition, .terminal)
    }
    let storedRecord = await records.record(for: variantKey(for: request).digestHex)
    XCTAssertNil(storedRecord)
  }

  func testRevokeThenNewResponsePersistsCurrentGenerationAndHitsDisk_CACHE_PT_038() async throws {
    let body = try makePNG()
    let registry = NamespaceRegistry()
    let root = try makeTemporaryDirectory()
    let transport = FakeHTTPTransport(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
        body: body
      )
    ])
    let encoded = try await OriginalEncodedStore.open(root: root.appendingPathComponent("encoded"))
    let records = try await RepresentationRecordStore.open(
      root: root.appendingPathComponent("records"))
    let namespace = SecurityNamespaceID("account-relogin")
    let request = try ImageRequest(
      url: try XCTUnwrap(URL(string: "https://example.com/relogin.png")),
      target: try TargetPixels(width: 20, height: 20),
      namespace: namespace,
      authorizationContext: AuthorizationContextID("principal-relogin")
    )
    let firstPipeline = FoveaPipeline(
      transport: transport,
      encodedStore: encoded,
      recordStore: records,
      namespaceRegistry: registry,
      decoder: ImageIOImageDecoder()
    )

    try await firstPipeline.revoke(namespace: namespace)
    _ = try await firstPipeline.image(for: request)

    let storedValue = await records.record(for: request.fetchVariantKey.digestHex)
    let stored = try XCTUnwrap(storedValue)
    XCTAssertEqual(stored.namespaceGeneration, 1)

    let coldMemoryPipeline = FoveaPipeline(
      transport: transport,
      encodedStore: encoded,
      recordStore: records,
      namespaceRegistry: registry,
      decoder: ImageIOImageDecoder()
    )
    _ = try await coldMemoryPipeline.image(for: request)

    let requestCount = await transport.capturedRequests().count
    XCTAssertEqual(requestCount, 1)
  }

  func testProbeFailureDoesNotPublishRecord_CACHE_PT_029_AIQA_MUT_015() async throws {
    let (pipeline, _, _, records) = try await makePipeline(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
        body: Data("broken".utf8)
      )
    ])
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.com/broken.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    await assertThrowsErrorAsync { try await pipeline.image(for: request) }
    let storedRecord = await records.record(for: variantKey(for: request).digestHex)
    XCTAssertNil(storedRecord)
  }
}

func assertThrowsErrorAsync<T>(
  _ expression: @escaping () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected error", file: file, line: line)
  } catch {
    // 预期会进入错误分支。
  }
}

private actor FailingImageTransformer: ImageTransforming {
  nonisolated let fingerprint = "tests-failing-transform-v1"
  private(set) var transformCount = 0

  func transform(_ image: DecodedImage) async throws -> DecodedImage {
    transformCount += 1
    throw TransformFixtureError.failed
  }
}

private enum TransformFixtureError: Error {
  case failed
}

private struct RejectingDecoder: ImageDecoding {
  func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
    throw ImageCraftError.decodeFailed
  }

  func decode(
    data: Data,
    probe: ImageProbe,
    request: ImageDecodeRequest,
    limits: DecodeLimits
  ) throws -> DecodedImage {
    throw ImageCraftError.decodeFailed
  }
}

private struct AlwaysFailingDecoder: ImageDecoding {
  func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
    ImageProbe(pixelWidth: 100, pixelHeight: 50, frameCount: 1)
  }

  func decode(
    data: Data,
    probe: ImageProbe,
    request: ImageDecodeRequest,
    limits: DecodeLimits
  ) throws -> DecodedImage {
    throw ImageCraftError.decodeFailed
  }
}

private actor TestWallClock: WallClock {
  private var value: Date

  init(_ value: Date) {
    self.value = value
  }

  func now() -> Date { value }

  func set(_ value: Date) {
    self.value = value
  }
}

private struct SlowDecoder: ImageDecoding {
  let delay: TimeInterval

  func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
    ImageProbe(pixelWidth: 100, pixelHeight: 50, frameCount: 1)
  }

  func decode(
    data: Data,
    probe: ImageProbe,
    request: ImageDecodeRequest,
    limits: DecodeLimits
  ) throws -> DecodedImage {
    Thread.sleep(forTimeInterval: delay)
    return try ImageIOImageDecoder().decode(data: data, request: request, limits: limits)
  }
}
