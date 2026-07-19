import AkashicDisk
import CryptoKit
import Foundation
import FoveaCore
import FoveaHTTP
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class ResourceLimitTests: XCTestCase {
  func testFetchConcurrencyNeverExceedsStaticLimit_RES_PT_001() async throws {
    let body = try makePNG()
    let transport = TrackingTransport(body: body, delay: .milliseconds(80))
    let root = try makeTemporaryDirectory()
    let pipeline = FoveaPipeline(
      configuration: PipelineConfiguration(
        maximumConcurrentFetches: 2,
        maximumConcurrentDecodes: 8
      ),
      transport: transport,
      encodedStore: try await OriginalEncodedStore.open(
        root: root.appendingPathComponent("encoded")),
      recordStore: try await RepresentationRecordStore.open(
        root: root.appendingPathComponent("records")),
      decoder: ImageIOImageDecoder()
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<8 {
        group.addTask {
          let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/fetch-\(index).png")),
            target: try TargetPixels(width: 20 + index, height: 20 + index),
            appID: "tests"
          )
          _ = try await pipeline.image(for: request)
        }
      }
      try await group.waitForAll()
    }

    let maximum = await transport.maximumConcurrentRequests
    XCTAssertEqual(maximum, 2)
  }

  func testCancelledPermitWaiterDoesNotLeakOrStartNetwork_RES_PT_002() async throws {
    let body = try makePNG()
    let transport = TrackingTransport(body: body, delay: .milliseconds(120))
    let root = try makeTemporaryDirectory()
    let pipeline = FoveaPipeline(
      configuration: PipelineConfiguration(
        maximumConcurrentFetches: 1,
        maximumConcurrentDecodes: 2
      ),
      transport: transport,
      encodedStore: try await OriginalEncodedStore.open(
        root: root.appendingPathComponent("encoded")),
      recordStore: try await RepresentationRecordStore.open(
        root: root.appendingPathComponent("records")),
      decoder: ImageIOImageDecoder()
    )

    let firstRequest = try makeRequest(path: "first")
    let cancelledRequest = try makeRequest(path: "cancelled")
    let afterCancelRequest = try makeRequest(path: "after-cancel")
    let first = Task {
      try await pipeline.image(for: firstRequest)
    }
    try await Task.sleep(for: .milliseconds(20))
    let cancelled = Task {
      try await pipeline.image(for: cancelledRequest)
    }
    try await Task.sleep(for: .milliseconds(20))
    cancelled.cancel()

    do {
      _ = try await cancelled.value
      XCTFail("Cancelled permit waiter must not continue")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .cancelled)
      XCTAssertEqual(failure.disposition, .cancelled)
    }

    _ = try await first.value
    _ = try await pipeline.image(for: afterCancelRequest)

    let requestCount = await transport.requestCount
    let maximum = await transport.maximumConcurrentRequests
    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(maximum, 1)
  }

  func testFetchPermitWaitDoesNotInflateHTTPResponseDelay_HTTP_CONF_AGE_004() async throws {
    let body = try makePNG()
    let transport = TrackingTransport(
      body: body,
      delay: .milliseconds(80),
      headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
    )
    let root = try makeTemporaryDirectory()
    let records = try await RepresentationRecordStore.open(
      root: root.appendingPathComponent("records"))
    let clock = SequenceWallClock([
      Date(timeIntervalSince1970: 10),
      Date(timeIntervalSince1970: 20),
      Date(timeIntervalSince1970: 30),
      Date(timeIntervalSince1970: 40),
      Date(timeIntervalSince1970: 50),
      Date(timeIntervalSince1970: 60),
    ])
    let pipeline = FoveaPipeline(
      configuration: PipelineConfiguration(
        maximumConcurrentFetches: 1,
        maximumConcurrentDecodes: 2
      ),
      transport: transport,
      encodedStore: try await OriginalEncodedStore.open(
        root: root.appendingPathComponent("encoded")),
      recordStore: records,
      namespaceRegistry: NamespaceRegistry(),
      decoder: ImageIOImageDecoder(),
      clock: clock
    )
    let firstRequest = try makeRequest(path: "clock-first")
    let secondRequest = try makeRequest(path: "clock-second")
    let first = Task { try await pipeline.image(for: firstRequest) }
    try await Task.sleep(for: .milliseconds(20))
    let second = Task { try await pipeline.image(for: secondRequest) }
    _ = try await first.value
    _ = try await second.value

    let secondRecordValue = await records.record(for: secondRequest.fetchVariantKey.digestHex)
    let secondRecord = try XCTUnwrap(secondRecordValue)
    XCTAssertEqual(secondRecord.requestTime, Date(timeIntervalSince1970: 50))
    XCTAssertEqual(secondRecord.responseTime, Date(timeIntervalSince1970: 60))
  }

  func testFetchQueueLimitRejectsExcessWaitersWithoutStartingNetwork_RES_PT_001() async throws {
    let body = try makePNG()
    let transport = TrackingTransport(body: body, delay: .milliseconds(120))
    let root = try makeTemporaryDirectory()
    let pipeline = FoveaPipeline(
      configuration: PipelineConfiguration(
        maximumConcurrentFetches: 1,
        maximumConcurrentDecodes: 2,
        maximumQueuedFetches: 0
      ),
      transport: transport,
      encodedStore: try await OriginalEncodedStore.open(
        root: root.appendingPathComponent("encoded")),
      recordStore: try await RepresentationRecordStore.open(
        root: root.appendingPathComponent("records")),
      decoder: ImageIOImageDecoder()
    )
    let firstRequest = try makeRequest(path: "queue-first")
    let rejectedRequest = try makeRequest(path: "queue-rejected")
    let first = Task { try await pipeline.image(for: firstRequest) }
    try await Task.sleep(for: .milliseconds(20))

    do {
      _ = try await pipeline.image(for: rejectedRequest)
      XCTFail("An exhausted zero-length queue must reject the request")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .resourceLimit)
      XCTAssertEqual(failure.stage, .transport)
      XCTAssertEqual(failure.disposition, .terminal)
      XCTAssertEqual(failure.reasonCode, "fetch-queue-limit-exceeded")
    }

    _ = try await first.value
    let requestCount = await transport.requestCount
    XCTAssertEqual(requestCount, 1)
  }

  func testDecodeConcurrencyNeverExceedsStaticLimit_RES_PT_001() async throws {
    let body = try makePNG()
    let transport = TrackingTransport(body: body, delay: .zero)
    let root = try makeTemporaryDirectory()
    let pipeline = FoveaPipeline(
      configuration: PipelineConfiguration(
        maximumConcurrentFetches: 8,
        maximumConcurrentDecodes: 1
      ),
      transport: transport,
      encodedStore: try await OriginalEncodedStore.open(
        root: root.appendingPathComponent("encoded")),
      recordStore: try await RepresentationRecordStore.open(
        root: root.appendingPathComponent("records")),
      decoder: DelayedDecoder(delay: 0.08)
    )

    let started = ContinuousClock.now
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<3 {
        group.addTask {
          let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/decode-\(index).png")),
            target: try TargetPixels(width: 20 + index, height: 20 + index),
            appID: "tests"
          )
          _ = try await pipeline.image(for: request)
        }
      }
      try await group.waitForAll()
    }
    let elapsed = started.duration(to: .now)
    XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(210))
  }

  private func makeRequest(path: String) throws -> ImageRequest {
    try ImageRequest.publicImage(
      url: XCTUnwrap(URL(string: "https://example.test/\(path).png")),
      target: TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
  }
}

private final class TrackingTransport: HTTPTransporting, Sendable {
  private let tracker = ConcurrencyTracker()
  private let body: Data
  private let delay: Duration
  private let headers: [String: String]

  init(
    body: Data,
    delay: Duration,
    headers: [String: String] = [
      "Content-Type": "image/png",
      "Cache-Control": "no-store",
    ]
  ) {
    self.body = body
    self.delay = delay
    self.headers = headers
  }

  func execute(_ request: TransportRequest) async throws -> TransportResponse {
    await tracker.begin()
    do {
      try await Task.sleep(for: delay)
      try Task.checkCancellation()
      await tracker.end()
    } catch {
      await tracker.end()
      throw error
    }
    let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    return TransportResponse(
      head: TransportResponseHead(
        statusCode: 200,
        headers: headers,
        url: request.request.url
      ),
      body: body,
      digestHex: digest,
      metrics: TransportMetrics(receivedBytes: body.count, spilledToDisk: false)
    )
  }

  var maximumConcurrentRequests: Int { get async { await tracker.maximum } }
  var requestCount: Int { get async { await tracker.total } }
}

private actor ConcurrencyTracker {
  private var active = 0
  private(set) var maximum = 0
  private(set) var total = 0

  func begin() {
    active += 1
    total += 1
    maximum = max(maximum, active)
  }

  func end() {
    active -= 1
  }
}

private actor SequenceWallClock: WallClock {
  private var values: [Date]
  private var index = 0

  init(_ values: [Date]) {
    self.values = values
  }

  func now() -> Date {
    guard !values.isEmpty else { return .distantPast }
    defer { index = min(index + 1, values.count - 1) }
    return values[index]
  }
}

private struct DelayedDecoder: ImageDecoding {
  let delay: TimeInterval

  func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
    try ImageIOImageDecoder().probe(data: data, limits: limits)
  }

  func decode(
    data: Data,
    probe: ImageProbe,
    request: ImageDecodeRequest,
    limits: DecodeLimits
  ) throws -> DecodedImage {
    Thread.sleep(forTimeInterval: delay)
    return try ImageIOImageDecoder().decode(
      data: data,
      probe: probe,
      request: request,
      limits: limits
    )
  }
}
