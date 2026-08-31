import AppKit
import CoreGraphics
import Dispatch
import Foundation
import FoveaAppKit
import FoveaCore
import ImageCraftCore

enum MacLabError: Error {
    case invalidArguments
    case requiresMacOS14
    case displayUnavailable
    case decodeKeyUnavailable
    case activeDisplayLinkDidNotAdvance
    case hiddenPauseDidNotEngage
    case hiddenDisplayLinkAdvanced
    case hiddenProviderAdvanced
    case resumeDidNotAdvance
    case cancellationDidNotUnregister
    case callbackTimingDidNotComplete
    case callbackTimingDriverModeMismatch
    case resourceProxyDidNotStart
}

enum Experiment: String {
    case mechanism
    case callbackTiming = "callback-timing"
    case refreshTiming = "refresh-timing"
    case resourceProxy = "resource-proxy"
}

enum SchedulingControl: String {
    case platformDefault = "platform-default"
    case externalEveryRefresh = "external-every-refresh"
    case automaticDeadline = "automatic-deadline"

    var appKitControl: FoveaAppKitAnimationSchedulingControl {
        switch self {
        case .platformDefault: .platformDefault
        case .externalEveryRefresh: .externalEveryRefreshControl
        case .automaticDeadline: .automaticDeadlineLoop
        }
    }

    var usesExternalPresentationTicks: Bool { self != .automaticDeadline }
}

enum DeadlineClockControl: String {
    case systemTaskSleep = "system-task-sleep"
    case strictDispatch = "strict-dispatch"
}

enum WindowPresentationMode: String {
    case nonintrusive
    case visible

    var alphaValue: CGFloat { self == .nonintrusive ? 0 : 1 }
}

struct Options {
    let output: URL
    let experiment: Experiment
    let schedulingControl: SchedulingControl
    let deadlineClockControl: DeadlineClockControl
    let requestedWindowPresentationMode: WindowPresentationMode
    let windowPresentationMode: WindowPresentationMode
    let visibleWindowAuthorized: Bool
    let durationNanoseconds: UInt64

    init(_ arguments: [String]) throws {
        let values = try Self.argumentMap(arguments)
        guard let output = values["--output"],
            let experiment = Experiment(rawValue: values["--experiment"] ?? "mechanism"),
            let scheduling = SchedulingControl(
                rawValue: values["--scheduling-control"] ?? "platform-default"
            ),
            let deadline = DeadlineClockControl(
                rawValue: values["--deadline-clock"] ?? "system-task-sleep"
            ),
            let requestedWindow = WindowPresentationMode(
                rawValue: values["--window-presentation"] ?? "nonintrusive"
            )
        else { throw MacLabError.invalidArguments }
        try Self.validate(experiment: experiment, scheduling: scheduling, deadline: deadline)
        let durationSeconds = values["--duration-seconds"].flatMap(UInt64.init) ?? 10
        guard (1...60).contains(durationSeconds) else { throw MacLabError.invalidArguments }
        self.output = URL(fileURLWithPath: output)
        self.experiment = experiment
        self.schedulingControl = scheduling
        self.deadlineClockControl = deadline
        self.requestedWindowPresentationMode = requestedWindow
        self.visibleWindowAuthorized = false
        self.windowPresentationMode = .nonintrusive
        self.durationNanoseconds = durationSeconds * 1_000_000_000
    }

    private static func argumentMap(_ arguments: [String]) throws -> [String: String] {
        guard arguments.count >= 3, !arguments.count.isMultiple(of: 2) else {
            throw MacLabError.invalidArguments
        }
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw MacLabError.invalidArguments }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        return values
    }

    private static func validate(
        experiment: Experiment,
        scheduling: SchedulingControl,
        deadline: DeadlineClockControl
    ) throws {
        guard experiment != .mechanism || scheduling == .platformDefault else {
            throw MacLabError.invalidArguments
        }
        guard deadline != .strictDispatch || scheduling == .automaticDeadline else {
            throw MacLabError.invalidArguments
        }
    }
}

struct StrictDispatchAnimationClock: AnimationPlaybackClock {
    private let queue = DispatchQueue(
        label: "fovea.animation.mac-lab.strict-deadline",
        qos: .default
    )

    func nowNanoseconds() async -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func sleep(untilNanoseconds deadline: UInt64) async throws {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else {
            try Task.checkCancellation()
            return
        }
        let state = StrictDispatchSleepState()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(deadline: deadline, queue: queue, continuation: continuation)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

final class StrictDispatchSleepState: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var completed = false

    func install(
        deadline: UInt64,
        queue: DispatchQueue,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline), leeway: .nanoseconds(0))
        timer.setEventHandler { [self] in finish(error: nil) }
        lock.lock()
        guard !completed else {
            lock.unlock()
            timer.cancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.timer = timer
        self.continuation = continuation
        timer.activate()
        lock.unlock()
    }

    func cancel() { finish(error: CancellationError()) }

    private func finish(error: (any Error)?) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let timer = self.timer
        let continuation = self.continuation
        self.timer = nil
        self.continuation = nil
        lock.unlock()
        timer?.cancel()
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }
}

struct CounterSnapshot {
    let acceptedTargetCount: UInt64
    let consumedTargetCount: UInt64
    let supersededPendingTargetCount: UInt64
    let rejectedNonmonotonicTargetCount: UInt64
    let lifecycleClearedPendingTargetCount: UInt64
    let hasPendingTarget: Bool
    let lastAcceptedTargetNanoseconds: UInt64?
    let isDisplayLinkPaused: Bool
    let effectiveVisibility: Bool?

    init(_ value: FoveaAppKitAnimationPresentationDiagnosticsSnapshot) {
        acceptedTargetCount = value.acceptedTargetCount
        consumedTargetCount = value.consumedTargetCount
        supersededPendingTargetCount = value.supersededPendingTargetCount
        rejectedNonmonotonicTargetCount = value.rejectedNonmonotonicTargetCount
        lifecycleClearedPendingTargetCount = value.lifecycleClearedPendingTargetCount
        hasPendingTarget = value.hasPendingTarget
        lastAcceptedTargetNanoseconds = value.lastAcceptedTargetNanoseconds
        isDisplayLinkPaused = value.isDisplayLinkPaused
        effectiveVisibility = value.effectiveVisibility
    }

    var json: [String: Any] {
        var value: [String: Any] = [
            "acceptedTargetCount": acceptedTargetCount,
            "consumedTargetCount": consumedTargetCount,
            "supersededPendingTargetCount": supersededPendingTargetCount,
            "rejectedNonmonotonicTargetCount": rejectedNonmonotonicTargetCount,
            "lifecycleClearedPendingTargetCount": lifecycleClearedPendingTargetCount,
            "hasPendingTarget": hasPendingTarget,
            "isDisplayLinkPaused": isDisplayLinkPaused,
        ]
        if let lastAcceptedTargetNanoseconds {
            value["lastAcceptedTargetNanoseconds"] = lastAcceptedTargetNanoseconds
        }
        if let effectiveVisibility { value["effectiveVisibility"] = effectiveVisibility }
        return value
    }
}

struct StageSnapshot {
    let presentation: CounterSnapshot
    let providerWindowCalls: Int
    let providerFrameCount: Int

    var json: [String: Any] {
        [
            "presentation": presentation.json,
            "providerWindowCalls": providerWindowCalls,
            "providerFrameCount": providerFrameCount,
        ]
    }
}

struct CallbackTimingEvent {
    let sequence: Int
    let elapsedNanoseconds: UInt64
    let frameIndex: Int

    var json: [String: Any] {
        ["sequence": sequence, "elapsedNanoseconds": elapsedNanoseconds, "frameIndex": frameIndex]
    }
}

@MainActor
final class CallbackTimingRecorder {
    private let frameCount: Int
    private(set) var firstTimestamp: UInt64?
    private(set) var observations: [CallbackTimingEvent] = []
    private(set) var observedSourceOrdinal: UInt64 = 0

    init(frameCount: Int) { self.frameCount = frameCount }

    func record(frameIndex: Int, timestamp: UInt64) {
        guard observedSourceOrdinal < UInt64(frameCount), (0..<frameCount).contains(frameIndex) else {
            return
        }
        guard observations.last?.frameIndex != frameIndex else { return }
        if let previous = observations.last?.frameIndex {
            let delta = frameIndex > previous ? frameIndex - previous : frameCount - previous + frameIndex
            observedSourceOrdinal &+= UInt64(delta)
        }
        let first = firstTimestamp ?? timestamp
        firstTimestamp = first
        observations.append(
            CallbackTimingEvent(
                sequence: observations.count,
                elapsedNanoseconds: timestamp &- first,
                frameIndex: frameIndex
            )
        )
    }
}

@MainActor
final class RefreshTimingRecorder {
    private let transitions: CallbackTimingRecorder
    private var lastRefreshTimestamp: UInt64?
    private(set) var refreshSampleCount = 0
    private(set) var refreshIntervalsNanoseconds: [UInt64] = []

    init(frameCount: Int) { transitions = CallbackTimingRecorder(frameCount: frameCount) }
    var observations: [CallbackTimingEvent] { transitions.observations }
    var observedSourceOrdinal: UInt64 { transitions.observedSourceOrdinal }
    var firstTimestamp: UInt64? { transitions.firstTimestamp }

    func record(frameIndex: Int, timestamp: UInt64) {
        if let lastRefreshTimestamp, timestamp > lastRefreshTimestamp {
            refreshIntervalsNanoseconds.append(timestamp - lastRefreshTimestamp)
        }
        lastRefreshTimestamp = timestamp
        refreshSampleCount += 1
        transitions.record(frameIndex: frameIndex, timestamp: timestamp)
    }
}

actor MacLabProvider: AnimationFrameProvider {
    private let frameCount: Int
    private var windowCalls = 0
    private var decodedFrames = 0
    private var cancellations = 0

    init(frameCount: Int) { self.frameCount = frameCount }

    func frames(in range: Range<Int>) throws -> [AnimationProviderFrame] {
        guard range.lowerBound >= 0, range.upperBound <= frameCount else {
            throw AnimationPlaybackCoordinatorError.providerResultMismatch
        }
        windowCalls += 1
        decodedFrames += range.count
        return range.map { AnimationProviderFrame(index: $0, image: makeFrame(index: $0)) }
    }

    func cancel() { cancellations += 1 }
    func snapshot() -> (windowCalls: Int, decodedFrames: Int, cancellations: Int) {
        (windowCalls, decodedFrames, cancellations)
    }
}

struct PlaybackFixture {
    let runtime: AnimationPlaybackRuntime
    let provider: MacLabProvider
    let handle: AnimationPlaybackHandle
    let frameCount: Int
    let frameDurations: [UInt64]

    static func make(options: Options) async throws -> PlaybackFixture {
        let frameCount = 60
        let frameDurations = (0..<frameCount).map { frameDuration(index: $0) }
        let predecodeAll = ProcessInfo.processInfo.environment["FOVEA_MACLAB_PREDECODE_ALL"] == "1"
        let runtime = AnimationPlaybackRuntime(
            frameMemoryCostLimit: predecodeAll ? 512 * 1024 : 16 * 1024
        )
        let provider = MacLabProvider(frameCount: frameCount)
        guard let decodeKey = AnimationDecodeKey(
            contentID: ContentID(data: Data("fovea-appkit-physical-display-link-v1".utf8)),
            target: try TargetPixels(width: 32, height: 32),
            contentMode: .fit,
            colorPolicy: .convertToSRGB,
            codecFingerprint: "fovea-animation-mac-lab-v1",
            animationPolicyVersion: 1,
            timingPolicyVersion: 1,
            frameStrategy: predecodeAll ? .predecodeAll : .boundedFrameCache
        ) else { throw MacLabError.decodeKeyUnavailable }
        let timeline = try AnimationPlaybackTimeline(
            frameDurationsNanoseconds: frameDurations,
            additionalRepeatCount: nil,
            zeroDurationReplacementNanoseconds: 10_000_000,
            timingPolicyVersion: 1
        )
        let clock: any AnimationPlaybackClock = options.deadlineClockControl == .strictDispatch
            ? StrictDispatchAnimationClock() : SystemAnimationPlaybackClock()
        let handle = try await runtime.makeHandle(
            namespace: SecurityNamespaceID("fovea-appkit-mac-lab"),
            generation: NamespaceGeneration(1),
            decodeKey: decodeKey,
            timeline: timeline,
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
            reduceMotionEnabled: false,
            provider: provider,
            windowPolicy: AnimationFrameWindowPolicy(normalFrameCount: 4, warningFrameCount: 2),
            maximumPredecodeAllFrameCount: predecodeAll ? frameCount : 0,
            clock: clock
        )
        return PlaybackFixture(
            runtime: runtime,
            provider: provider,
            handle: handle,
            frameCount: frameCount,
            frameDurations: frameDurations
        )
    }
}

@MainActor
final class WindowFixture {
    let window: NSWindow
    let imageView: FoveaAppKit.FoveaImageView

    init(options: Options, screen: NSScreen) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.alphaValue = options.windowPresentationMode.alphaValue
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 160))
        imageView = FoveaAppKit.FoveaImageView(
            frame: NSRect(x: 16, y: 16, width: 128, height: 128)
        )
        content.addSubview(imageView)
        window.contentView = content
        window.center()
        window.orderFrontRegardless()
    }

    func close() {
        imageView.cancelAnimation(clearImage: true)
        window.orderOut(nil)
        window.close()
    }
}
