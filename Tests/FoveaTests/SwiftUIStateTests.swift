import Combine
import FoveaCore
import FoveaSwiftUI
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

@MainActor
final class SwiftUIStateTests: XCTestCase {
  func testReduceMotionDisablesImageTransition_UI_PT_007() {
    let policy = FoveaImageTransitionPolicy(opacityDuration: 0.25)

    XCTAssertEqual(policy.resolved(reduceMotion: false), .opacity(duration: 0.25))
    XCTAssertEqual(policy.resolved(reduceMotion: true), .identity)
    XCTAssertEqual(
      FoveaImageTransitionPolicy(opacityDuration: 0).resolved(reduceMotion: false),
      .identity
    )
  }

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

  func testPreviewIdentityChangeRejectsOldFinal_UI_PT_003() async throws {
    let model = FoveaImageModel()
    let oldPreview = try decodedImage(width: 10)
    let oldFinal = try decodedImage(width: 30)
    let oldLoader = GateProgressiveImageLoader(preview: oldPreview, final: oldFinal)
    let oldRequest = try request(path: "old-progressive.png", width: 30, height: 30)
    let previewPublished = expectation(description: "preview 已发布到模型")
    let observation = model.$phase.sink { phase in
      if phase.kind == .preview { previewPublished.fulfill() }
    }
    defer { observation.cancel() }
    let oldTask = Task { await model.load(request: oldRequest, loader: oldLoader) }
    await fulfillment(of: [previewPublished], timeout: 1)
    XCTAssertEqual(model.phase.kind, .preview)

    let newImage = try decodedImage(width: 20)
    let newRequest = try request(path: "new-final.png", width: 20, height: 20)
    await model.load(request: newRequest, loader: ImmediateImageLoader(image: newImage))
    XCTAssertEqual(model.phase.kind, .success)

    await oldLoader.releaseFinal()
    await oldTask.value

    guard case .success(let displayed) = model.phase else {
      return XCTFail("新 identity 的 final 必须保持可见")
    }
    XCTAssertEqual(displayed.pixelWidth, 20)
  }

  func testPreviewOnlyStreamEndsAsFailure() async throws {
    let model = FoveaImageModel()
    let loader = PreviewOnlyImageLoader(image: try decodedImage())

    await model.load(
      request: try request(path: "preview-only.png"),
      loader: loader
    )

    guard case .failure(let failure) = model.phase else {
      return XCTFail("缺少 final 的渐进流必须进入失败状态")
    }
    XCTAssertEqual(failure, .incompleteProgressiveStream)
  }

  func testGeometryBuilderFailureIsObservableAndClearsPreviousRequest_UI_PT_017() throws {
    let geometryModel = FoveaGeometryRequestModel()
    let url = try XCTUnwrap(URL(string: "https://example.test/geometry-builder.png"))
    geometryModel.update(
      widthPoints: 20,
      heightPoints: 20,
      scale: 2,
      contentMode: .fit,
      isStable: true
    ) { target in
      try ImageRequest.publicImage(url: url, resolvedTarget: target, appID: "tests")
    }
    XCTAssertNotNil(geometryModel.request)

    geometryModel.update(
      widthPoints: 30,
      heightPoints: 30,
      scale: 2,
      contentMode: .fit,
      isStable: true
    ) { _ in
      throw GeometryBuilderFixtureError.failed
    }
    XCTAssertNil(geometryModel.request)
    XCTAssertEqual(geometryModel.failure?.category, .internalFailure)
    XCTAssertEqual(geometryModel.failure?.stage, .requestValidation)
    XCTAssertEqual(geometryModel.failure?.reasonCode, "responsive-request-builder-failed")

    let expected = PipelineFailure(
      category: .transport,
      stage: .transport,
      disposition: .retryable,
      reasonCode: "builder-needs-refresh"
    )
    geometryModel.update(
      widthPoints: 40,
      heightPoints: 40,
      scale: 2,
      contentMode: .fit,
      isStable: true
    ) { _ in
      throw expected
    }
    XCTAssertEqual(geometryModel.failure, expected)

    geometryModel.reset()
    XCTAssertNil(geometryModel.request)
    XCTAssertNil(geometryModel.failure)

    geometryModel.update(
      widthPoints: -1,
      heightPoints: 20,
      scale: 2,
      contentMode: .fit,
      isStable: true
    ) { target in
      try ImageRequest.publicImage(url: url, resolvedTarget: target, appID: "tests")
    }
    XCTAssertEqual(geometryModel.failure?.category, .securityLimit)
    XCTAssertEqual(geometryModel.failure?.stage, .requestValidation)
    XCTAssertEqual(geometryModel.failure?.reasonCode, "invalid-target-pixels")
  }

  func testPhaseKindsAndFailureRetryContract_UI_PT_017() throws {
    let image = try decodedImage()
    let failure = PipelineFailure(
      category: .transport,
      stage: .transport,
      disposition: .retryable,
      reasonCode: "retryable"
    )
    XCTAssertEqual(FoveaImagePhase.empty.kind, .empty)
    XCTAssertEqual(FoveaImagePhase.loading.kind, .loading)
    XCTAssertEqual(FoveaImagePhase.preview(image).kind, .preview)
    XCTAssertEqual(FoveaImagePhase.success(image).kind, .success)
    XCTAssertEqual(FoveaImagePhase.failure(failure).kind, .failure)
    XCTAssertEqual(FoveaImagePhase.cancelled.kind, .cancelled)

    var retryCount = 0
    let retrying = FoveaImageFailureContext(
      failure: failure,
      recoveryAction: .retry,
      retryAction: { retryCount += 1 }
    )
    retrying.retry()
    XCTAssertEqual(retryCount, 1)

    let terminal = FoveaImageFailureContext(
      failure: failure,
      recoveryAction: .none,
      retryAction: { retryCount += 1 }
    )
    terminal.retry()
    XCTAssertEqual(retryCount, 1)
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

  func testZeroLayoutDoesNotLoadAndStableSizeLoadsOnce_UI_PT_011() async throws {
    let geometryModel = FoveaGeometryRequestModel()
    let imageModel = FoveaImageModel()
    let loader = CountingImageLoader(image: try decodedImage())
    let url = try XCTUnwrap(URL(string: "https://example.test/responsive.png"))
    let builder: (ResolvedImageTarget) throws -> ImageRequest = { target in
      try ImageRequest.publicImage(url: url, resolvedTarget: target, appID: "tests")
    }

    geometryModel.update(
      widthPoints: 0,
      heightPoints: 0,
      scale: 2,
      contentMode: .fit,
      isStable: false,
      requestBuilder: builder
    )
    XCTAssertNil(geometryModel.request)
    let zeroCount = await loader.requestCount
    XCTAssertEqual(zeroCount, 0)

    geometryModel.update(
      widthPoints: 20,
      heightPoints: 10,
      scale: 2,
      contentMode: .fit,
      isStable: true,
      requestBuilder: builder
    )
    let request = try XCTUnwrap(geometryModel.request)
    await imageModel.load(request: request, loader: loader)

    geometryModel.update(
      widthPoints: 20,
      heightPoints: 10,
      scale: 2,
      contentMode: .fit,
      isStable: true,
      requestBuilder: builder
    )
    let repeatedRequest = try XCTUnwrap(geometryModel.request)
    await imageModel.load(request: repeatedRequest, loader: loader)

    let finalCount = await loader.requestCount
    XCTAssertEqual(finalCount, 1)
    XCTAssertEqual(imageModel.phase.kind, .success)
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

  private func decodedImage(width: Int = 20) throws -> DecodedImage {
    try ImageIOImageDecoder().decode(
      data: makePNG(width: 100, height: 50),
      target: TargetPixels(width: width, height: width)
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

private struct PreviewOnlyImageLoader: ProgressiveImageLoading {
  let image: DecodedImage

  nonisolated func events(
    for request: ImageRequest
  ) -> AsyncThrowingStream<ImageLoadingEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.preview(image, quality: 1))
      continuation.finish()
    }
  }
}

private enum GeometryBuilderFixtureError: Error {
  case failed
}

private actor GateProgressiveImageLoader: ProgressiveImageLoading {
  private let preview: DecodedImage
  private let final: DecodedImage
  private var previewWaiters: [CheckedContinuation<Void, Never>] = []
  private var finalWaiters: [CheckedContinuation<Void, Never>] = []
  private var previewWasConsumed = false
  private var finalWasReleased = false

  init(preview: DecodedImage, final: DecodedImage) {
    self.preview = preview
    self.final = final
  }

  nonisolated func events(
    for request: ImageRequest
  ) -> AsyncThrowingStream<ImageLoadingEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        let preview = self.preview
        continuation.yield(.preview(preview, quality: 1))
        await self.markPreviewConsumed()
        await self.waitForFinalRelease()
        let final = self.final
        continuation.yield(.final(final))
        continuation.finish()
      }
    }
  }

  func waitUntilPreviewWasConsumed() async {
    if previewWasConsumed { return }
    await withCheckedContinuation { previewWaiters.append($0) }
  }

  func releaseFinal() {
    finalWasReleased = true
    for waiter in finalWaiters { waiter.resume() }
    finalWaiters.removeAll()
  }

  private func markPreviewConsumed() {
    previewWasConsumed = true
    for waiter in previewWaiters { waiter.resume() }
    previewWaiters.removeAll()
  }

  private func waitForFinalRelease() async {
    if finalWasReleased { return }
    await withCheckedContinuation { finalWaiters.append($0) }
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

private actor CountingImageLoader: ImageLoading {
  let image: DecodedImage
  private(set) var requestCount = 0

  init(image: DecodedImage) {
    self.image = image
  }

  func image(for request: ImageRequest) async throws -> DecodedImage {
    requestCount += 1
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
