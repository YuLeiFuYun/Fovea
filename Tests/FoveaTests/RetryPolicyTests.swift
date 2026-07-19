import AkashicDisk
import CryptoKit
import Foundation
import FoveaCore
import FoveaHTTP
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class RetryPolicyTests: XCTestCase {
  func testTransientTransportFailureRetriesWithinSharedBudgetErrPt003() async throws {
    let body = try makePNG()
    let transport = SequencedRetryTransport(steps: [
      .failure(URLError(.networkConnectionLost)),
      .response(statusCode: 200, headers: imageHeaders, body: body),
    ])
    let sleeper = RecordingRetrySleeper()
    let diagnostics = BoundedDiagnosticsSink(capacity: 64)
    let pipeline = try await makeRetryPipeline(
      transport: transport,
      sleeper: sleeper,
      diagnostics: diagnostics,
      policy: TransportRetryPolicy(
        maximumAttempts: 3,
        baseDelayNanoseconds: 10,
        maximumDelayNanoseconds: 100,
        maximumTotalDelayNanoseconds: 100,
        jitterPermille: 0
      )
    )
    let request = try publicRequest("transient-retry.png")

    _ = try await pipeline.image(for: request)

    let requestCount = await transport.requestCount
    let delays = await sleeper.delays
    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(delays, [10])
    let retries = await diagnostics.snapshot().map(\.event).filter {
      $0.kind == .fetchRetryScheduled
    }
    XCTAssertEqual(retries.count, 1)
    XCTAssertEqual(retries.first?.attempt, 1)
    XCTAssertEqual(retries.first?.retryDelayNanoseconds, 10)
    XCTAssertEqual(retries.first?.reason, "url-session-transport")
  }

  func testRetryAfterControlsBoundedDelayErrPt003() async throws {
    let body = try makePNG()
    let transport = SequencedRetryTransport(steps: [
      .response(
        statusCode: 503,
        headers: ["Retry-After": "1"],
        body: Data()
      ),
      .response(statusCode: 200, headers: imageHeaders, body: body),
    ])
    let sleeper = RecordingRetrySleeper()
    let pipeline = try await makeRetryPipeline(
      transport: transport,
      sleeper: sleeper,
      policy: TransportRetryPolicy(
        maximumAttempts: 2,
        baseDelayNanoseconds: 10,
        maximumDelayNanoseconds: 2_000_000_000,
        maximumTotalDelayNanoseconds: 2_000_000_000,
        jitterPermille: 0
      )
    )

    _ = try await pipeline.image(for: publicRequest("retry-after.png"))

    let requestCount = await transport.requestCount
    let delays = await sleeper.delays
    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(delays, [1_000_000_000])
  }

  func testSubscriberJoinDoesNotResetRetryBudgetErrPt003() async throws {
    let transport = SequencedRetryTransport(steps: [
      .failure(URLError(.timedOut)),
      .failure(URLError(.timedOut)),
      .failure(URLError(.timedOut)),
    ])
    let sleeper = GateFirstRetrySleeper()
    let diagnostics = BoundedDiagnosticsSink(capacity: 64)
    let pipeline = try await makeRetryPipeline(
      transport: transport,
      sleeper: sleeper,
      diagnostics: diagnostics,
      policy: TransportRetryPolicy(
        maximumAttempts: 3,
        baseDelayNanoseconds: 1,
        maximumDelayNanoseconds: 4,
        maximumTotalDelayNanoseconds: 10,
        jitterPermille: 0
      )
    )
    let request = try publicRequest("shared-budget.png")
    let first = Task { try await pipeline.image(for: request) }
    await sleeper.waitUntilFirstSleep()
    let joined = Task { try await pipeline.image(for: request) }
    await waitUntilFetchJoined(diagnostics)
    await sleeper.releaseFirstSleep()

    for task in [first, joined] {
      do {
        _ = try await task.value
        XCTFail("All shared attempts must fail")
      } catch let failure as PipelineFailure {
        XCTAssertEqual(failure.category, .transport)
      }
    }

    let requestCount = await transport.requestCount
    let delays = await sleeper.delays
    XCTAssertEqual(requestCount, 3)
    XCTAssertEqual(delays, [1, 2])
  }

  func testCancellationDuringBackoffStopsFurtherAttemptsErrPt004() async throws {
    let transport = SequencedRetryTransport(steps: [
      .failure(URLError(.networkConnectionLost)),
      .response(statusCode: 200, headers: imageHeaders, body: try makePNG()),
    ])
    let sleeper = CancellableRetrySleeper()
    let pipeline = try await makeRetryPipeline(
      transport: transport,
      sleeper: sleeper,
      policy: TransportRetryPolicy(
        maximumAttempts: 2,
        baseDelayNanoseconds: 1_000_000_000,
        maximumDelayNanoseconds: 1_000_000_000,
        maximumTotalDelayNanoseconds: 1_000_000_000,
        jitterPermille: 0
      )
    )
    let request = try publicRequest("cancel-backoff.png")
    let task = Task { try await pipeline.image(for: request) }
    await sleeper.waitUntilSleeping()
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Cancelled subscriber must not receive a result")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .cancelled)
    }
    let requestCount = await transport.requestCount
    XCTAssertEqual(requestCount, 1)
  }

  func testAuthorizationStatusDoesNotRetryErrPt004() async throws {
    let transport = SequencedRetryTransport(steps: [
      .response(statusCode: 401, headers: [:], body: Data()),
      .response(statusCode: 200, headers: imageHeaders, body: try makePNG()),
    ])
    let sleeper = RecordingRetrySleeper()
    let pipeline = try await makeRetryPipeline(
      transport: transport,
      sleeper: sleeper,
      policy: TransportRetryPolicy(maximumAttempts: 3, jitterPermille: 0)
    )

    do {
      _ = try await pipeline.image(for: publicRequest("auth-no-retry.png"))
      XCTFail("401 must remain terminal without an explicit authorizer refresh")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .http)
      XCTAssertEqual(failure.statusCode, 401)
      XCTAssertEqual(failure.disposition, .terminal)
    }
    let requestCount = await transport.requestCount
    let delays = await sleeper.delays
    XCTAssertEqual(requestCount, 1)
    XCTAssertTrue(delays.isEmpty)
  }

  func testTLSAndAuthenticationTransportFailuresNeverRetryErrPt004() async throws {
    for code in [
      URLError.serverCertificateUntrusted,
      URLError.appTransportSecurityRequiresSecureConnection,
      URLError.userAuthenticationRequired,
      URLError.badURL,
    ] {
      let transport = SequencedRetryTransport(steps: [
        .failure(URLError(code)),
        .response(statusCode: 200, headers: imageHeaders, body: try makePNG()),
      ])
      let sleeper = RecordingRetrySleeper()
      let pipeline = try await makeRetryPipeline(
        transport: transport,
        sleeper: sleeper,
        policy: TransportRetryPolicy(maximumAttempts: 3, jitterPermille: 0)
      )

      do {
        _ = try await pipeline.image(for: publicRequest("terminal-\(code.rawValue).png"))
        XCTFail("Terminal URL error must not retry: \(code)")
      } catch let failure as PipelineFailure {
        XCTAssertEqual(failure.disposition, .terminal)
        XCTAssertEqual(failure.reasonCode, "url-session-terminal")
      }
      let requestCount = await transport.requestCount
      let delays = await sleeper.delays
      XCTAssertEqual(requestCount, 1)
      XCTAssertTrue(delays.isEmpty)
    }
  }

  func testAdditionalResponseByteBudgetStopsRetry() async throws {
    let transport = SequencedRetryTransport(steps: [
      .response(statusCode: 503, headers: [:], body: Data(repeating: 1, count: 128)),
      .response(statusCode: 200, headers: imageHeaders, body: try makePNG()),
    ])
    let pipeline = try await makeRetryPipeline(
      transport: transport,
      sleeper: RecordingRetrySleeper(),
      policy: TransportRetryPolicy(
        maximumAttempts: 2,
        maximumAdditionalResponseBytes: 64,
        jitterPermille: 0
      )
    )

    do {
      _ = try await pipeline.image(for: publicRequest("byte-budget.png"))
      XCTFail("503 must surface when retry byte budget is exhausted")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.statusCode, 503)
    }
    let requestCount = await transport.requestCount
    XCTAssertEqual(requestCount, 1)
  }

  func testTotalDelayBudgetStopsRetry() async throws {
    let transport = SequencedRetryTransport(steps: [
      .failure(URLError(.timedOut)),
      .response(statusCode: 200, headers: imageHeaders, body: try makePNG()),
    ])
    let sleeper = RecordingRetrySleeper()
    let pipeline = try await makeRetryPipeline(
      transport: transport,
      sleeper: sleeper,
      policy: TransportRetryPolicy(
        maximumAttempts: 2,
        baseDelayNanoseconds: 100,
        maximumDelayNanoseconds: 100,
        maximumTotalDelayNanoseconds: 50,
        jitterPermille: 0
      )
    )

    do {
      _ = try await pipeline.image(for: publicRequest("delay-budget.png"))
      XCTFail("Transport failure must surface when delay budget is exhausted")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .transport)
    }
    let requestCount = await transport.requestCount
    let delays = await sleeper.delays
    XCTAssertEqual(requestCount, 1)
    XCTAssertTrue(delays.isEmpty)
  }

  private func waitUntilFetchJoined(_ diagnostics: BoundedDiagnosticsSink) async {
    for _ in 0..<2_000 {
      if await diagnostics.snapshot().contains(where: { $0.event.kind == .fetchJoined }) {
        return
      }
      try? await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Second subscriber did not join the shared retry operation")
  }

  private func makeRetryPipeline(
    transport: any HTTPTransporting,
    sleeper: any RetrySleeping,
    diagnostics: any DiagnosticsSink = NullDiagnosticsSink(),
    policy: TransportRetryPolicy
  ) async throws -> FoveaPipeline {
    let root = try makeTemporaryDirectory()
    return FoveaPipeline(
      configuration: PipelineConfiguration(transportRetryPolicy: policy),
      transport: transport,
      encodedStore: try await OriginalEncodedStore.open(
        root: root.appendingPathComponent("encoded")
      ),
      recordStore: try await RepresentationRecordStore.open(
        root: root.appendingPathComponent("records")
      ),
      namespaceRegistry: NamespaceRegistry(),
      diagnostics: diagnostics,
      decoder: ImageIOImageDecoder(),
      retrySleeper: sleeper,
      retryJitter: FixedRetryJitter()
    )
  }

  private func publicRequest(_ path: String) throws -> ImageRequest {
    try ImageRequest.publicImage(
      url: XCTUnwrap(URL(string: "https://example.test/\(path)")),
      target: TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
  }

  private var imageHeaders: [String: String] {
    ["Content-Type": "image/png", "Cache-Control": "no-store"]
  }
}

private actor SequencedRetryTransport: HTTPTransporting {
  enum Step: Sendable {
    case failure(URLError)
    case response(statusCode: Int, headers: [String: String], body: Data)
  }

  private var steps: [Step]
  private(set) var requestCount = 0

  init(steps: [Step]) {
    self.steps = steps
  }

  func execute(_ request: TransportRequest) async throws -> TransportResponse {
    requestCount += 1
    guard !steps.isEmpty else { throw URLError(.resourceUnavailable) }
    let step = steps.removeFirst()
    switch step {
    case .failure(let error):
      throw error
    case .response(let statusCode, let headers, let body):
      let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
      return TransportResponse(
        head: TransportResponseHead(
          statusCode: statusCode,
          headers: headers,
          url: request.request.url
        ),
        body: body,
        digestHex: digest,
        metrics: TransportMetrics(receivedBytes: body.count, spilledToDisk: false)
      )
    }
  }
}

private actor RecordingRetrySleeper: RetrySleeping {
  private(set) var delays: [UInt64] = []

  func sleep(nanoseconds: UInt64) async throws {
    delays.append(nanoseconds)
    try Task.checkCancellation()
  }
}

private actor GateFirstRetrySleeper: RetrySleeping {
  private(set) var delays: [UInt64] = []
  private var firstSleepStarted = false
  private var released = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func sleep(nanoseconds: UInt64) async throws {
    delays.append(nanoseconds)
    if delays.count == 1 {
      firstSleepStarted = true
      for waiter in startWaiters { waiter.resume() }
      startWaiters.removeAll()
      if !released {
        await withCheckedContinuation { releaseWaiters.append($0) }
      }
    }
    try Task.checkCancellation()
  }

  func waitUntilFirstSleep() async {
    guard !firstSleepStarted else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func releaseFirstSleep() {
    released = true
    for waiter in releaseWaiters { waiter.resume() }
    releaseWaiters.removeAll()
  }
}

private actor CancellableRetrySleeper: RetrySleeping {
  private var isSleeping = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func sleep(nanoseconds: UInt64) async throws {
    isSleeping = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
    try await Task.sleep(nanoseconds: 60_000_000_000)
  }

  func waitUntilSleeping() async {
    guard !isSleeping else { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}

private struct FixedRetryJitter: RetryJittering {
  func offsetPermille(maximumMagnitude: Int) async -> Int { 0 }
}
