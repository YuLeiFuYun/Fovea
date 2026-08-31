import CoreGraphics
import Foundation
import FoveaCore
import FoveaSystem
import ImageCraftCore
import XCTest

#if canImport(AppKit)
    import AppKit
#endif

final class AnimationSystemIntegrationTests: XCTestCase {
    func
        testSystemCreatesZeroResidentAnimationRuntimeWithoutChangingDisabledPressureContract_W5_PT_064()
        async throws
    {
        let system = try await FoveaSystemPipeline.open(
            cacheRoot: try makeTemporaryDirectory("animation-system-empty"),
            configuration: PipelineConfiguration(memoryCostLimit: 4 * 1024 * 1024),
            automaticallyPurgesMemoryOnPressure: false
        )

        let frameCount = await system.animationRuntime.currentFrameCount()
        let frameCost = await system.animationRuntime.currentFrameMemoryCost()
        let driverCount = await system.animationRuntime.registeredDriverCount()
        let legacyRemovalCount = await system.simulateMemoryPressureForTesting()
        XCTAssertEqual(frameCount, 0)
        XCTAssertEqual(frameCost, 0)
        XCTAssertEqual(driverCount, 0)
        XCTAssertEqual(legacyRemovalCount, 0)
        await system.invalidateAndCancel()
    }

    func testSystemLifecycleNotificationFreezesNewAnimationUntilActive_W5_PT_065()
        async throws
    {
        let system = try await FoveaSystemPipeline.open(
            cacheRoot: try makeTemporaryDirectory("animation-system-lifecycle"),
            automaticallyPurgesMemoryOnPressure: false
        )
        #if canImport(AppKit)
            NotificationCenter.default.post(
                name: NSApplication.didResignActiveNotification,
                object: nil
            )
            try await waitUntil("system animation runtime observes resign-active") {
                !(await system.animationRuntime.applicationIsActiveForTesting())
            }
        #else
            await system.simulateApplicationActiveForTesting(false)
        #endif

        let provider = SystemAnimationProvider(image: makeSystemAnimationImage())
        let recorder = SystemAnimationRecorder()
        let handle = try await makeSystemHandle(
            system: system,
            provider: provider,
            label: "lifecycle"
        )
        try await system.animationRuntime.start(handle) { output in
            await recorder.record(output)
        }
        for _ in 0..<20 { await Task.yield() }
        let inactiveCalls = await provider.callCount()
        let inactiveOutputs = await recorder.count()
        XCTAssertEqual(inactiveCalls, 0)
        XCTAssertEqual(inactiveOutputs, 0)

        #if canImport(AppKit)
            NotificationCenter.default.post(
                name: NSApplication.didBecomeActiveNotification,
                object: nil
            )
            try await waitUntil("system animation runtime observes become-active") {
                await system.animationRuntime.applicationIsActiveForTesting()
            }
        #else
            await system.simulateApplicationActiveForTesting(true)
        #endif
        try await waitUntil("system animation produces first active frame") {
            await recorder.count() == 1
        }
        let activeCalls = await provider.callCount()
        XCTAssertEqual(activeCalls, 1)
        await system.invalidateAndCancel()
    }

    func testSystemCriticalPressurePurgesAndNormalRecoversAnimation_W5_PT_066()
        async throws
    {
        let system = try await FoveaSystemPipeline.open(
            cacheRoot: try makeTemporaryDirectory("animation-system-pressure")
        )
        let provider = SystemAnimationProvider(image: makeSystemAnimationImage())
        let recorder = SystemAnimationRecorder()
        let handle = try await makeSystemHandle(
            system: system,
            provider: provider,
            label: "pressure"
        )
        try await system.animationRuntime.start(handle) { output in
            await recorder.record(output)
        }
        try await waitUntil("system animation frame resident") {
            await system.animationRuntime.currentFrameCount() == 1
        }

        let critical = await system.simulateAnimationPressureForTesting(.critical)
        let criticalState = await system.animationRuntime.memoryPressureForTesting()
        let purgedCount = await system.animationRuntime.currentFrameCount()
        XCTAssertEqual(critical.animation.registeredDriverCount, 1)
        XCTAssertEqual(critical.animation.affectedDriverCount, 1)
        XCTAssertEqual(critical.animation.failedDriverCount, 0)
        XCTAssertEqual(critical.animation.removedFrames.itemCount, 1)
        XCTAssertEqual(criticalState, .critical)
        XCTAssertEqual(purgedCount, 0)

        let normal = await system.simulateAnimationPressureForTesting(.normal)
        XCTAssertEqual(normal.renderedRemovalCount, 0)
        try await waitUntil("system animation recovers after normal pressure") {
            await system.animationRuntime.currentFrameCount() == 1
        }
        let providerCalls = await provider.callCount()
        XCTAssertEqual(providerCalls, 2)
        await system.invalidateAndCancel()
    }

    func testSystemInvalidationCancelsAllAnimationDrivers_W5_PT_067() async throws {
        let system = try await FoveaSystemPipeline.open(
            cacheRoot: try makeTemporaryDirectory("animation-system-invalidate")
        )
        let provider = SystemAnimationProvider(image: makeSystemAnimationImage())
        let handle = try await makeSystemHandle(
            system: system,
            provider: provider,
            label: "invalidate"
        )
        try await system.animationRuntime.start(handle) { _ in }
        try await waitUntil("system animation starts before invalidation") {
            await provider.callCount() == 1
        }

        await system.invalidateAndCancel()
        await system.invalidateAndCancel()
        let driverCount = await system.animationRuntime.registeredDriverCount()
        let frameCount = await system.animationRuntime.currentFrameCount()
        let cancelCount = await provider.cancelCount()
        XCTAssertEqual(driverCount, 0)
        XCTAssertEqual(frameCount, 0)
        XCTAssertEqual(cancelCount, 1)
    }

    private func makeSystemHandle(
        system: FoveaSystemPipeline,
        provider: SystemAnimationProvider,
        label: String
    ) async throws -> AnimationPlaybackHandle {
        let decodeKey = try XCTUnwrap(
            AnimationDecodeKey(
                contentID: ContentID(data: Data("system-\(label)".utf8)),
                target: TargetPixels(width: 16, height: 16),
                contentMode: .fit,
                colorPolicy: .convertToSRGB,
                codecFingerprint: "system-animation-provider-v1",
                animationPolicyVersion: 1,
                timingPolicyVersion: 1,
                frameStrategy: .boundedFrameCache
            )
        )
        let timeline = try AnimationPlaybackTimeline(
            frameDurationsNanoseconds: [10],
            additionalRepeatCount: nil,
            zeroDurationReplacementNanoseconds: 1,
            timingPolicyVersion: 1
        )
        return try await system.animationRuntime.makeHandle(
            namespace: SecurityNamespaceID("system-animation-account"),
            generation: NamespaceGeneration(1),
            decodeKey: decodeKey,
            timeline: timeline,
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .firstFrame),
            reduceMotionEnabled: false,
            provider: provider,
            windowPolicy: AnimationFrameWindowPolicy(
                normalFrameCount: 1,
                warningFrameCount: 1
            ),
            clock: SystemAnimationConstantClock()
        )
    }
}

private struct SystemAnimationConstantClock: AnimationPlaybackClock {
    func nowNanoseconds() async -> UInt64 { 0 }
    func sleep(untilNanoseconds _: UInt64) async throws { throw CancellationError() }
}

private actor SystemAnimationProvider: AnimationFrameProvider {
    private let image: DecodedImage
    private var calls = 0
    private var cancellations = 0

    init(image: DecodedImage) {
        self.image = image
    }

    func frames(in range: Range<Int>) -> [AnimationProviderFrame] {
        calls += 1
        return range.map { AnimationProviderFrame(index: $0, image: image) }
    }

    func cancel() {
        cancellations += 1
    }

    func callCount() -> Int { calls }
    func cancelCount() -> Int { cancellations }
}

private actor SystemAnimationRecorder {
    private var outputs: [AnimationPlaybackOutput] = []

    func record(_ output: AnimationPlaybackOutput) {
        outputs.append(output)
    }

    func count() -> Int { outputs.count }
}

private func makeSystemAnimationImage() -> DecodedImage {
    let width = 4
    let height = 4
    let bytesPerRow = width * 4
    let data = Data(repeating: 0x2f, count: bytesPerRow * height)
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
