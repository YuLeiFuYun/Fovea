import AkashicDisk
import CryptoKit
import Foundation
import FoveaCore
import FoveaHTTP
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class PriorityPropagationTests: XCTestCase {
  func testJoinedSubscriberRaisesAndThenLowersTransportPriority_SCHED_PT_003() async throws {
    let body = try makePNG()
    let transport = PriorityObservingTransport(body: body)
    let diagnostics = BoundedDiagnosticsSink(capacity: 64)
    let root = try makeTemporaryDirectory()
    let pipeline = FoveaPipeline(
      transport: transport,
      encodedStore: try await OriginalEncodedStore.open(
        root: root.appendingPathComponent("encoded")
      ),
      recordStore: try await RepresentationRecordStore.open(
        root: root.appendingPathComponent("records")
      ),
      diagnostics: diagnostics,
      decoder: ImageIOImageDecoder()
    )
    let url = try XCTUnwrap(URL(string: "https://example.test/priority-propagation.png"))
    let lowRequest = try ImageRequest.publicImage(
      url: url,
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests",
      priority: .low
    )
    let highRequest = try ImageRequest.publicImage(
      url: url,
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests",
      priority: .userInitiated
    )

    let low = Task { try await pipeline.image(for: lowRequest) }
    await transport.waitUntilStarted()
    let high = Task { try await pipeline.image(for: highRequest) }
    await transport.waitUntilObserved(.userInitiated)
    high.cancel()
    do {
      _ = try await high.value
      XCTFail("Cancelled high-priority subscriber must not receive the shared result")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .cancelled)
    }
    await transport.waitUntilObservedLowAfterHigh()
    await transport.release()
    _ = try await low.value

    let requestCount = await transport.requestCount
    let observed = await transport.observedPriorities
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(observed.first, .low)
    XCTAssertTrue(observed.contains(.userInitiated))
    XCTAssertEqual(observed.last, .low)

    let events = await diagnostics.snapshot().map(\.event)
    let join = try XCTUnwrap(events.first { $0.kind == .fetchJoined })
    XCTAssertEqual(join.requestedPriority, .userInitiated)
    XCTAssertEqual(join.effectivePriority, .userInitiated)
  }
}

private actor PriorityObservingTransport: HTTPTransporting {
  nonisolated let reusePolicy = TransportReusePolicy.reusable(
    contextIdentifier: "tests-priority-observing-v1"
  )

  private let body: Data
  private var started = false
  private var released = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  private var priorityWaiters: [(TransportPriority, CheckedContinuation<Void, Never>)] = []
  private(set) var observedPriorities: [TransportPriority] = []
  private(set) var requestCount = 0

  init(body: Data) {
    self.body = body
  }

  func execute(_ request: TransportRequest) async throws -> TransportResponse {
    requestCount += 1
    observe(request.priority)
    let priorityObserver = Task { [weak self] in
      guard let controller = request.priorityController else { return }
      let updates = await controller.updates()
      for await priority in updates {
        await self?.observe(priority)
      }
    }
    started = true
    for waiter in startWaiters { waiter.resume() }
    startWaiters.removeAll()
    if !released {
      await withCheckedContinuation { releaseWaiters.append($0) }
    }
    priorityObserver.cancel()
    try Task.checkCancellation()
    let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    return TransportResponse(
      head: TransportResponseHead(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
        url: request.request.url
      ),
      body: body,
      digestHex: digest,
      metrics: TransportMetrics(receivedBytes: body.count, spilledToDisk: false)
    )
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func waitUntilObserved(_ priority: TransportPriority) async {
    guard !observedPriorities.contains(priority) else { return }
    await withCheckedContinuation { priorityWaiters.append((priority, $0)) }
  }

  func waitUntilObservedLowAfterHigh() async {
    if let highIndex = observedPriorities.lastIndex(of: .userInitiated),
      observedPriorities.dropFirst(highIndex + 1).contains(.low)
    {
      return
    }
    for _ in 0..<2_000 {
      if let highIndex = observedPriorities.lastIndex(of: .userInitiated),
        observedPriorities.dropFirst(highIndex + 1).contains(.low)
      {
        return
      }
      try? await Task.sleep(for: .milliseconds(1))
    }
  }

  func release() {
    released = true
    for waiter in releaseWaiters { waiter.resume() }
    releaseWaiters.removeAll()
  }

  private func observe(_ priority: TransportPriority) {
    guard observedPriorities.last != priority else { return }
    observedPriorities.append(priority)
    var remaining: [(TransportPriority, CheckedContinuation<Void, Never>)] = []
    for waiter in priorityWaiters {
      if waiter.0 == priority {
        waiter.1.resume()
      } else {
        remaining.append(waiter)
      }
    }
    priorityWaiters = remaining
  }
}
