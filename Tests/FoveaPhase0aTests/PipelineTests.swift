import AkashicDisk
import FoveaCore
import FoveaHTTP
import FoveaTesting
import ImageCraftCore
import XCTest

final class PipelineTests: XCTestCase {
  func testCredentialHeaderWithoutContextFailsBeforeNetwork_AUTH_PT_006() async throws {
    let body = try makePNG()
    let (pipeline, transport, _, _) = try makePipeline(stubs: [
      .init(statusCode: 200, headers: ["Content-Type": "image/png"], body: body)
    ])
    let request = ImageRequest(
      url: try XCTUnwrap(URL(string: "https://example.com/credential.png")),
      target: try TargetPixels(width: 20, height: 20),
      namespace: SecurityNamespaceID.publicNamespace(appID: "tests"),
      headers: ["Authorization": "Bearer secret"]
    )
    do {
      _ = try await pipeline.image(for: request)
      XCTFail("Expected fail-closed authorization error")
    } catch let error as FoveaError {
      XCTAssertEqual(error, .missingAuthorizationContext)
    }
    let requestCount = await transport.capturedRequests().count
    XCTAssertEqual(requestCount, 0)
  }

  func testCorruptFreshBlobFallsBackToNetwork() async throws {
    let root = try makeTemporaryDirectory()
    let firstBody = try makePNG(red: 200)
    let replacementBody = try makePNG(red: 10)
    let (pipeline, transport, encoded, records) = try makePipeline(
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
    let request = ImageRequest.publicImage(
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

  func test304WithMissingBodyRetriesUnconditionalGET() async throws {
    let root = try makeTemporaryDirectory()
    let firstBody = try makePNG(red: 150)
    let replacementBody = try makePNG(red: 20)
    let (pipeline, transport, encoded, records) = try makePipeline(
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
    let request = ImageRequest.publicImage(
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
    let (pipeline, transport, _, _) = try makePipeline(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
        body: body,
        delayNanoseconds: 100_000_000
      )
    ])
    let url = try XCTUnwrap(URL(string: "https://example.com/shared-cancel.png"))
    let firstRequest = ImageRequest.publicImage(
      url: url,
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    let secondRequest = ImageRequest.publicImage(
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
    } catch is CancellationError {
      // Expected.
    }

    let final = try await survivor.value
    XCTAssertEqual(final.pixelWidth, 80)
    XCTAssertEqual(final.pixelHeight, 40)
    let requestCount = await transport.capturedRequests().count
    XCTAssertEqual(requestCount, 1)
  }

  func testDifferentTargetsShareFetchButDecodeIndependently() async throws {
    let body = try makePNG(width: 100, height: 50)
    let (pipeline, transport, _, _) = try makePipeline(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
        body: body,
        delayNanoseconds: 100_000_000
      )
    ])
    let url = try XCTUnwrap(URL(string: "https://example.com/shared-fetch.png"))
    let small = ImageRequest.publicImage(
      url: url,
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    let large = ImageRequest.publicImage(
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

  func testFreshRecordAvoidsNetwork_CACHE_PT_006() async throws {
    let body = try makePNG()
    let (pipeline, transport, _, _) = try makePipeline(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
        body: body
      )
    ])
    let request = ImageRequest.publicImage(
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
    let (pipeline, transport, _, records) = try makePipeline(stubs: [
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
    let request = ImageRequest.publicImage(
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

  func testNoStoreNeverSatisfiesNewRequest_CACHE_PT_026() async throws {
    let body = try makePNG()
    let (pipeline, transport, _, records) = try makePipeline(stubs: [
      .init(
        statusCode: 200, headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
        body: body),
      .init(
        statusCode: 200, headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
        body: body),
    ])
    let request = ImageRequest.publicImage(
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
    let (pipeline, _, _, records) = try makePipeline(
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
    let request = ImageRequest(
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
    } catch let error as FoveaError {
      XCTAssertEqual(error, .namespaceRevoked)
    }
    let storedRecord = await records.record(for: variantKey(for: request).digestHex)
    XCTAssertNil(storedRecord)
  }

  func testProbeFailureDoesNotPublishRecord_CACHE_PT_029_AIQA_MUT_015() async throws {
    let (pipeline, _, _, records) = try makePipeline(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
        body: Data("broken".utf8)
      )
    ])
    let request = ImageRequest.publicImage(
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
    // Expected.
  }
}
