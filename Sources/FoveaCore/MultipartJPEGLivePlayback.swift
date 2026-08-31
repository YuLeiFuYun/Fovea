import Foundation
import FoveaHTTP
import ImageCraftCore

/// 消费 MJPEG part stream 的 latest-frame 播放会话。
///
/// 网络摄取与像素解码解耦：摄取端永远只保留一个最新 encoded part，慢解码期间到达的
/// 中间 part 被显式计入 droppedEncodedFrameCount，而不会形成无界队列或反压网络流。
/// 解码启动间隔使用绝对单调 deadline；offscreen/background 期间继续保留最新 encoded part，
/// 恢复时只解码最新值，不追赶历史帧。
package actor MultipartJPEGLivePlaybackSession {
    package typealias OutputHandler = @Sendable (MultipartJPEGLiveFrameOutput) async -> Void
    package typealias FailureHandler = @Sendable (any Error) async -> Void
    package typealias CompletionHandler = @Sendable () async -> Void

    private let stream: AsyncThrowingStream<MultipartJPEGPart, any Error>
    private let decoder: any MultipartJPEGFrameDecoding
    private let clock: any AnimationPlaybackClock
    private let policy: MultipartJPEGLivePlaybackPolicy
    private let diagnostics: any DiagnosticsSink
    private let diagnosticKeyDigest: String?
    private let stopsAfterFirstFrame: Bool
    private let cancellationHandler: @Sendable () -> Void

    private var outputHandler: OutputHandler?
    private var failureHandler: FailureHandler?
    private var completionHandler: CompletionHandler?
    private var ingestionTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?
    private var pendingPart: MultipartJPEGPart?
    private var pendingSignal: CheckedContinuation<Void, Never>?
    private var inputFinished = false
    private var inputFailure: (any Error)?
    private var isVisible = true
    private var applicationIsActive = true
    private var memoryPressure: AnimationMemoryPressureLevel = .normal
    private var isCancelled = false
    private var isFinished = false
    private var hasStarted = false
    private var hasSelectedFirstFrame = false
    private var nextEligibleDecodeNanoseconds: UInt64?
    private var droppedEncodedFrameCount: UInt64 = 0
    private var lastReportedDroppedEncodedFrameCount: UInt64 = 0
    private var decodedFrameCount: UInt64 = 0
    private var lastReceivedPartIndex: Int?

    package init(
        stream: AsyncThrowingStream<MultipartJPEGPart, any Error>,
        decoder: any MultipartJPEGFrameDecoding,
        policy: MultipartJPEGLivePlaybackPolicy = MultipartJPEGLivePlaybackPolicy(),
        clock: any AnimationPlaybackClock = SystemAnimationPlaybackClock(),
        diagnostics: any DiagnosticsSink = NullDiagnosticsSink(),
        diagnosticKeyDigest: String? = nil,
        stopsAfterFirstFrame: Bool = false,
        cancellationHandler: @escaping @Sendable () -> Void = {}
    ) {
        self.stream = stream
        self.decoder = decoder
        self.policy = policy
        self.clock = clock
        self.diagnostics = diagnostics
        self.diagnosticKeyDigest = diagnosticKeyDigest
        self.stopsAfterFirstFrame = stopsAfterFirstFrame
        self.cancellationHandler = cancellationHandler
    }

    deinit {
        ingestionTask?.cancel()
        workerTask?.cancel()
        pendingSignal?.resume()
        cancellationHandler()
    }

    package func start(
        output: @escaping OutputHandler,
        failure: @escaping FailureHandler = { _ in },
        completion: @escaping CompletionHandler = {},
        initiallyVisible: Bool = true,
        initiallyApplicationActive: Bool = true,
        initialMemoryPressure: AnimationMemoryPressureLevel = .normal
    ) throws {
        guard !isTerminal else { throw MultipartJPEGLivePlaybackError.cancelled }
        guard !hasStarted else { throw MultipartJPEGLivePlaybackError.alreadyStarted }
        hasStarted = true
        outputHandler = output
        failureHandler = failure
        completionHandler = completion
        isVisible = initiallyVisible
        applicationIsActive = initiallyApplicationActive
        memoryPressure = initialMemoryPressure

        let stream = stream
        ingestionTask = Task { [weak self] in
            do {
                for try await part in stream {
                    try Task.checkCancellation()
                    try await self?.submit(part)
                }
                await self?.finishInput(error: nil)
            } catch is CancellationError {
                return
            } catch {
                await self?.finishInput(error: error)
            }
        }
        ensureWorker()
    }

    package func setVisible(_ visible: Bool) {
        guard !isTerminal else { return }
        isVisible = visible
        if visible {
            signalWorker()
            ensureWorker()
        }
    }

    package func setApplicationActive(_ active: Bool) {
        guard !isTerminal else { return }
        applicationIsActive = active
        if active {
            signalWorker()
            ensureWorker()
        }
    }

    package func setMemoryPressure(_ level: AnimationMemoryPressureLevel) {
        guard !isTerminal else { return }
        memoryPressure = level
        if level == .critical {
            if pendingPart != nil {
                pendingPart = nil
                droppedEncodedFrameCount = Self.saturatingIncrement(
                    droppedEncodedFrameCount
                )
            }
            return
        }
        signalWorker()
        ensureWorker()
    }

    package func cancel() {
        guard !isTerminal else { return }
        isCancelled = true
        ingestionTask?.cancel()
        ingestionTask = nil
        workerTask?.cancel()
        workerTask = nil
        pendingPart = nil
        inputFailure = nil
        signalWorker()
        outputHandler = nil
        failureHandler = nil
        completionHandler = nil
        cancellationHandler()
    }

    package func snapshotForTesting() -> (
        pendingPartIndex: Int?,
        droppedEncodedFrameCount: UInt64,
        decodedFrameCount: UInt64,
        inputFinished: Bool,
        isCancelled: Bool,
        isFinished: Bool
    ) {
        (
            pendingPart?.index,
            droppedEncodedFrameCount,
            decodedFrameCount,
            inputFinished,
            isCancelled,
            isFinished
        )
    }

    private func submit(_ part: MultipartJPEGPart) throws {
        guard !isTerminal else { throw MultipartJPEGLivePlaybackError.cancelled }
        if let lastReceivedPartIndex, part.index <= lastReceivedPartIndex {
            throw MultipartJPEGLivePlaybackError.sourceIndexRegressed
        }
        lastReceivedPartIndex = part.index
        if stopsAfterFirstFrame {
            if hasSelectedFirstFrame {
                droppedEncodedFrameCount = Self.saturatingIncrement(droppedEncodedFrameCount)
                return
            }
            hasSelectedFirstFrame = true
        }
        if memoryPressure == .critical {
            droppedEncodedFrameCount = Self.saturatingIncrement(droppedEncodedFrameCount)
            return
        }
        if pendingPart != nil {
            droppedEncodedFrameCount = Self.saturatingIncrement(droppedEncodedFrameCount)
        }
        pendingPart = part
        signalWorker()
        ensureWorker()
    }

    private func finishInput(error: (any Error)?) {
        guard !isTerminal else { return }
        inputFinished = true
        inputFailure = error
        signalWorker()
        ensureWorker()
    }

    private func ensureWorker() {
        guard hasStarted, !isTerminal, workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.runWorker()
        }
    }

    private func runWorker() async {
        defer { workerFinished() }
        while !Task.isCancelled {
            guard !isTerminal else { return }
            guard isVisible, applicationIsActive, memoryPressure != .critical else {
                await waitForSignal()
                continue
            }
            guard pendingPart != nil else {
                if inputFinished {
                    await finishPlaybackIfNeeded()
                    return
                }
                await waitForSignal()
                continue
            }

            do {
                if try await decodePendingPartAndPublishIfEligible() { return }
            } catch is CancellationError {
                return
            } catch {
                await fail(error)
                return
            }
        }
    }

    private func decodePendingPartAndPublishIfEligible() async throws -> Bool {
        try await waitUntilEligibleDecodeTime()
        try Task.checkCancellation()
        guard !isCancelled, isVisible, applicationIsActive, memoryPressure != .critical,
            let part = pendingPart
        else { return false }
        pendingPart = nil
        let decoded = try await decode(part)
        try Task.checkCancellation()
        guard !isTerminal else { return true }
        guard isVisible, applicationIsActive, memoryPressure != .critical else {
            restoreOrDropAfterVisibilityChange(part)
            return false
        }
        await publish(decoded.image, part: part, decodeDuration: decoded.duration)
        guard stopsAfterFirstFrame else { return false }
        await completeSuccessfully()
        return true
    }

    private func decode(_ part: MultipartJPEGPart) async throws -> (image: DecodedImage, duration: UInt64) {
        let decodeStarted = await clock.nowNanoseconds()
        let next = decodeStarted.addingReportingOverflow(policy.minimumFrameIntervalNanoseconds)
        guard !next.overflow else { throw MultipartJPEGLivePlaybackError.deadlineOverflow }
        nextEligibleDecodeNanoseconds = next.partialValue
        let image = try await decoder.decode(part)
        let decodeFinished = await clock.nowNanoseconds()
        guard decodeFinished >= decodeStarted else {
            throw MultipartJPEGLivePlaybackError.nonMonotonicClock
        }
        return (image, decodeFinished - decodeStarted)
    }

    private func restoreOrDropAfterVisibilityChange(_ part: MultipartJPEGPart) {
        if memoryPressure == .critical || pendingPart != nil {
            droppedEncodedFrameCount = Self.saturatingIncrement(droppedEncodedFrameCount)
        } else {
            pendingPart = part
        }
    }

    private func publish(
        _ image: DecodedImage,
        part: MultipartJPEGPart,
        decodeDuration: UInt64
    ) async {
        decodedFrameCount = Self.saturatingIncrement(decodedFrameCount)
        let output = MultipartJPEGLiveFrameOutput(
            image: image,
            sourcePartIndex: part.index,
            droppedEncodedFrameCount: droppedEncodedFrameCount,
            decodedFrameCount: decodedFrameCount,
            decodeDurationNanoseconds: decodeDuration
        )
        lastReportedDroppedEncodedFrameCount = await MultipartJPEGLiveDiagnostics.recordPublication(
            output,
            previousDroppedFrameCount: lastReportedDroppedEncodedFrameCount,
            sink: diagnostics,
            keyDigest: diagnosticKeyDigest
        )
        if let outputHandler { await outputHandler(output) }
    }

    private func waitUntilEligibleDecodeTime() async throws {
        guard let deadline = nextEligibleDecodeNanoseconds else { return }
        let now = await clock.nowNanoseconds()
        guard deadline > now else { return }
        try await clock.sleep(untilNanoseconds: deadline)
    }

    private func waitForSignal() async {
        if isTerminal { return }
        await withCheckedContinuation { continuation in
            if isTerminal
                || (isVisible && applicationIsActive && memoryPressure != .critical
                    && pendingPart != nil)
                || (inputFinished && pendingPart == nil)
            {
                continuation.resume()
            } else {
                pendingSignal = continuation
            }
        }
    }

    private func signalWorker() {
        pendingSignal?.resume()
        pendingSignal = nil
    }

    private func workerFinished() {
        workerTask = nil
        if !isTerminal,
            pendingPart != nil,
            isVisible,
            applicationIsActive,
            memoryPressure != .critical
        {
            ensureWorker()
        }
    }

    private func finishPlaybackIfNeeded() async {
        if let inputFailure {
            await fail(inputFailure)
        } else {
            await completeSuccessfully()
        }
    }

    private func completeSuccessfully() async {
        guard !isTerminal else { return }
        isFinished = true
        ingestionTask?.cancel()
        ingestionTask = nil
        pendingPart = nil
        signalWorker()
        cancellationHandler()
        if let completionHandler { await completionHandler() }
        outputHandler = nil
        failureHandler = nil
        completionHandler = nil
    }

    private func fail(_ error: any Error) async {
        guard !isTerminal else { return }
        isCancelled = true
        ingestionTask?.cancel()
        ingestionTask = nil
        pendingPart = nil
        signalWorker()
        await MultipartJPEGLiveDiagnostics.recordFailure(
            error,
            sink: diagnostics,
            keyDigest: diagnosticKeyDigest
        )
        if let failureHandler { await failureHandler(error) }
        outputHandler = nil
        failureHandler = nil
        completionHandler = nil
        cancellationHandler()
    }

    private var isTerminal: Bool { isCancelled || isFinished }

    private nonisolated static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == .max ? .max : value + 1
    }
}
