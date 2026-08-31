import AppKit
import CoreGraphics
import Dispatch
import Foundation
import FoveaAppKit
import FoveaCore
import ImageCraftCore

@main
@MainActor
private enum FoveaAnimationMacLab {
    static func main() async throws {
        let options = try Options(CommandLine.arguments)
        guard #available(macOS 14.0, *) else { throw MacLabError.requiresMacOS14 }
        guard let screen = NSScreen.main else { throw MacLabError.displayUnavailable }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let playback = try await PlaybackFixture.make(options: options)
        let window = WindowFixture(options: options, screen: screen)
        defer { window.close() }
        switch options.experiment {
        case .mechanism:
            try await runMechanism(options: options, screen: screen, window: window, playback: playback)
        case .callbackTiming:
            try await runCallbackTiming(options: options, screen: screen, window: window, playback: playback)
        case .refreshTiming:
            try await runRefreshTiming(options: options, screen: screen, window: window, playback: playback)
        case .resourceProxy:
            try await runResourceProxy(options: options, screen: screen, window: window, playback: playback)
        }
    }
}

@MainActor
private func runMechanism(
    options: Options,
    screen: NSScreen,
    window: WindowFixture,
    playback: PlaybackFixture
) async throws {
    window.imageView.setAnimation(
        handle: playback.handle,
        runtime: playback.runtime,
        accessibility: .decorative
    )
    try await waitForActive(view: window.imageView, provider: playback.provider)
    let active = try await stageSnapshot(view: window.imageView, provider: playback.provider)
    guard active.presentation.acceptedTargetCount > 0,
        active.presentation.consumedTargetCount > 0,
        !active.presentation.isDisplayLinkPaused,
        active.presentation.effectiveVisibility == true
    else { throw MacLabError.activeDisplayLinkDidNotAdvance }
    let hidden = try await captureHidden(view: window.imageView, provider: playback.provider)
    let resumed = try await captureResumed(
        view: window.imageView,
        provider: playback.provider,
        hiddenEnd: hidden.end
    )
    let cancelled = try await cancelAndSnapshot(
        view: window.imageView,
        runtime: playback.runtime,
        provider: playback.provider
    )
    try writeJSON(
        mechanismReport(
            options: options,
            screen: screen,
            playback: playback,
            active: active,
            hidden: hidden,
            resumed: resumed,
            cancelled: cancelled
        ),
        to: options.output
    )
}

@MainActor
private func waitForActive(
    view: FoveaAppKit.FoveaImageView,
    provider: MacLabProvider
) async throws {
    try await waitUntil(timeoutNanoseconds: 2_000_000_000, error: .activeDisplayLinkDidNotAdvance) {
        guard let diagnostics = view.animationPresentationDiagnostics else { return false }
        let state = await provider.snapshot()
        return diagnostics.acceptedTargetCount >= 8
            && diagnostics.consumedTargetCount >= 4
            && state.decodedFrames >= 4
    }
}

@MainActor
private func captureHidden(
    view: FoveaAppKit.FoveaImageView,
    provider: MacLabProvider
) async throws -> (settled: StageSnapshot, end: StageSnapshot) {
    view.isHidden = true
    try await waitUntil(timeoutNanoseconds: 1_000_000_000, error: .hiddenPauseDidNotEngage) {
        view.animationPresentationDiagnostics?.isDisplayLinkPaused == true
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    let settled = try await stageSnapshot(view: view, provider: provider)
    try await Task.sleep(nanoseconds: 350_000_000)
    let end = try await stageSnapshot(view: view, provider: provider)
    guard end.presentation.acceptedTargetCount == settled.presentation.acceptedTargetCount else {
        throw MacLabError.hiddenDisplayLinkAdvanced
    }
    guard end.providerFrameCount == settled.providerFrameCount else {
        throw MacLabError.hiddenProviderAdvanced
    }
    return (settled, end)
}

@MainActor
private func captureResumed(
    view: FoveaAppKit.FoveaImageView,
    provider: MacLabProvider,
    hiddenEnd: StageSnapshot
) async throws -> StageSnapshot {
    view.isHidden = false
    try await waitUntil(timeoutNanoseconds: 2_000_000_000, error: .resumeDidNotAdvance) {
        guard let diagnostics = view.animationPresentationDiagnostics else { return false }
        let state = await provider.snapshot()
        return diagnostics.acceptedTargetCount >= hiddenEnd.presentation.acceptedTargetCount + 8
            && state.decodedFrames > hiddenEnd.providerFrameCount
    }
    let resumed = try await stageSnapshot(view: view, provider: provider)
    guard resumed.presentation.acceptedTargetCount > hiddenEnd.presentation.acceptedTargetCount,
        resumed.providerFrameCount > hiddenEnd.providerFrameCount,
        !resumed.presentation.isDisplayLinkPaused,
        resumed.presentation.effectiveVisibility == true
    else { throw MacLabError.resumeDidNotAdvance }
    return resumed
}

@MainActor
private func runCallbackTiming(
    options: Options,
    screen: NSScreen,
    window: WindowFixture,
    playback: PlaybackFixture
) async throws {
    let recorder = CallbackTimingRecorder(frameCount: playback.frameCount)
    window.imageView.animationBenchmarkPresentationHandler = {
        recorder.record(frameIndex: $0, timestamp: $1)
    }
    startMeasuredAnimation(options: options, window: window, playback: playback)
    try await waitUntil(timeoutNanoseconds: 8_000_000_000, error: .callbackTimingDidNotComplete) {
        recorder.observedSourceOrdinal >= UInt64(playback.frameCount)
    }
    let mode = try await verifiedDriverMode(options: options, handle: playback.handle)
    let cancelled = try await cancelAndSnapshot(
        view: window.imageView,
        runtime: playback.runtime,
        provider: playback.provider
    )
    var report = commonTimingReport(
        version: "fovea-appkit-physical-callback-timing-v1",
        boundary: callbackBoundary,
        options: options,
        screen: screen,
        playback: playback,
        mode: mode,
        cancelled: cancelled
    )
    report["observations"] = recorder.observations.map(\.json)
    report["observedSourceOrdinal"] = recorder.observedSourceOrdinal
    report["checks"] = [
        "full-source-ordinal-progression-observed": true,
        "source-frame-skips-preserved-as-measurement": true,
        "expected-driver-mode-active": true,
        "cancel-unregistered-driver": true,
    ]
    try writeJSON(report, to: options.output)
}

@MainActor
private func runRefreshTiming(
    options: Options,
    screen: NSScreen,
    window: WindowFixture,
    playback: PlaybackFixture
) async throws {
    let recorder = RefreshTimingRecorder(frameCount: playback.frameCount)
    window.imageView.animationBenchmarkRefreshSampleHandler = {
        recorder.record(frameIndex: $0, timestamp: $1)
    }
    startMeasuredAnimation(options: options, window: window, playback: playback)
    try await waitUntil(timeoutNanoseconds: 8_000_000_000, error: .callbackTimingDidNotComplete) {
        recorder.observedSourceOrdinal >= UInt64(playback.frameCount)
    }
    let diagnostics = window.imageView.animationPresentationDiagnostics
    let mode = try await verifiedDriverMode(options: options, handle: playback.handle)
    let cancelled = try await cancelAndSnapshot(
        view: window.imageView,
        runtime: playback.runtime,
        provider: playback.provider
    )
    guard let start = await playback.handle.driver.playbackStartNanosecondsForTesting(),
        let first = recorder.firstTimestamp,
        first >= start
    else { throw MacLabError.callbackTimingDidNotComplete }
    var report = commonTimingReport(
        version: "fovea-appkit-physical-refresh-sampled-timing-v1",
        boundary: refreshBoundary,
        options: options,
        screen: screen,
        playback: playback,
        mode: mode,
        cancelled: cancelled
    )
    report["playbackStartNanoseconds"] = start
    report["firstRefreshTimestampNanoseconds"] = first
    report["firstRefreshOffsetFromPlaybackStartNanoseconds"] = first - start
    report["refreshSampleCount"] = recorder.refreshSampleCount
    report["refreshIntervalsNanoseconds"] = recorder.refreshIntervalsNanoseconds
    report["observations"] = recorder.observations.map(\.json)
    report["observedSourceOrdinal"] = recorder.observedSourceOrdinal
    addPresentationCounts(diagnostics, to: &report)
    report["checks"] = [
        "full-source-ordinal-progression-observed": true,
        "source-frame-skips-preserved-as-measurement": true,
        "common-view-display-link-refresh-coordinate": true,
        "expected-driver-mode-active": true,
        "cancel-unregistered-driver": true,
    ]
    try writeJSON(report, to: options.output)
}

@MainActor
private func runResourceProxy(
    options: Options,
    screen: NSScreen,
    window: WindowFixture,
    playback: PlaybackFixture
) async throws {
    startMeasuredAnimation(options: options, window: window, playback: playback)
    try await waitUntil(timeoutNanoseconds: 2_000_000_000, error: .resourceProxyDidNotStart) {
        let started = await playback.handle.driver.playbackStartNanosecondsForTesting() != nil
        let providerState = await playback.provider.snapshot()
        return started && providerState.decodedFrames > 0
    }
    let mode = try await verifiedDriverMode(options: options, handle: playback.handle)
    let thermalBefore = thermalStateName(ProcessInfo.processInfo.thermalState)
    let started = DispatchTime.now().uptimeNanoseconds
    try await Task.sleep(nanoseconds: options.durationNanoseconds)
    let ended = DispatchTime.now().uptimeNanoseconds
    let providerBeforeCancel = await playback.provider.snapshot()
    let diagnostics = window.imageView.animationPresentationDiagnostics
    let cancelled = try await cancelAndSnapshot(
        view: window.imageView,
        runtime: playback.runtime,
        provider: playback.provider
    )
    var report: [String: Any] = [
        "schemaVersion": 1,
        "evidenceVersion": "fovea-appkit-physical-resource-proxy-v1",
        "claimBoundary": resourceBoundary,
        "runtime": runtimeJSON(options: options, screen: screen),
        "schedulingControl": options.schedulingControl.rawValue,
        "deadlineClockControl": options.deadlineClockControl.rawValue,
        "driverSchedulingMode": driverModeName(mode),
        "requestedDurationNanoseconds": options.durationNanoseconds,
        "measuredDurationNanoseconds": ended - started,
        "providerWindowCalls": providerBeforeCancel.windowCalls,
        "providerFrameCount": providerBeforeCancel.decodedFrames,
        "registeredDriverCountAfterCancel": cancelled.registeredDrivers,
        "providerCancelCountAfterCancel": cancelled.provider.cancellations,
        "thermalStateBefore": thermalBefore,
        "thermalStateAfter": thermalStateName(ProcessInfo.processInfo.thermalState),
    ]
    addPresentationCounts(diagnostics, to: &report)
    report["checks"] = [
        "requested-driver-mode-active": true,
        "provider-work-observed": providerBeforeCancel.decodedFrames > 0,
        "cancel-unregistered-driver": true,
        "deadline-control-has-no-display-link": options.schedulingControl != .automaticDeadline
            || diagnostics == nil,
    ]
    try writeJSON(report, to: options.output)
}

@MainActor
private func startMeasuredAnimation(
    options: Options,
    window: WindowFixture,
    playback: PlaybackFixture
) {
    window.imageView.setAnimation(
        handle: playback.handle,
        runtime: playback.runtime,
        accessibility: .decorative,
        schedulingControl: options.schedulingControl.appKitControl
    )
}

private func mechanismReport(
    options: Options,
    screen: NSScreen,
    playback: PlaybackFixture,
    active: StageSnapshot,
    hidden: (settled: StageSnapshot, end: StageSnapshot),
    resumed: StageSnapshot,
    cancelled: CancelledSnapshot
) -> [String: Any] {
    [
        "schemaVersion": 1,
        "evidenceVersion": "fovea-appkit-physical-display-link-mechanism-v1",
        "claimBoundary": mechanismBoundary,
        "runtime": runtimeJSON(options: options, screen: screen),
        "frameCount": playback.frameCount,
        "frameDurationsNanoseconds": playback.frameDurations,
        "active": active.json,
        "hiddenSettled": hidden.settled.json,
        "hiddenEnd": hidden.end.json,
        "resumed": resumed.json,
        "registeredDriverCountAfterCancel": cancelled.registeredDrivers,
        "providerCancelCountAfterCancel": cancelled.provider.cancellations,
        "checks": [
            "active-targets-observed": true,
            "active-targets-consumed": true,
            "hidden-targets-stable": true,
            "hidden-provider-work-stable": true,
            "resume-targets-advanced": true,
            "resume-provider-work-advanced": true,
            "cancel-unregistered-driver": true,
        ],
    ]
}

private struct CancelledSnapshot {
    let registeredDrivers: Int
    let provider: (windowCalls: Int, decodedFrames: Int, cancellations: Int)
}

@MainActor
private func cancelAndSnapshot(
    view: FoveaAppKit.FoveaImageView,
    runtime: AnimationPlaybackRuntime,
    provider: MacLabProvider
) async throws -> CancelledSnapshot {
    view.cancelAnimation(clearImage: true)
    try await waitUntil(timeoutNanoseconds: 2_000_000_000, error: .cancellationDidNotUnregister) {
        await runtime.registeredDriverCount() == 0
    }
    let registered = await runtime.registeredDriverCount()
    guard registered == 0 else { throw MacLabError.cancellationDidNotUnregister }
    return CancelledSnapshot(registeredDrivers: registered, provider: await provider.snapshot())
}

private func commonTimingReport(
    version: String,
    boundary: [String],
    options: Options,
    screen: NSScreen,
    playback: PlaybackFixture,
    mode: AnimationPlaybackSchedulingMode,
    cancelled: CancelledSnapshot
) -> [String: Any] {
    [
        "schemaVersion": 1,
        "evidenceVersion": version,
        "claimBoundary": boundary,
        "runtime": runtimeJSON(options: options, screen: screen),
        "schedulingControl": options.schedulingControl.rawValue,
        "deadlineClockControl": options.deadlineClockControl.rawValue,
        "driverSchedulingMode": driverModeName(mode),
        "frameCount": playback.frameCount,
        "frameDurationsNanoseconds": playback.frameDurations,
        "providerWindowCalls": cancelled.provider.windowCalls,
        "providerFrameCount": cancelled.provider.decodedFrames,
        "registeredDriverCountAfterCancel": cancelled.registeredDrivers,
        "providerCancelCountAfterCancel": cancelled.provider.cancellations,
    ]
}

private func runtimeJSON(options: Options, screen: NSScreen) -> [String: Any] {
    [
        "operatingSystemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
        "architecture": architectureName(),
        "processorCount": ProcessInfo.processInfo.processorCount,
        "activeProcessorCount": ProcessInfo.processInfo.activeProcessorCount,
        "displayMaximumFramesPerSecond": screen.maximumFramesPerSecond,
        "displayBackingScaleFactor": Double(screen.backingScaleFactor),
        "requestedWindowPresentationMode": options.requestedWindowPresentationMode.rawValue,
        "windowPresentationMode": options.windowPresentationMode.rawValue,
        "visibleWindowAuthorized": options.visibleWindowAuthorized,
        "windowAlphaValue": Double(options.windowPresentationMode.alphaValue),
    ]
}

private func addPresentationCounts(
    _ diagnostics: FoveaAppKitAnimationPresentationDiagnosticsSnapshot?,
    to report: inout [String: Any]
) {
    if let diagnostics {
        report["presentationTargetAcceptedCount"] = diagnostics.acceptedTargetCount
        report["presentationTargetConsumedCount"] = diagnostics.consumedTargetCount
    }
}

private func verifiedDriverMode(
    options: Options,
    handle: AnimationPlaybackHandle
) async throws -> AnimationPlaybackSchedulingMode {
    let mode = await handle.driver.schedulingModeForTesting()
    let expected: AnimationPlaybackSchedulingMode = options.schedulingControl.usesExternalPresentationTicks
        ? .externalPresentationTicks : .automaticDeadlineLoop
    guard mode == expected else { throw MacLabError.callbackTimingDriverModeMismatch }
    return mode
}

private func driverModeName(_ mode: AnimationPlaybackSchedulingMode) -> String {
    mode == .externalPresentationTicks ? "external-presentation-ticks" : "automatic-deadline-loop"
}

@MainActor
private func stageSnapshot(
    view: FoveaAppKit.FoveaImageView,
    provider: MacLabProvider
) async throws -> StageSnapshot {
    guard let diagnostics = view.animationPresentationDiagnostics else {
        throw MacLabError.activeDisplayLinkDidNotAdvance
    }
    let state = await provider.snapshot()
    return StageSnapshot(
        presentation: CounterSnapshot(diagnostics),
        providerWindowCalls: state.windowCalls,
        providerFrameCount: state.decodedFrames
    )
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64,
    error: MacLabError,
    condition: @MainActor () async -> Bool
) async throws {
    let started = DispatchTime.now().uptimeNanoseconds
    while !(await condition()) {
        if DispatchTime.now().uptimeNanoseconds &- started >= timeoutNanoseconds { throw error }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

private func writeJSON(_ value: [String: Any], to output: URL) throws {
    let data = try JSONSerialization.data(
        withJSONObject: value,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: output, options: .atomic)
    print(output.path)
}

func frameDuration(index: Int) -> UInt64 {
    switch index % 6 {
    case 0: 20_000_000
    case 1: 30_000_000
    case 2: 50_000_000
    case 3: 80_000_000
    case 4: 120_000_000
    default: 200_000_000
    }
}

private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
}

func makeFrame(index: Int) -> DecodedImage {
    let width = 32
    let height = 32
    let bytesPerRow = width * 4
    let native = ProcessInfo.processInfo.environment["FOVEA_MACLAB_NATIVE_PIXEL_FORMAT"] == "1"
    var bytes = Data(count: bytesPerRow * height)
    bytes.withUnsafeMutableBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        let color = (UInt8((index * 37) & 0xFF), UInt8((index * 67) & 0xFF), UInt8((index * 97) & 0xFF))
        for offset in stride(from: 0, to: raw.count, by: 4) {
            if native {
                base[offset] = color.2; base[offset + 1] = color.1; base[offset + 2] = color.0
            } else {
                base[offset] = color.0; base[offset + 1] = color.1; base[offset + 2] = color.2
            }
            base[offset + 3] = 255
        }
    }
    let provider = CGDataProvider(data: bytes as CFData)!
    let colorSpace = native ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = native
        ? CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little)
        : CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
    return DecodedImage(cgImage: image)
}

private func architectureName() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafePointer(to: &info.machine) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
}

private let mechanismBoundary = [
    "physical Mac mechanism evidence only",
    "no third-party comparator or aggregate ranking",
    "no energy, thermal, memory, startup, codec, or cross-platform superiority claim",
    "display-target counters are distinct from timeline dropped-frame accounting",
]

private let callbackBoundary = [
    "physical Mac presenter callback timing only; not hardware scanout timing",
    "same Fovea source timeline and provider are used for both scheduling controls",
    "no third-party comparator or aggregate ranking",
    "no energy, thermal, memory, startup, codec, or cross-platform superiority claim",
]

private let refreshBoundary = [
    "physical Mac view-display-link refresh-sampled committed-frame timing",
    "both scheduling controls are sampled on displayLink.timestamp from the same view-bound display link",
    "refresh sampling observes committed source-frame state and is not a hardware pixel-scanout timestamp",
    "same Fovea source timeline and provider are used for both scheduling controls",
    "no third-party comparator or aggregate ranking",
    "no energy, thermal, memory, startup, codec, or cross-platform superiority claim",
]

private let resourceBoundary = [
    "process resource proxy only; not energy measurement",
    "no extra display observer is active in automatic-deadline mode",
    "external mode uses only its production view-bound display link",
    "CPU time, cycles, instructions, context switches and RSS are captured externally by /usr/bin/time -l",
    "thermal state is coarse ProcessInfo state only and is not a thermal-energy endpoint",
]
