import AkashicDisk
import CryptoKit
import Foundation
import FoveaCore
import FoveaHTTP
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class AuthenticationRefreshTests: XCTestCase {
  func testConcurrentUnauthorizedRequestsShareOneRefreshAuthPt007() async throws {
    let fixture = try await makeFixture()
    let refresher = GatedCredentialRefresher()
    let loader = RefreshingImageLoader(base: fixture.pipeline, refresher: refresher)

    async let first = loader.image(for: fixture.request)
    async let second = loader.image(for: fixture.request)
    await refresher.waitUntilStarted()
    await refresher.release()
    _ = try await [first, second]

    let refreshCount = await refresher.refreshCount
    XCTAssertEqual(refreshCount, 1)
    let counts = await fixture.transport.counts
    XCTAssertGreaterThanOrEqual(counts["Bearer old", default: 0], 1)
    XCTAssertGreaterThanOrEqual(counts["Bearer new", default: 0], 1)
  }

  func testCompletedRefreshCoversLateOldGenerationUnauthorizedRequestAuthPt007() async throws {
    let fixture = try await makeFixture()
    let refresher = FixedCredentialRefresher(
      result: CredentialRefreshResult(
        credentialGeneration: CredentialGeneration(2),
        headers: ["Authorization": "Bearer new"]
      )
    )
    let loader = RefreshingImageLoader(base: fixture.pipeline, refresher: refresher)

    _ = try await loader.image(for: fixture.request)
    _ = try await loader.image(for: fixture.request)

    let refreshCount = await refresher.refreshCount
    let counts = await fixture.transport.counts
    XCTAssertEqual(refreshCount, 1)
    XCTAssertEqual(counts["Bearer old"], 2)
    XCTAssertEqual(counts["Bearer new"], 2)
  }

  func testCancellingOneRefreshSubscriberDoesNotCancelOtherAuthPt007() async throws {
    let fixture = try await makeFixture()
    let refresher = GatedCredentialRefresher()
    let loader = RefreshingImageLoader(base: fixture.pipeline, refresher: refresher)
    let first = Task { try await loader.image(for: fixture.request) }
    let second = Task { try await loader.image(for: fixture.request) }
    await refresher.waitUntilStarted()

    first.cancel()
    await refresher.release()
    do {
      _ = try await first.value
      XCTFail("Cancelled subscriber must not receive a refreshed image")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .cancelled)
    }
    _ = try await second.value

    let refreshCount = await refresher.refreshCount
    let wasCancelled = await refresher.wasCancelled
    XCTAssertEqual(refreshCount, 1)
    XCTAssertFalse(wasCancelled)
    let counts = await fixture.transport.counts
    XCTAssertEqual(counts["Bearer new"], 1)
  }

  func testRefreshGenerationMustAdvanceAuthPt009() async throws {
    let fixture = try await makeFixture()
    let refresher = FixedCredentialRefresher(
      result: CredentialRefreshResult(
        credentialGeneration: CredentialGeneration(1),
        headers: ["Authorization": "Bearer new"]
      )
    )
    let loader = RefreshingImageLoader(base: fixture.pipeline, refresher: refresher)

    do {
      _ = try await loader.image(for: fixture.request)
      XCTFail("A refresh that does not advance generation must fail closed")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .authorization)
      XCTAssertEqual(failure.reasonCode, "credential-generation-not-advanced")
    }
    let counts = await fixture.transport.counts
    XCTAssertEqual(counts["Bearer old"], 1)
    XCTAssertNil(counts["Bearer new"])
  }

  func testForbiddenResponseDoesNotTriggerCredentialRefreshAuthPt009() async throws {
    let fixture = try await makeFixture(oldStatusCode: 403)
    let refresher = FixedCredentialRefresher(
      result: CredentialRefreshResult(
        credentialGeneration: CredentialGeneration(2),
        headers: ["Authorization": "Bearer new"]
      )
    )
    let loader = RefreshingImageLoader(base: fixture.pipeline, refresher: refresher)

    do {
      _ = try await loader.image(for: fixture.request)
      XCTFail("403 must not be converted into a credential refresh")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.statusCode, 403)
    }
    let refreshCount = await refresher.refreshCount
    XCTAssertEqual(refreshCount, 0)
  }

  func testRecursiveRefreshIsRejectedAuthPt009() async throws {
    let fixture = try await makeFixture()
    let refresher = RecursiveCredentialRefresher()
    let loader = RefreshingImageLoader(base: fixture.pipeline, refresher: refresher)
    await refresher.install {
      _ = try await loader.image(for: fixture.request)
    }

    do {
      _ = try await loader.image(for: fixture.request)
      XCTFail("Recursive credential refresh must not deadlock or recurse")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .authorization)
      XCTAssertEqual(failure.reasonCode, "credential-refresh-reentrancy")
    }
  }

  func testAuthorizationContextChangeChangesPersistentIdentityAuthPt002() throws {
    let url = try XCTUnwrap(URL(string: "https://example.test/context-change.png"))
    let first = try authenticatedRequest(
      url: url,
      context: "reader",
      generation: 1,
      token: "Bearer reader"
    )
    let second = try authenticatedRequest(
      url: url,
      context: "admin",
      generation: 1,
      token: "Bearer admin"
    )

    XCTAssertNotEqual(first.fetchBaseKey, second.fetchBaseKey)
    XCTAssertNotEqual(first.fetchVariantKey, second.fetchVariantKey)
  }

  private func makeFixture(oldStatusCode: Int = 401) async throws -> AuthRefreshFixture {
    let body = try makePNG()
    let transport = CredentialSwitchingTransport(
      oldStatusCode: oldStatusCode,
      body: body
    )
    let root = try makeTemporaryDirectory()
    let pipeline = FoveaPipeline(
      configuration: PipelineConfiguration(
        transportRetryPolicy: TransportRetryPolicy(maximumAttempts: 1)
      ),
      transport: transport,
      encodedStore: try await OriginalEncodedStore.open(
        root: root.appendingPathComponent("encoded")
      ),
      recordStore: try await RepresentationRecordStore.open(
        root: root.appendingPathComponent("records")
      ),
      decoder: ImageIOImageDecoder()
    )
    let request = try authenticatedRequest(
      url: XCTUnwrap(URL(string: "https://example.test/private-refresh.png")),
      context: "account",
      generation: 1,
      token: "Bearer old"
    )
    return AuthRefreshFixture(
      pipeline: pipeline,
      transport: transport,
      request: request
    )
  }

  private func authenticatedRequest(
    url: URL,
    context: String,
    generation: UInt64,
    token: String
  ) throws -> ImageRequest {
    try ImageRequest(
      url: url,
      target: TargetPixels(width: 20, height: 20),
      namespace: SecurityNamespaceID("account-a"),
      authorizationContext: AuthorizationContextID(context),
      credentialGeneration: CredentialGeneration(generation),
      headers: ["Authorization": token]
    )
  }
}

private struct AuthRefreshFixture {
  let pipeline: FoveaPipeline
  let transport: CredentialSwitchingTransport
  let request: ImageRequest
}

private actor CredentialSwitchingTransport: HTTPTransporting {
  nonisolated let reusePolicy = TransportReusePolicy.reusable(
    contextIdentifier: "tests-credential-switch-v1"
  )

  private let oldStatusCode: Int
  private let body: Data
  private(set) var counts: [String: Int] = [:]

  init(oldStatusCode: Int, body: Data) {
    self.oldStatusCode = oldStatusCode
    self.body = body
  }

  func execute(_ request: TransportRequest) async throws -> TransportResponse {
    let credential = request.request.value(forHTTPHeaderField: "Authorization") ?? "missing"
    counts[credential, default: 0] += 1
    let statusCode = credential == "Bearer new" ? 200 : oldStatusCode
    let responseBody = statusCode == 200 ? body : Data()
    let digest = SHA256.hash(data: responseBody)
      .map { String(format: "%02x", $0) }
      .joined()
    return TransportResponse(
      head: TransportResponseHead(
        statusCode: statusCode,
        headers: statusCode == 200
          ? ["Content-Type": "image/png", "Cache-Control": "no-store"]
          : [:],
        url: request.request.url
      ),
      body: responseBody,
      digestHex: digest,
      metrics: TransportMetrics(receivedBytes: responseBody.count, spilledToDisk: false)
    )
  }
}

private actor GatedCredentialRefresher: CredentialRefreshing {
  private(set) var refreshCount = 0
  private(set) var wasCancelled = false
  private var started = false
  private var released = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func refreshCredentials(
    namespace: SecurityNamespaceID,
    authorizationContext: AuthorizationContextID,
    currentGeneration: CredentialGeneration
  ) async throws -> CredentialRefreshResult {
    refreshCount += 1
    started = true
    for waiter in startWaiters { waiter.resume() }
    startWaiters.removeAll()
    do {
      if !released {
        await withTaskCancellationHandler {
          await withCheckedContinuation { releaseWaiters.append($0) }
        } onCancel: {
          Task { await self.markCancelled() }
        }
      }
      try Task.checkCancellation()
    } catch {
      wasCancelled = true
      throw error
    }
    return CredentialRefreshResult(
      credentialGeneration: CredentialGeneration(currentGeneration.value + 1),
      headers: ["Authorization": "Bearer new"]
    )
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func release() {
    released = true
    for waiter in releaseWaiters { waiter.resume() }
    releaseWaiters.removeAll()
  }

  private func markCancelled() {
    wasCancelled = true
    for waiter in releaseWaiters { waiter.resume() }
    releaseWaiters.removeAll()
  }
}

private actor FixedCredentialRefresher: CredentialRefreshing {
  private let result: CredentialRefreshResult
  private(set) var refreshCount = 0

  init(result: CredentialRefreshResult) {
    self.result = result
  }

  func refreshCredentials(
    namespace: SecurityNamespaceID,
    authorizationContext: AuthorizationContextID,
    currentGeneration: CredentialGeneration
  ) async throws -> CredentialRefreshResult {
    refreshCount += 1
    return result
  }
}

private actor RecursiveCredentialRefresher: CredentialRefreshing {
  private var recursiveOperation: (@Sendable () async throws -> Void)?

  func install(_ operation: @escaping @Sendable () async throws -> Void) {
    recursiveOperation = operation
  }

  func refreshCredentials(
    namespace: SecurityNamespaceID,
    authorizationContext: AuthorizationContextID,
    currentGeneration: CredentialGeneration
  ) async throws -> CredentialRefreshResult {
    try await recursiveOperation?()
    return CredentialRefreshResult(
      credentialGeneration: CredentialGeneration(currentGeneration.value + 1),
      headers: ["Authorization": "Bearer new"]
    )
  }
}
