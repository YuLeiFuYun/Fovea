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
            try await waitUntilOnMainActor("平台图片视图状态收敛") { view.image?.cgImage?.width == 24 }

            await firstLoader.release()
            try await testSleep(.milliseconds(10))
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
            try await waitUntilOnMainActor("平台图片视图状态收敛") { view.image != nil }
            view.setImage(
                request: request,
                loader: loader,
                accessibility: .decorative,
                placeholderDelayNanoseconds: 0
            )
            try await testSleep(.milliseconds(10))
            let countAfterNoOp = await loader.requestCount
            XCTAssertEqual(countAfterNoOp, 1)

            view.setImage(
                request: request,
                loader: loader,
                accessibility: .decorative,
                placeholderDelayNanoseconds: 0,
                forceReload: true
            )
            try await waitUntilOnMainActor("平台图片视图状态收敛") { await loader.requestCount == 2 }
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

            try await waitUntilOnMainActor("平台图片视图状态收敛") { weakView == nil }
            try await waitUntilOnMainActor("平台图片视图状态收敛") { await loader.wasCancelled }
        }

        func testUIKitAccessibilityMustBeExplicit_UI_PT_015() async throws {
            let view = FoveaUIKit.FoveaImageView()
            let loader = PlatformCountingImageLoader(image: try platformDecodedImage(width: 10))
            let labeledRequest = try platformRequest(
                path: "uikit-accessibility-label.png", width: 10)

            view.setImage(
                request: labeledRequest,
                loader: loader,
                accessibility: .label("用户头像"),
                placeholderDelayNanoseconds: 0
            )
            try await waitUntilOnMainActor("平台图片视图状态收敛") { view.image != nil }
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
            try await waitUntilOnMainActor("平台图片视图状态收敛") { view.image != nil }
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
            try await waitUntilOnMainActor("平台图片视图状态收敛") { view.image != nil }

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
            try await waitUntilOnMainActor("平台图片视图状态收敛") { view.image != nil }

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
            try await waitUntilOnMainActor("平台图片视图状态收敛") { appKitPixelWidth(view.image) == 24 }

            await firstLoader.release()
            try await testSleep(.milliseconds(10))
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
            try await waitUntilOnMainActor("平台图片视图状态收敛") { view.image != nil }
            view.setImage(
                request: request,
                loader: loader,
                accessibility: .decorative,
                placeholderDelayNanoseconds: 0
            )
            try await testSleep(.milliseconds(10))
            let countAfterNoOp = await loader.requestCount
            XCTAssertEqual(countAfterNoOp, 1)

            view.setImage(
                request: request,
                loader: loader,
                accessibility: .decorative,
                placeholderDelayNanoseconds: 0,
                forceReload: true
            )
            try await waitUntilOnMainActor("平台图片视图状态收敛") { await loader.requestCount == 2 }
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

            try await waitUntilOnMainActor("平台图片视图状态收敛") { weakView == nil }
            try await waitUntilOnMainActor("平台图片视图状态收敛") { await loader.wasCancelled }
        }

        func testAppKitAccessibilityMustBeExplicit_UI_PT_015() async throws {
            let view = FoveaAppKit.FoveaImageView()
            let loader = PlatformCountingImageLoader(image: try platformDecodedImage(width: 10))
            let labeledRequest = try platformRequest(
                path: "appkit-accessibility-label.png", width: 10)

            view.setImage(
                request: labeledRequest,
                loader: loader,
                accessibility: .label("用户头像"),
                placeholderDelayNanoseconds: 0
            )
            try await waitUntilOnMainActor("平台图片视图状态收敛") { view.image != nil }
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
                request: try platformRequest(
                    path: "appkit-accessibility-decorative.png", width: 10),
                loader: loader,
                accessibility: .decorative,
                placeholderDelayNanoseconds: 0
            )
            try await waitUntilOnMainActor("平台图片视图状态收敛") { view.image != nil }
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
            try await waitUntilOnMainActor("平台图片视图状态收敛") { view.image != nil }

            let image = try XCTUnwrap(view.image)
            let scale = max(
                1, view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
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
            try await waitUntilOnMainActor("平台图片视图状态收敛") { view.image != nil }

            view.prepareForReuse()

            XCTAssertNil(view.image)
        }

        func testCompletedAppKitImageDoesNotReloadOnWindowReattach_H005_PT_001() async throws {
            let loader = PlatformCountingImageLoader(image: try platformDecodedImage(width: 22))
            let completion = PlatformCompletionRecorder()
            let window = makePlatformTestWindow()
            let view = FoveaAppKit.FoveaImageView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
            window.contentView?.addSubview(view)
            XCTAssertNotNil(view.window)

            view.setImage(
                request: try platformRequest(path: "appkit-reattach-success.png", width: 22),
                loader: loader,
                accessibility: .decorative,
                placeholderDelayNanoseconds: 0,
                completion: { result in completion.record(result) }
            )
            try await waitUntilOnMainActor("初次成功图片") {
                appKitPixelWidth(view.image) == 22 && completion.count == 1
            }
            let initialRequestCount = await loader.requestCount
            XCTAssertEqual(initialRequestCount, 1)

            view.removeFromSuperview()
            XCTAssertNil(view.window)
            XCTAssertEqual(appKitPixelWidth(view.image), 22)

            window.contentView?.addSubview(view)
            try await testSleep(.milliseconds(20))
            let reattachedRequestCount = await loader.requestCount
            XCTAssertEqual(reattachedRequestCount, 1, "已完成图片窗口切换不应隐藏重下载")
            XCTAssertEqual(appKitPixelWidth(view.image), 22)
            XCTAssertEqual(completion.count, 1, "窗口恢复不能重复调用原 setImage completion")

            view.cancelImageRequest(clearImage: true)
        }

        func testInFlightAppKitDetachRestartsWithoutDuplicateCompletion_H005_PT_002() async throws {
            let loader = PlatformDetachRecoveryLoader(image: try platformDecodedImage(width: 26))
            let completion = PlatformCompletionRecorder()
            let window = makePlatformTestWindow()
            let view = FoveaAppKit.FoveaImageView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
            window.contentView?.addSubview(view)

            view.setImage(
                request: try platformRequest(path: "appkit-reattach-inflight.png", width: 26),
                loader: loader,
                accessibility: .decorative,
                placeholderDelayNanoseconds: 0,
                completion: { result in completion.record(result) }
            )
            await loader.waitUntilFirstRequestStarted()

            view.removeFromSuperview()
            try await waitUntilOnMainActor("detach 取消首个订阅") {
                await loader.cancellationCount == 1
            }
            XCTAssertEqual(completion.count, 0)

            window.contentView?.addSubview(view)
            try await waitUntilOnMainActor("reattach 恢复进行中静态图") {
                await loader.requestCount == 2 && appKitPixelWidth(view.image) == 26
            }
            XCTAssertEqual(completion.count, 1)

            view.cancelImageRequest(clearImage: true)
        }

        func testExplicitAppKitCancelDoesNotRestartOnReattach_H005_PT_003() async throws {
            let loader = PlatformDetachRecoveryLoader(image: try platformDecodedImage(width: 28))
            let window = makePlatformTestWindow()
            let view = FoveaAppKit.FoveaImageView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
            window.contentView?.addSubview(view)

            view.setImage(
                request: try platformRequest(path: "appkit-explicit-cancel.png", width: 28),
                loader: loader,
                accessibility: .decorative,
                placeholderDelayNanoseconds: 0
            )
            await loader.waitUntilFirstRequestStarted()
            view.cancelImageRequest(clearImage: true)
            try await waitUntilOnMainActor("显式取消首个订阅") {
                await loader.cancellationCount == 1
            }

            view.removeFromSuperview()
            window.contentView?.addSubview(view)
            try await testSleep(.milliseconds(20))
            let requestCount = await loader.requestCount
            XCTAssertEqual(requestCount, 1, "显式取消不能被窗口 reattach 复活")
            XCTAssertNil(view.image)
        }

        func testLoaderCancellationAllowsExplicitSameIdentityRetry_H005_PT_004() async throws {
            let loader = PlatformTransientCancellationLoader(
                image: try platformDecodedImage(width: 30)
            )
            let request = try platformRequest(path: "appkit-loader-cancel-retry.png", width: 30)
            let view = FoveaAppKit.FoveaImageView()

            view.setImage(
                request: request,
                loader: loader,
                accessibility: .decorative,
                placeholderDelayNanoseconds: 0
            )
            try await waitUntilOnMainActor("loader 首次取消") {
                let requestCount = await loader.requestCount
                let firstCancellationReturned = await loader.firstCancellationReturned
                return requestCount == 1 && firstCancellationReturned
            }
            try await testSleep(.milliseconds(10))

            view.setImage(
                request: request,
                loader: loader,
                accessibility: .decorative,
                placeholderDelayNanoseconds: 0
            )
            try await waitUntilOnMainActor("同 identity 显式重试") {
                await loader.requestCount == 2 && appKitPixelWidth(view.image) == 30
            }
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
            try await testSleep(.seconds(60))
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

private actor PlatformTransientCancellationLoader: ImageLoading {
    private let image: DecodedImage
    private(set) var requestCount = 0
    private(set) var firstCancellationReturned = false

    init(image: DecodedImage) {
        self.image = image
    }

    func image(for request: ImageRequest) async throws -> DecodedImage {
        requestCount += 1
        if requestCount == 1 {
            firstCancellationReturned = true
            throw CancellationError()
        }
        return image
    }
}

private actor PlatformDetachRecoveryLoader: ImageLoading {
    private let image: DecodedImage
    private(set) var requestCount = 0
    private(set) var cancellationCount = 0
    private var firstRequestStarted = false
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []

    init(image: DecodedImage) {
        self.image = image
    }

    func image(for request: ImageRequest) async throws -> DecodedImage {
        requestCount += 1
        if requestCount == 1 {
            firstRequestStarted = true
            for waiter in firstRequestWaiters { waiter.resume() }
            firstRequestWaiters.removeAll()
            do {
                try await testSleep(.seconds(60))
            } catch is CancellationError {
                cancellationCount += 1
                throw CancellationError()
            }
        }
        return image
    }

    func waitUntilFirstRequestStarted() async {
        if firstRequestStarted { return }
        await withCheckedContinuation { firstRequestWaiters.append($0) }
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
    @MainActor
    private final class PlatformCompletionRecorder {
        private(set) var count = 0

        func record(_ result: Result<DecodedImage, PipelineFailure>) {
            count += 1
        }
    }

    @MainActor
    private func makePlatformTestWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    private func appKitPixelWidth(_ image: NSImage?) -> Int? {
        image?.representations.compactMap { representation in
            representation.pixelsWide > 0 ? representation.pixelsWide : nil
        }.max()
    }
#endif

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
