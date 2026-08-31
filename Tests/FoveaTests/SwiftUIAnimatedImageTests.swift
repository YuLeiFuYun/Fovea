import CoreGraphics
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaSwiftUI
import ImageCraftCore
import XCTest

@MainActor
final class SwiftUIAnimatedImageTests: XCTestCase {
    func testVisibilitySequencerWaitsForCancelledPriorEffect_T00() async {
        let sequencer = FoveaSwiftUIVisibilitySequencer()
        let probe = SwiftUIVisibilityOrderingProbe()
        sequencer.submit { await probe.apply(false) }
        await probe.waitUntilFirstStarted()
        sequencer.submit { await probe.apply(true) }
        for _ in 0..<20 { await Task.yield() }
        let beforeRelease = await probe.values()
        XCTAssertEqual(beforeRelease, [])
        await probe.releaseFirst()
        await sequencer.waitUntilDrainedForTesting()
        let afterRelease = await probe.values()
        XCTAssertEqual(afterRelease, [false, true])
        sequencer.cancel()
    }

    func testSwiftUIModelDefersLiveDecodeUntilVisibleAndShowsLatest_W5_PT_107()
        async throws
    {
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 16 * 1024)
        let source = SwiftUILiveSource()
        let decoder = SwiftUIImmediateLiveDecoder()
        let session = MultipartJPEGLivePlaybackSession(
            stream: source.stream,
            decoder: decoder,
            policy: MultipartJPEGLivePlaybackPolicy(
                minimumFrameIntervalNanoseconds: 1
            ),
            clock: SwiftUIImmediateClock()
        )
        let handle = try await runtime.registerLiveSession(session)
        let model = FoveaAnimatedImageModel()
        model.present(
            FoveaAnimatedImagePresentation(liveHandle: handle),
            initiallyVisible: false
        )
        source.yield(swiftUILivePart(index: 0))
        source.yield(swiftUILivePart(index: 1))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(model.imageForTesting)
        let hiddenDecodes = await decoder.indices()
        XCTAssertEqual(hiddenDecodes, [])

        model.setVisible(true)
        try await waitUntil("SwiftUI live presentation publishes latest frame") {
            model.imageForTesting?.pixelWidth == 3
        }
        let visibleDecodes = await decoder.indices()
        XCTAssertEqual(visibleDecodes, [1])

        model.cancel(clearImage: true)
        try await waitUntil("SwiftUI live presentation unregisters") {
            await runtime.registeredLiveSessionCount() == 0
        }
        XCTAssertNil(model.imageForTesting)
    }

    func testSwiftUIModelReplacementRejectsLateOldLiveFrame_W5_PT_108() async throws {
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 16 * 1024)
        let firstSource = SwiftUILiveSource()
        let firstDecoder = SwiftUIGatedLiveDecoder()
        let firstSession = MultipartJPEGLivePlaybackSession(
            stream: firstSource.stream,
            decoder: firstDecoder,
            policy: MultipartJPEGLivePlaybackPolicy(
                minimumFrameIntervalNanoseconds: 1
            ),
            clock: SwiftUIImmediateClock()
        )
        let firstHandle = try await runtime.registerLiveSession(firstSession)
        let model = FoveaAnimatedImageModel()
        model.present(
            FoveaAnimatedImagePresentation(liveHandle: firstHandle),
            initiallyVisible: true
        )
        firstSource.yield(swiftUILivePart(index: 0))
        await firstDecoder.waitUntilStarted()

        let secondSource = SwiftUILiveSource()
        let secondSession = MultipartJPEGLivePlaybackSession(
            stream: secondSource.stream,
            decoder: SwiftUIImmediateLiveDecoder(),
            policy: MultipartJPEGLivePlaybackPolicy(
                minimumFrameIntervalNanoseconds: 1
            ),
            clock: SwiftUIImmediateClock()
        )
        let secondHandle = try await runtime.registerLiveSession(secondSession)
        model.present(
            FoveaAnimatedImagePresentation(liveHandle: secondHandle),
            initiallyVisible: true
        )
        secondSource.yield(swiftUILivePart(index: 2))
        try await waitUntil("SwiftUI replacement publishes new frame") {
            model.imageForTesting?.pixelWidth == 4
        }

        await firstDecoder.release()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(model.imageForTesting?.pixelWidth, 4)
        let registrations = await runtime.registeredLiveSessionCount()
        XCTAssertEqual(registrations, 1)
        model.cancel(clearImage: true)
        await runtime.cancelAll()
    }

    func testSwiftUIModelPresentsStaticAnimationHandleAndCancels_W5_PT_109() async throws {
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 16 * 1024)
        let image = swiftUIImage(width: 5)
        let provider = SwiftUIStaticAnimationProvider(image: image)
        let handle = try await runtime.makeHandle(
            namespace: SecurityNamespaceID("swiftui-animation"),
            generation: NamespaceGeneration(0),
            decodeKey: try XCTUnwrap(
                AnimationDecodeKey(
                    contentID: ContentID(data: Data("swiftui-animation".utf8)),
                    target: TargetPixels(width: 8, height: 8),
                    contentMode: .fit,
                    colorPolicy: .convertToSRGB,
                    codecFingerprint: "swiftui-test-v1",
                    animationPolicyVersion: 1,
                    timingPolicyVersion: 1,
                    frameStrategy: .boundedFrameCache
                )
            ),
            timeline: try AnimationPlaybackTimeline(
                frameDurationsNanoseconds: [10, 10],
                additionalRepeatCount: nil,
                zeroDurationReplacementNanoseconds: 1,
                timingPolicyVersion: 1
            ),
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .firstFrame),
            reduceMotionEnabled: false,
            provider: provider,
            windowPolicy: AnimationFrameWindowPolicy(
                normalFrameCount: 2,
                warningFrameCount: 1
            ),
            clock: SwiftUIImmediateClock()
        )
        let model = FoveaAnimatedImageModel()
        model.present(
            FoveaAnimatedImagePresentation(animationHandle: handle),
            initiallyVisible: true
        )
        try await waitUntil("SwiftUI static animation handle publishes") {
            model.imageForTesting?.pixelWidth == 5
        }
        let providerCalls = await provider.callCount()
        XCTAssertEqual(providerCalls, 1)

        model.cancel(clearImage: true)
        try await waitUntil("SwiftUI static animation unregisters") {
            await runtime.registeredDriverCount() == 0
        }
        XCTAssertNil(model.imageForTesting)
        let providerCancels = await provider.cancelCount()
        XCTAssertEqual(providerCancels, 1)
    }
}

extension FoveaAnimatedImageModel {
    fileprivate var imageForTesting: DecodedImage? {
        guard case .image(let image) = phase else { return nil }
        return image
    }
}

private struct SwiftUILiveSource: Sendable {
    let stream: AsyncThrowingStream<MultipartJPEGPart, any Error>
    private let continuation: AsyncThrowingStream<MultipartJPEGPart, any Error>.Continuation

    init() {
        let pair = AsyncThrowingStream<MultipartJPEGPart, any Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func yield(_ part: MultipartJPEGPart) { continuation.yield(part) }
}

private actor SwiftUIImmediateLiveDecoder: MultipartJPEGFrameDecoding {
    private var decoded: [Int] = []
    func decode(_ part: MultipartJPEGPart) -> DecodedImage {
        decoded.append(part.index)
        return swiftUIImage(width: part.index + 2)
    }
    func indices() -> [Int] { decoded }
}

private actor SwiftUIGatedLiveDecoder: MultipartJPEGFrameDecoding {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func decode(_ part: MultipartJPEGPart) async -> DecodedImage {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll(keepingCapacity: false)
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return swiftUIImage(width: part.index + 2)
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll(keepingCapacity: false)
    }
}

private actor SwiftUIStaticAnimationProvider: AnimationFrameProvider {
    private let image: DecodedImage
    private var calls = 0
    private var cancels = 0

    init(image: DecodedImage) { self.image = image }

    func frames(in range: Range<Int>) -> [AnimationProviderFrame] {
        calls += 1
        return range.map { AnimationProviderFrame(index: $0, image: image) }
    }

    func cancel() { cancels += 1 }
    func callCount() -> Int { calls }
    func cancelCount() -> Int { cancels }
}

private actor SwiftUIImmediateClock: AnimationPlaybackClock {
    private var value: UInt64 = 0
    func nowNanoseconds() -> UInt64 { value }
    func sleep(untilNanoseconds deadline: UInt64) throws {
        try Task.checkCancellation()
        value = max(value, deadline)
    }
}

private func swiftUILivePart(index: Int) -> MultipartJPEGPart {
    MultipartJPEGPart(
        index: index,
        data: Data([0xff, 0xd8, UInt8(index & 0xff), 0xff, 0xd9])
    )
}

private func swiftUIImage(width: Int) -> DecodedImage {
    let height = 2
    let bytesPerRow = width * 4
    let data = Data(repeating: UInt8(width & 0xff), count: bytesPerRow * height)
    let provider = CGDataProvider(data: data as CFData)!
    let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
    return DecodedImage(cgImage: image)
}

private actor SwiftUIVisibilityOrderingProbe {
    private var firstStarted = false
    private var firstReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var applied: [Bool] = []
    func apply(_ visible: Bool) async {
        if !firstStarted {
            firstStarted = true
            for waiter in startWaiters { waiter.resume() }
            startWaiters.removeAll(keepingCapacity: false)
            if !firstReleased { await withCheckedContinuation { releaseWaiters.append($0) } }
        }
        applied.append(visible)
    }
    func waitUntilFirstStarted() async {
        if firstStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func releaseFirst() {
        firstReleased = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll(keepingCapacity: false)
    }
    func values() -> [Bool] { applied }
}
