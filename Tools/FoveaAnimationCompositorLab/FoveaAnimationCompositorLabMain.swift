import AppKit
import Foundation
import FoveaAppKit
import FoveaCore
import ImageCraftCore

private struct ProducerReport: Codable {
    let mode: String
    let playbackStartNanoseconds: UInt64
    let providerWindowCalls: Int
    let providerFrameCount: Int
    let providerCancelCountAfterCancel: Int
    let registeredDriverCountAfterCancel: Int
    let presentationTargetAcceptedCount: UInt64?
    let presentationTargetConsumedCount: UInt64?
    let compositorPresentationActiveDuringRun: Bool
    let compositorLayerAttachedDuringRun: Bool
    let compositorPresentationFrameIndexDuringRun: Int?
    let compositorAnimationBeginTimeDuringRun: Double?
    let compositorLayerCurrentTimeDuringRun: Double?
    let displayMaximumFramesPerSecond: Int
    let displayBackingScaleFactor: Double
    let checks: [String: Bool]
}

private actor BitProvider: AnimationFrameProvider {
    private var windowCalls = 0
    private var decodedFrames = 0
    private var cancellations = 0

    func frames(in range: Range<Int>) throws -> [AnimationProviderFrame] {
        guard range.lowerBound >= 0, range.upperBound <= 60 else {
            throw AnimationPlaybackCoordinatorError.providerResultMismatch
        }
        windowCalls += 1
        decodedFrames += range.count
        return range.map { index in
            AnimationProviderFrame(index: index, image: makeBitFrame(index: index))
        }
    }

    func cancel() { cancellations += 1 }

    func snapshot() -> (windowCalls: Int, decodedFrames: Int, cancellations: Int) {
        (windowCalls, decodedFrames, cancellations)
    }
}

@main
private enum FoveaAnimationCompositorLab {
    @MainActor
    static func main() async throws {
        throw NSError(
            domain: "FoveaAnimationCompositorLab",
            code: 78,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "desktop-visible compositor lab disabled: automated experiments must not present test UI"
            ]
        )
        guard #available(macOS 14.0, *), CommandLine.arguments.count == 5 else {
            throw NSError(domain: "FoveaAnimationCompositorLab", code: 1)
        }
        let readyURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let goURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let startURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let reportURL = URL(fileURLWithPath: CommandLine.arguments[4])
        guard let screen = NSScreen.main else {
            throw NSError(domain: "FoveaAnimationCompositorLab", code: 2)
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()

        let frameDurations: [UInt64] = (0..<60).map { index in
            switch index % 6 {
            case 0: 20_000_000
            case 1: 30_000_000
            case 2: 50_000_000
            case 3: 80_000_000
            case 4: 120_000_000
            default: 200_000_000
            }
        }
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 512 * 1024)
        let provider = BitProvider()
        let decodeKey = AnimationDecodeKey(
            contentID: ContentID(data: Data("fovea-compositor-screen-oracle".utf8)),
            target: try TargetPixels(width: 32, height: 32),
            contentMode: .fit,
            colorPolicy: .convertToSRGB,
            codecFingerprint: "fovea-compositor-screen-oracle-v2",
            animationPolicyVersion: 1,
            timingPolicyVersion: 1,
            frameStrategy: .predecodeAll
        )!
        let timeline = try AnimationPlaybackTimeline(
            frameDurationsNanoseconds: frameDurations,
            additionalRepeatCount: nil,
            zeroDurationReplacementNanoseconds: 10_000_000,
            timingPolicyVersion: 1
        )
        let handle = try await runtime.makeHandle(
            namespace: SecurityNamespaceID("fovea-compositor-screen-oracle"),
            generation: NamespaceGeneration(1),
            decodeKey: decodeKey,
            timeline: timeline,
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
            reduceMotionEnabled: false,
            provider: provider,
            windowPolicy: AnimationFrameWindowPolicy(normalFrameCount: 4, warningFrameCount: 2),
            maximumPredecodeAllFrameCount: 60
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 3)
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.alphaValue = 1
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 160))
        let imageView = FoveaImageView(frame: NSRect(x: 16, y: 16, width: 128, height: 128))
        content.addSubview(imageView)
        window.contentView = content
        window.center()
        window.orderFrontRegardless()
        defer {
            imageView.cancelAnimation(clearImage: true)
            window.orderOut(nil)
            window.close()
        }

        try FileManager.default.createDirectory(
            at: readyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let readyPayload =
            "pid=\(ProcessInfo.processInfo.processIdentifier) window=\(window.windowNumber)\n"
        try Data(readyPayload.utf8).write(to: readyURL, options: .atomic)

        var goObserved = false
        for _ in 0..<1_000 {
            if FileManager.default.fileExists(atPath: goURL.path) {
                goObserved = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard goObserved else {
            throw NSError(domain: "FoveaAnimationCompositorLab", code: 3)
        }

        imageView.setAnimation(
            handle: handle,
            runtime: runtime,
            accessibility: .decorative,
            schedulingControl: .platformDefault
        )
        var playbackStart: UInt64?
        for _ in 0..<200 {
            if let start = await handle.driver.playbackStartNanosecondsForTesting() {
                playbackStart = start
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let playbackStart else {
            throw NSError(domain: "FoveaAnimationCompositorLab", code: 4)
        }
        try Data("\(playbackStart)\n".utf8).write(to: startURL, options: .atomic)

        // observer 在 6.1 秒停止；继续保留 presentation 一小段时间，为 teardown 留出额外余量。
        try await Task.sleep(nanoseconds: 6_600_000_000)
        let diagnostics = imageView.animationPresentationDiagnostics
        let compositorActive = imageView.animationCompositorPresentationActiveForTesting == true
        let compositorAttached = imageView.animationCompositorLayerAttachedForTesting == true
        let compositorFrameIndex = imageView.animationCompositorPresentationFrameIndexForTesting
        let compositorBeginTime = imageView.animationCompositorAnimationBeginTimeForTesting
        let compositorCurrentTime = imageView.animationCompositorLayerCurrentTimeForTesting
        let providerBeforeCancel = await provider.snapshot()

        imageView.cancelAnimation(clearImage: true)
        for _ in 0..<200 {
            if await runtime.registeredDriverCount() == 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let providerAfterCancel = await provider.snapshot()
        let registeredAfterCancel = await runtime.registeredDriverCount()
        let compositorRequested =
            ProcessInfo.processInfo.environment["FOVEA_APPKIT_COMPOSITOR_PREDECODE"] == "1"
        let report = ProducerReport(
            mode: compositorRequested ? "compositor" : "streaming-predecode",
            playbackStartNanoseconds: playbackStart,
            providerWindowCalls: providerBeforeCancel.windowCalls,
            providerFrameCount: providerBeforeCancel.decodedFrames,
            providerCancelCountAfterCancel: providerAfterCancel.cancellations,
            registeredDriverCountAfterCancel: registeredAfterCancel,
            presentationTargetAcceptedCount: diagnostics?.acceptedTargetCount,
            presentationTargetConsumedCount: diagnostics?.consumedTargetCount,
            compositorPresentationActiveDuringRun: compositorActive,
            compositorLayerAttachedDuringRun: compositorAttached,
            compositorPresentationFrameIndexDuringRun: compositorFrameIndex,
            compositorAnimationBeginTimeDuringRun: compositorBeginTime,
            compositorLayerCurrentTimeDuringRun: compositorCurrentTime,
            displayMaximumFramesPerSecond: screen.maximumFramesPerSecond,
            displayBackingScaleFactor: Double(screen.backingScaleFactor),
            checks: [
                "predecode-provider-complete": providerBeforeCancel.windowCalls == 1
                    && providerBeforeCancel.decodedFrames == 60,
                "cancel-unregistered-driver": registeredAfterCancel == 0,
                "compositor-state-matches-request": compositorActive == compositorRequested,
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        print(reportURL.path)
    }
}

private func makeBitFrame(index: Int) -> DecodedImage {
    let width = 32
    let height = 32
    let bytesPerRow = width * 4
    var data = Data(count: bytesPerRow * height)
    data.withUnsafeMutableBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        for y in 0..<height {
            for x in 0..<width {
                let bit = min(5, x * 6 / width)
                let value: UInt8 = (index & (1 << bit)) != 0 ? 255 : 0
                let offset = y * bytesPerRow + x * 4
                base[offset] = value
                base[offset + 1] = value
                base[offset + 2] = value
                base[offset + 3] = 255
            }
        }
    }
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
