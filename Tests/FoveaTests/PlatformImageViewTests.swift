import FoveaCore
import ImageCraftCore
import ImageCraftImageIO
import XCTest

#if canImport(UIKit)
  import FoveaUIKit
  import UIKit

  @MainActor
  final class UIKitImageViewTests: XCTestCase {
    func testIdentityReplacementRejectsLateUIKitResult_UI_PT_016() async throws {
      let firstImage = try platformDecodedImage(width: 12)
      let secondImage = try platformDecodedImage(width: 24)
      let firstLoader = PlatformGateImageLoader(image: firstImage)
      let view = FoveaUIKit.FoveaImageView()

      view.setImage(
        request: try platformRequest(path: "uikit-first.png", width: 12),
        loader: firstLoader,
        accessibility: .decorative,
        placeholderDelayNanoseconds: 0
      )
      await firstLoader.waitUntilStarted()
      view.setImage(
        request: try platformRequest(path: "uikit-second.png", width: 24),
        loader: PlatformImmediateImageLoader(image: secondImage),
        accessibility: .decorative,
        placeholderDelayNanoseconds: 0
      )
      try await waitUntil { view.image?.cgImage?.width == 24 }

      await firstLoader.release()
      try await Task.sleep(for: .milliseconds(10))
      XCTAssertEqual(view.image?.cgImage?.width, 24)
    }

    func testSameIdentityIsIdempotentAndForceReloadsUIKit() async throws {
      let loader = PlatformCountingImageLoader(image: try platformDecodedImage(width: 18))
      let view = FoveaUIKit.FoveaImageView()
      let request = try platformRequest(path: "uikit-idempotent.png", width: 18)

      view.setImage(
        request: request,
        loader: loader,
        accessibility: .decorative,
        placeholderDelayNanoseconds: 0
      )
      try await waitUntil { view.image != nil }
      view.setImage(
        request: request,
        loader: loader,
        accessibility: .decorative,
        placeholderDelayNanoseconds: 0
      )
      try await Task.sleep(for: .milliseconds(10))
      let countAfterNoOp = await loader.requestCount
      XCTAssertEqual(countAfterNoOp, 1)

      view.setImage(
        request: request,
        loader: loader,
        accessibility: .decorative,
        placeholderDelayNanoseconds: 0,
        forceReload: true
      )
      try await waitUntil { await loader.requestCount == 2 }
    }

    func testDeinitCancelsInFlightUIKitRequest_UI_PT_016() async throws {
      let loader = PlatformCancellationLoader()
      weak var weakView: FoveaUIKit.FoveaImageView?
      var view: FoveaUIKit.FoveaImageView? = FoveaUIKit.FoveaImageView()
      weakView = view
      view?.setImage(
        request: try platformRequest(path: "uikit-deinit.png", width: 16),
        loader: loader,
        accessibility: .decorative,
        placeholderDelayNanoseconds: 0
      )
      await loader.waitUntilStarted()

      view = nil

      try await waitUntil { weakView == nil }
      try await waitUntil { await loader.wasCancelled }
    }

    func testUIKitAccessibilityMustBeExplicit_UI_PT_015() async throws {
      let view = FoveaUIKit.FoveaImageView()
      let loader = PlatformCountingImageLoader(image: try platformDecodedImage(width: 10))
      let labeledRequest = try platformRequest(path: "uikit-accessibility-label.png", width: 10)

      view.setImage(
        request: labeledRequest,
        loader: loader,
        accessibility: .label("用户头像"),
        placeholderDelayNanoseconds: 0
      )
      try await waitUntil { view.image != nil }
      XCTAssertTrue(view.isAccessibilityElement)
      XCTAssertEqual(view.accessibilityLabel, "用户头像")

      view.setImage(
        request: labeledRequest,
        loader: loader,
        accessibility: .label("更新后的头像"),
        placeholderDelayNanoseconds: 0
      )
      XCTAssertEqual(view.accessibilityLabel, "更新后的头像")
      let requestCountAfterLabelUpdate = await loader.requestCount
      XCTAssertEqual(requestCountAfterLabelUpdate, 1)

      view.setImage(
        request: try platformRequest(path: "uikit-accessibility-decorative.png", width: 10),
        loader: loader,
        accessibility: .decorative,
        placeholderDelayNanoseconds: 0
      )
      try await waitUntil { view.image != nil }
      XCTAssertFalse(view.isAccessibilityElement)
      XCTAssertNil(view.accessibilityLabel)
    }

    func testUIKitImageUsesTraitDisplayScale_UI_PT_018() async throws {
      let view = FoveaUIKit.FoveaImageView()
      view.setImage(
        request: try platformRequest(path: "uikit-display-scale.png", width: 20),
        loader: PlatformImmediateImageLoader(image: try platformDecodedImage(width: 20)),
        accessibility: .decorative,
        placeholderDelayNanoseconds: 0
      )
      try await waitUntil { view.image != nil }

      let image = try XCTUnwrap(view.image)
      let scale = max(1, view.traitCollection.displayScale)
      XCTAssertEqual(image.scale, scale)
      XCTAssertEqual(image.size.width, CGFloat(20) / scale, accuracy: 0.001)
    }

    func testPrepareForReuseCancelsAndClearsUIKitImage_UI_PT_016() async throws {
      let view = FoveaUIKit.FoveaImageView()
      view.setImage(
        request: try platformRequest(path: "uikit-reuse.png", width: 16),
        loader: PlatformImmediateImageLoader(image: try platformDecodedImage(width: 16)),
        accessibility: .decorative,
        placeholderDelayNanoseconds: 0
      )
      try await waitUntil { view.image != nil }

      view.prepareForReuse()

      XCTAssertNil(view.image)
    }
  }
#endif

#if canImport(AppKit)
  import AppKit
  import FoveaAppKit

  @MainActor
  final class AppKitImageViewTests: XCTestCase {
    func testIdentityReplacementRejectsLateAppKitResult_UI_PT_016() async throws {
      let firstImage = try platformDecodedImage(width: 12)
      let secondImage = try platformDecodedImage(width: 24)
      let firstLoader = PlatformGateImageLoader(image: firstImage)
      let view = FoveaAppKit.FoveaImageView()

      view.setImage(
        request: try platformRequest(path: "appkit-first.png", width: 12),
        loader: firstLoader,
        accessibility: .decorative,
        placeholderDelayNanoseconds: 0
      )
      await firstLoader.waitUntilStarted()
      view.setImage(
        request: try platformRequest(path: "appkit-second.png", width: 24),
        loader: PlatformImmediateImageLoader(image: secondImage),
        accessibility: .decorative,
        placeholderDelayNanoseconds: 0
      )
      try await waitUntil { appKitPixelWidth(view.image) == 24 }

      await firstLoader.release()
      try await Task.sleep(for: .milliseconds(10))
      XCTAssertEqual(appKitPixelWidth(view.image), 24)
    }

    func testSameIdentityIsIdempotentAndForceReloadsAppKit() async throws {
      let loader = PlatformCountingImageLoader(image: try platformDecodedImage(width: 18))
      let view = FoveaAppKit.FoveaImageView()
      let request = try platformRequest(path: "appkit-idempotent.png", width: 18)

      view.setImage(
        request: request,
        loader: loader,
        accessibility: .decorative,
        placeholderDelayNanoseconds: 0
      )
      try await waitUntil { view.image != nil }
      view.setImage(
        request: request,
        loader: loader,
        accessibility: .decorative,
        placeholderDelayNanoseconds: 0
      )
      try await Task.sleep(for: .milliseconds(10))
      let countAfterNoOp = await loader.requestCount
      XCTAssertEqual(countAfterNoOp, 1)

      view.setImage(
        request: request,
        loader: loader,
        accessibility: .decorative,
        placeholderDelayNanoseconds: 0,
        forceReload: true
      )
      try await waitUntil { await loader.requestCount == 2 }
    }

    func testDeinitCancelsInFlightAppKitRequest_UI_PT_016() async throws {
      let loader = PlatformCancellationLoader()
      weak var weakView: FoveaAppKit.FoveaImageView?
      var view: FoveaAppKit.FoveaImageView? = FoveaAppKit.FoveaImageView()
      weakView = view
      view?.setImage(
        request: try platformRequest(path: "appkit-deinit.png", width: 16),
        loader: loader,
        accessibility: .decorative,
        placeholderDelayNanoseconds: 0
      )
      await loader.waitUntilStarted()

      view = nil

      try await waitUntil { weakView == nil }
      try await waitUntil { await loader.wasCancelled }
    }

    func testAppKitAccessibilityMustBeExplicit_UI_PT_015() async throws {
      let view = FoveaAppKit.FoveaImageView()
      let loader = PlatformCountingImageLoader(image: try platformDecodedImage(width: 10))
      let labeledRequest = try platformRequest(path: "appkit-accessibility-label.png", width: 10)

      view.setImage(
        request: labeledRequest,
        loader: loader,
        accessibility: .label("用户头像"),
        placeholderDelayNanoseconds: 0
      )
      try await waitUntil { view.image != nil }
      XCTAssertTrue(view.isAccessibilityElement())
      XCTAssertEqual(view.accessibilityLabel(), "用户头像")

      view.setImage(
        request: labeledRequest,
        loader: loader,
        accessibility: .label("更新后的头像"),
        placeholderDelayNanoseconds: 0
      )
      XCTAssertEqual(view.accessibilityLabel(), "更新后的头像")
      let requestCountAfterLabelUpdate = await loader.requestCount
      XCTAssertEqual(requestCountAfterLabelUpdate, 1)

      view.setImage(
        request: try platformRequest(path: "appkit-accessibility-decorative.png", width: 10),
        loader: loader,
        accessibility: .decorative,
        placeholderDelayNanoseconds: 0
      )
      try await waitUntil { view.image != nil }
      XCTAssertFalse(view.isAccessibilityElement())
      XCTAssertNil(view.accessibilityLabel())
    }

    func testAppKitImageUsesBackingDisplayScale_UI_PT_018() async throws {
      let view = FoveaAppKit.FoveaImageView()
      view.setImage(
        request: try platformRequest(path: "appkit-display-scale.png", width: 20),
        loader: PlatformImmediateImageLoader(image: try platformDecodedImage(width: 20)),
        accessibility: .decorative,
        placeholderDelayNanoseconds: 0
      )
      try await waitUntil { view.image != nil }

      let image = try XCTUnwrap(view.image)
      let scale = max(1, view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
      XCTAssertEqual(appKitPixelWidth(image), 20)
      XCTAssertEqual(image.size.width, CGFloat(20) / scale, accuracy: 0.001)
    }

    func testPrepareForReuseCancelsAndClearsAppKitImage_UI_PT_016() async throws {
      let view = FoveaAppKit.FoveaImageView()
      view.setImage(
        request: try platformRequest(path: "appkit-reuse.png", width: 16),
        loader: PlatformImmediateImageLoader(image: try platformDecodedImage(width: 16)),
        accessibility: .decorative,
        placeholderDelayNanoseconds: 0
      )
      try await waitUntil { view.image != nil }

      view.prepareForReuse()

      XCTAssertNil(view.image)
    }
  }
#endif

private struct PlatformImmediateImageLoader: ImageLoading {
  let image: DecodedImage

  func image(for request: ImageRequest) async throws -> DecodedImage { image }
}

private actor PlatformCountingImageLoader: ImageLoading {
  private let image: DecodedImage
  private(set) var requestCount = 0

  init(image: DecodedImage) {
    self.image = image
  }

  func image(for request: ImageRequest) async throws -> DecodedImage {
    requestCount += 1
    return image
  }
}

private actor PlatformCancellationLoader: ImageLoading {
  private var started = false
  private(set) var wasCancelled = false
  private var startedWaiters: [CheckedContinuation<Void, Never>] = []

  func image(for request: ImageRequest) async throws -> DecodedImage {
    started = true
    for waiter in startedWaiters { waiter.resume() }
    startedWaiters.removeAll()
    do {
      try await Task.sleep(for: .seconds(60))
      throw CancellationError()
    } catch is CancellationError {
      wasCancelled = true
      throw CancellationError()
    }
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startedWaiters.append($0) }
  }
}

private actor PlatformGateImageLoader: ImageLoading {
  private let image: DecodedImage
  private var started = false
  private var released = false
  private var startedWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  init(image: DecodedImage) {
    self.image = image
  }

  func image(for request: ImageRequest) async throws -> DecodedImage {
    started = true
    for waiter in startedWaiters { waiter.resume() }
    startedWaiters.removeAll()
    if !released {
      await withCheckedContinuation { releaseWaiters.append($0) }
    }
    try Task.checkCancellation()
    return image
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startedWaiters.append($0) }
  }

  func release() {
    released = true
    for waiter in releaseWaiters { waiter.resume() }
    releaseWaiters.removeAll()
  }
}

#if canImport(AppKit)
  private func appKitPixelWidth(_ image: NSImage?) -> Int? {
    image?.representations.compactMap { representation in
      representation.pixelsWide > 0 ? representation.pixelsWide : nil
    }.max()
  }
#endif

@MainActor
private func waitUntil(
  timeoutIterations: Int = 200,
  condition: @MainActor () async -> Bool
) async throws {
  for _ in 0..<timeoutIterations {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(1))
  }
  XCTFail("等待平台图片视图状态超时")
}

private func platformRequest(path: String, width: Int) throws -> ImageRequest {
  try ImageRequest.publicImage(
    url: XCTUnwrap(URL(string: "https://example.test/\(path)")),
    target: TargetPixels(width: width, height: width),
    appID: "platform-image-view-tests"
  )
}

private func platformDecodedImage(width: Int) throws -> DecodedImage {
  try ImageIOImageDecoder().decode(
    data: makePNG(width: width, height: width),
    target: TargetPixels(width: width, height: width)
  )
}
