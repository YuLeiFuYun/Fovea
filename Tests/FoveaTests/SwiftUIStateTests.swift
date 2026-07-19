import Combine
import FoveaCore
import FoveaSwiftUI
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

@MainActor
final class SwiftUIStateTests: XCTestCase {
  func testLateResultCannotOverwriteNewIdentityUiPt001() async throws {
    let body = try makePNG(width: 100, height: 50)
    let (pipeline, _, _, _) = try await makePipeline(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
        body: body,
        delayNanoseconds: 100_000_000
      ),
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
        body: body
      ),
    ])
    let model = FoveaImageModel()
    let first = try request(path: "first.png", width: 10, height: 10)
    let second = try request(path: "second.png", width: 20, height: 20)

    let firstTask = Task { await model.load(request: first, loader: pipeline) }
    try await Task.sleep(for: .milliseconds(10))
    await model.load(request: second, loader: pipeline)
    _ = await firstTask.result

    guard case .success(let image) = model.phase else {
      return XCTFail("Expected final image")
    }
    XCTAssertEqual(image.pixelWidth, 20)
    XCTAssertEqual(image.pixelHeight, 10)
  }

  func testNearSynchronousHitDoesNotPublishLoadingUiPt002() async throws {
    let image = try decodedImage()
    let model = FoveaImageModel()
    let loader = ImmediateImageLoader(image: image)
    var kinds: [FoveaImagePhaseKind] = []
    let observation = model.$phase.sink { kinds.append($0.kind) }
    defer { observation.cancel() }

    await model.load(
      request: try request(path: "memory.png"),
      loader: loader,
      policy: FoveaImageLoadingPolicy(placeholderDelayNanoseconds: 50_000_000)
    )

    XCTAssertEqual(model.phase.kind, .success)
    XCTAssertFalse(kinds.contains(.loading))
  }

  func testSlowLoadPublishesLoadingThenSuccessUiPt009() async throws {
    let model = FoveaImageModel()
    let loader = DelayedImageLoader(image: try decodedImage(), delayNanoseconds: 50_000_000)
    let request = try request(path: "slow.png")
    let task = Task {
      await model.load(
        request: request,
        loader: loader,
        policy: FoveaImageLoadingPolicy(placeholderDelayNanoseconds: 1_000_000)
      )
    }

    try await Task.sleep(for: .milliseconds(10))
    XCTAssertEqual(model.phase.kind, .loading)
    await task.value
    XCTAssertEqual(model.phase.kind, .success)
  }

  func testInvalidateRejectsLateResultUiPt004() async throws {
    let model = FoveaImageModel()
    let loader = GateImageLoader(image: try decodedImage())
    let request = try request(path: "invalidate.png")
    let task = Task { await model.load(request: request, loader: loader) }
    await loader.waitUntilStarted()

    model.invalidate()
    await loader.release()
    await task.value

    XCTAssertEqual(model.phase.kind, .empty)
  }

  func testSameIdentityCreatesOneSubscriptionUiPt005() async throws {
    let model = FoveaImageModel()
    let loader = GateImageLoader(image: try decodedImage())
    let request = try request(path: "deduplicated.png")
    let first = Task { await model.load(request: request, loader: loader) }
    await loader.waitUntilStarted()

    await model.load(request: request, loader: loader)
    let countBeforeRelease = await loader.requestCount
    XCTAssertEqual(countBeforeRelease, 1)

    await loader.release()
    await first.value
    XCTAssertEqual(model.phase.kind, .success)
  }

  func testRetryUsesNewGenerationUiPt006() async throws {
    let model = FoveaImageModel()
    let loader = RetryImageLoader(image: try decodedImage())
    let request = try request(path: "retry.png")

    await model.load(request: request, loader: loader)
    XCTAssertEqual(model.phase.kind, .failure)
    let failedGeneration = model.requestGeneration

    await model.retry(request: request, loader: loader)
    XCTAssertEqual(model.phase.kind, .success)
    XCTAssertGreaterThan(model.requestGeneration, failedGeneration)
    let requestCount = await loader.requestCount
    XCTAssertEqual(requestCount, 2)
  }

  func testIdentityChangeClearsPrivateImageBeforeReplacementUiPt008() async throws {
    let model = FoveaImageModel()
    let firstLoader = ImmediateImageLoader(image: try decodedImage())
    let first = try privateRequest(path: "account-a.png", namespace: "account-a")
    await model.load(request: first, loader: firstLoader)
    XCTAssertEqual(model.phase.kind, .success)

    let second = try privateRequest(path: "account-b.png", namespace: "account-b")
    model.prepareForIdentityChange(to: second.displayIdentity, retention: .clearImmediately)

    XCTAssertEqual(model.phase.kind, .empty)
  }

  func testRecoveryActionUsesCentralFailureMatrixUiPt014() {
    XCTAssertEqual(
      PipelineFailure(
        category: .transport,
        stage: .transport,
        disposition: .retryable,
        reasonCode: "transport"
      ).imageRecoveryAction,
      .retry
    )
    XCTAssertEqual(
      PipelineFailure(
        category: .namespaceRevoked,
        stage: .revocation,
        disposition: .terminal,
        reasonCode: "namespace-revoked"
      ).imageRecoveryAction,
      .reauthenticate
    )
    XCTAssertEqual(
      PipelineFailure(
        category: .securityLimit,
        stage: .probe,
        disposition: .terminal,
        reasonCode: "security"
      ).imageRecoveryAction,
      .none
    )
  }

  private func decodedImage() throws -> DecodedImage {
    try ImageIOImageDecoder().decode(
      data: makePNG(width: 100, height: 50),
      target: TargetPixels(width: 20, height: 20)
    )
  }

  private func request(path: String, width: Int = 20, height: Int = 20) throws -> ImageRequest {
    try ImageRequest.publicImage(
      url: XCTUnwrap(URL(string: "https://example.test/\(path)")),
      target: TargetPixels(width: width, height: height),
      appID: "tests"
    )
  }

  private func privateRequest(path: String, namespace: String) throws -> ImageRequest {
    try ImageRequest(
      url: XCTUnwrap(URL(string: "https://example.test/\(path)")),
      target: TargetPixels(width: 20, height: 20),
      namespace: SecurityNamespaceID(namespace),
      authorizationContext: AuthorizationContextID("principal-\(namespace)"),
      credentialGeneration: CredentialGeneration(1),
      headers: ["Authorization": "Bearer \(namespace)"]
    )
  }
}

private struct ImmediateImageLoader: ImageLoading {
  let image: DecodedImage
  func image(for request: ImageRequest) async throws -> DecodedImage { image }
}

private struct DelayedImageLoader: ImageLoading {
  let image: DecodedImage
  let delayNanoseconds: UInt64

  func image(for request: ImageRequest) async throws -> DecodedImage {
    try await Task.sleep(nanoseconds: delayNanoseconds)
    return image
  }
}

private actor GateImageLoader: ImageLoading {
  let image: DecodedImage
  private(set) var requestCount = 0
  private var isReleased = false
  private var startedWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  init(image: DecodedImage) {
    self.image = image
  }

  func image(for request: ImageRequest) async throws -> DecodedImage {
    requestCount += 1
    for waiter in startedWaiters { waiter.resume() }
    startedWaiters.removeAll()
    if !isReleased {
      await withCheckedContinuation { releaseWaiters.append($0) }
    }
    try Task.checkCancellation()
    return image
  }

  func waitUntilStarted() async {
    if requestCount > 0 { return }
    await withCheckedContinuation { startedWaiters.append($0) }
  }

  func release() {
    isReleased = true
    for waiter in releaseWaiters { waiter.resume() }
    releaseWaiters.removeAll()
  }
}

private actor RetryImageLoader: ImageLoading {
  let image: DecodedImage
  private(set) var requestCount = 0

  init(image: DecodedImage) {
    self.image = image
  }

  func image(for request: ImageRequest) async throws -> DecodedImage {
    requestCount += 1
    if requestCount == 1 {
      throw PipelineFailure(
        category: .transport,
        stage: .transport,
        disposition: .retryable,
        reasonCode: "retry-test"
      )
    }
    return image
  }
}
