import CoreGraphics
import Foundation
import FoveaCore
import FoveaHTTP
import ImageCraftCore
import XCTest

final class MultipartJPEGLivePlaybackTests: XCTestCase {
    func testSlowDecodeKeepsLatestFrameAndCountsIntermediateDrop_W5_PT_078() async throws {
        let source = LivePartSource()
        let decoder = GatedLiveFrameDecoder()
        let recorder = LiveOutputRecorder()
        let session = MultipartJPEGLivePlaybackSession(
            stream: source.stream,
            decoder: decoder,
            policy: MultipartJPEGLivePlaybackPolicy(minimumFrameIntervalNanoseconds: 1),
            clock: AutoAdvanceLiveClock()
        )
        try await session.start { output in await recorder.record(output) }
        source.yield(livePart(index: 0))
        await decoder.waitUntilStarted(index: 0)
        source.yield(livePart(index: 1))
        source.yield(livePart(index: 2))
        try await waitUntil("slow decode ingests latest pending frame") {
            let state = await session.snapshotForTesting()
            return state.pendingPartIndex == 2
                && state.droppedEncodedFrameCount == 1
        }
        await decoder.release(index: 0)
        await decoder.waitUntilStarted(index: 2, occurrence: 1)
        await decoder.release(index: 2)
        try await waitUntil("latest MJPEG frame decoded") { await recorder.count() == 2 }

        let outputs = await recorder.outputs()
        XCTAssertEqual(outputs.map(\.sourcePartIndex), [0, 2])
        XCTAssertEqual(outputs.map(\.droppedEncodedFrameCount), [1, 1])
        XCTAssertEqual(outputs.map(\.decodedFrameCount), [1, 2])
        await session.cancel()
    }

    func testInitiallyHiddenIngestsButDecodesOnlyLatestOnVisibility_W5_PT_079() async throws {
        let source = LivePartSource()
        let decoder = ImmediateLiveFrameDecoder()
        let recorder = LiveOutputRecorder()
        let session = MultipartJPEGLivePlaybackSession(
            stream: source.stream,
            decoder: decoder,
            policy: MultipartJPEGLivePlaybackPolicy(minimumFrameIntervalNanoseconds: 1),
            clock: AutoAdvanceLiveClock()
        )
        try await session.start(
            output: { output in await recorder.record(output) },
            initiallyVisible: false
        )
        source.yield(livePart(index: 0))
        source.yield(livePart(index: 1))
        source.yield(livePart(index: 2))
        try await waitUntil("hidden MJPEG ingests and coalesces latest frame") {
            let state = await session.snapshotForTesting()
            return state.pendingPartIndex == 2
                && state.droppedEncodedFrameCount == 2
        }
        let hiddenIndices = await decoder.indices()
        let hiddenOutputs = await recorder.count()
        XCTAssertEqual(hiddenIndices, [])
        XCTAssertEqual(hiddenOutputs, 0)

        await session.setVisible(true)
        try await waitUntil("hidden MJPEG latest frame appears") { await recorder.count() == 1 }
        let outputs = await recorder.outputs()
        let indices = await decoder.indices()
        XCTAssertEqual(outputs.map(\.sourcePartIndex), [2])
        XCTAssertEqual(outputs.first?.droppedEncodedFrameCount, 2)
        XCTAssertEqual(indices, [2])
        await session.cancel()
    }

    func testPauseDuringDecodeRestoresFrameForResume_W5_PT_080() async throws {
        let source = LivePartSource()
        let decoder = GatedLiveFrameDecoder()
        let recorder = LiveOutputRecorder()
        let session = MultipartJPEGLivePlaybackSession(
            stream: source.stream,
            decoder: decoder,
            policy: MultipartJPEGLivePlaybackPolicy(minimumFrameIntervalNanoseconds: 1),
            clock: AutoAdvanceLiveClock()
        )
        try await session.start { output in await recorder.record(output) }
        source.yield(livePart(index: 0))
        await decoder.waitUntilStarted(index: 0)
        await session.setApplicationActive(false)
        await decoder.release(index: 0)
        try await waitUntil("paused MJPEG frame restored to pending") {
            let state = await session.snapshotForTesting()
            return state.pendingPartIndex == 0
                && state.decodedFrameCount == 0
        }
        let pausedOutputs = await recorder.count()
        XCTAssertEqual(pausedOutputs, 0)

        await session.setApplicationActive(true)
        await decoder.waitUntilStarted(index: 0, occurrence: 2)
        await decoder.release(index: 0)
        try await waitUntil("paused MJPEG frame restored") { await recorder.count() == 1 }
        let indices = await decoder.indices()
        let outputs = await recorder.outputs()
        XCTAssertEqual(indices, [0, 0])
        XCTAssertEqual(outputs.map(\.sourcePartIndex), [0])
        await session.cancel()
    }

    func testMaximumFrameRateUsesAbsoluteDecodeDeadlines_W5_PT_081() async throws {
        let source = LivePartSource()
        let decoder = ImmediateLiveFrameDecoder()
        let recorder = LiveOutputRecorder()
        let clock = RecordingLiveClock(now: 100)
        let session = MultipartJPEGLivePlaybackSession(
            stream: source.stream,
            decoder: decoder,
            policy: MultipartJPEGLivePlaybackPolicy(minimumFrameIntervalNanoseconds: 10),
            clock: clock
        )
        try await session.start { output in await recorder.record(output) }
        source.yield(livePart(index: 0))
        try await waitUntil("first rate-limited MJPEG frame") { await recorder.count() == 1 }
        source.yield(livePart(index: 1))
        await clock.waitUntilSleeping(at: 110)
        source.yield(livePart(index: 2))
        try await waitUntil("rate-limited MJPEG keeps latest pending frame") {
            let state = await session.snapshotForTesting()
            return state.pendingPartIndex == 2
                && state.droppedEncodedFrameCount == 1
        }
        await clock.releaseSleep()
        try await waitUntil("second rate-limited MJPEG frame") { await recorder.count() == 2 }

        let deadlines = await clock.deadlines()
        let outputs = await recorder.outputs()
        XCTAssertEqual(deadlines, [110])
        XCTAssertEqual(outputs.map(\.sourcePartIndex), [0, 2])
        XCTAssertEqual(outputs.last?.droppedEncodedFrameCount, 1)
        await session.cancel()
    }

    func testRegressedPartIndexFailsClosed_W5_PT_082() async throws {
        let source = LivePartSource()
        let decoder = ImmediateLiveFrameDecoder()
        let recorder = LiveOutputRecorder()
        let session = MultipartJPEGLivePlaybackSession(
            stream: source.stream,
            decoder: decoder,
            clock: AutoAdvanceLiveClock()
        )
        try await session.start(
            output: { output in await recorder.record(output) },
            failure: { error in await recorder.fail(error) }
        )
        source.yield(livePart(index: 1))
        try await waitUntil("first indexed MJPEG frame") { await recorder.count() == 1 }
        source.yield(livePart(index: 1))
        try await waitUntil("regressed MJPEG index failure") {
            await recorder.failures().count == 1
        }
        let failures = await recorder.failures()
        let snapshot = await session.snapshotForTesting()
        XCTAssertEqual(failures, ["source-index-regressed"])
        XCTAssertTrue(snapshot.isCancelled)
    }

    func testReduceMotionPolicyDefaultsToFirstFrameAndRequiresExplicitPreserve_W5_PT_102() {
        let defaultPolicy = MultipartJPEGLivePlaybackPolicy(maximumFramesPerSecond: 30)
        XCTAssertFalse(defaultPolicy.stopsAfterFirstFrame(reduceMotionEnabled: false))
        XCTAssertTrue(defaultPolicy.stopsAfterFirstFrame(reduceMotionEnabled: true))

        let preserve = MultipartJPEGLivePlaybackPolicy(
            maximumFramesPerSecond: 30,
            reduceMotionBehavior: .preserveLiveMotion
        )
        XCTAssertFalse(preserve.stopsAfterFirstFrame(reduceMotionEnabled: true))
    }

    func testSuccessfulFiniteSessionCompletesOnceWithoutCancellation_W5_PT_103() async throws {
        let source = LivePartSource()
        let recorder = LiveOutputRecorder()
        let completion = LiveCompletionRecorder()
        let cancellation = LiveSynchronousCounter()
        let session = MultipartJPEGLivePlaybackSession(
            stream: source.stream,
            decoder: ImmediateLiveFrameDecoder(),
            policy: MultipartJPEGLivePlaybackPolicy(
                minimumFrameIntervalNanoseconds: 1
            ),
            clock: AutoAdvanceLiveClock(),
            cancellationHandler: { cancellation.increment() }
        )
        try await session.start(
            output: { output in await recorder.record(output) },
            completion: { await completion.record() }
        )
        source.yield(livePart(index: 0))
        source.finish()

        try await waitUntil("finite MJPEG session completes once") {
            await completion.count() == 1
        }
        let state = await session.snapshotForTesting()
        let outputCount = await recorder.count()
        XCTAssertEqual(outputCount, 1)
        XCTAssertTrue(state.isFinished)
        XCTAssertFalse(state.isCancelled)
        XCTAssertEqual(cancellation.value, 1)

        await session.cancel()
        XCTAssertEqual(cancellation.value, 1)
        let completionCount = await completion.count()
        XCTAssertEqual(completionCount, 1)
    }

    func testCriticalPressureDropsResidentAndIncomingEncodedFrames_W5_PT_099() async throws {
        let source = LivePartSource()
        let decoder = ImmediateLiveFrameDecoder()
        let recorder = LiveOutputRecorder()
        let session = MultipartJPEGLivePlaybackSession(
            stream: source.stream,
            decoder: decoder,
            policy: MultipartJPEGLivePlaybackPolicy(minimumFrameIntervalNanoseconds: 1),
            clock: AutoAdvanceLiveClock()
        )
        try await session.start(output: { output in await recorder.record(output) })
        await session.setVisible(false)
        source.yield(livePart(index: 0))
        try await waitUntil("MJPEG pending frame before critical pressure") {
            await session.snapshotForTesting().pendingPartIndex == 0
        }

        await session.setMemoryPressure(.critical)
        source.yield(livePart(index: 1))
        try await waitUntil("critical pressure drops pending and incoming MJPEG frames") {
            let state = await session.snapshotForTesting()
            return state.pendingPartIndex == nil
                && state.droppedEncodedFrameCount == 2
        }
        let critical = await session.snapshotForTesting()
        XCTAssertNil(critical.pendingPartIndex)
        XCTAssertEqual(critical.droppedEncodedFrameCount, 2)
        let decodedDuringCritical = await decoder.indices()
        XCTAssertEqual(decodedDuringCritical, [])

        await session.setVisible(true)
        await session.setMemoryPressure(.normal)
        let recovered = await session.snapshotForTesting()
        XCTAssertNil(recovered.pendingPartIndex)
        let outputCountAfterRecovery = await recorder.count()
        XCTAssertEqual(outputCountAfterRecovery, 0)
        source.yield(livePart(index: 2))
        try await waitUntil("MJPEG fresh frame after critical pressure") {
            await recorder.count() == 1
        }
        let outputs = await recorder.outputs()
        XCTAssertEqual(outputs.map(\.sourcePartIndex), [2])
        XCTAssertEqual(outputs.map(\.droppedEncodedFrameCount), [2])
        await session.cancel()
    }

    func testInputFailureDrainsPendingLatestThenReportsFailure_W5_PT_083() async throws {
        let source = LivePartSource()
        let decoder = GatedLiveFrameDecoder()
        let recorder = LiveOutputRecorder()
        let session = MultipartJPEGLivePlaybackSession(
            stream: source.stream,
            decoder: decoder,
            policy: MultipartJPEGLivePlaybackPolicy(minimumFrameIntervalNanoseconds: 1),
            clock: AutoAdvanceLiveClock()
        )
        try await session.start(
            output: { output in await recorder.record(output) },
            failure: { error in await recorder.fail(error) }
        )
        source.yield(livePart(index: 0))
        await decoder.waitUntilStarted(index: 0)
        source.yield(livePart(index: 1))
        source.finish(throwing: LiveTestError.sourceFailed)
        await decoder.release(index: 0)
        await decoder.release(index: 1)
        try await waitUntil("MJPEG source failure after latest drain") {
            await recorder.failures().count == 1
        }
        let outputs = await recorder.outputs()
        let failures = await recorder.failures()
        XCTAssertEqual(outputs.map(\.sourcePartIndex), [0, 1])
        XCTAssertEqual(failures, ["source-failed"])
    }
}

private struct LivePartSource: Sendable {
    let stream: AsyncThrowingStream<MultipartJPEGPart, any Error>
    private let continuation: AsyncThrowingStream<MultipartJPEGPart, any Error>.Continuation

    init() {
        let pair = AsyncThrowingStream<MultipartJPEGPart, any Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func yield(_ part: MultipartJPEGPart) { continuation.yield(part) }
    func finish(throwing error: (any Error)? = nil) {
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}

private actor LiveCompletionRecorder {
    private var storedCount = 0
    func record() { storedCount += 1 }
    func count() -> Int { storedCount }
}

private final class LiveSynchronousCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0
    func increment() { lock.withLock { storedValue += 1 } }
    var value: Int { lock.withLock { storedValue } }
}

private actor ImmediateLiveFrameDecoder: MultipartJPEGFrameDecoding {
    private var decodedIndices: [Int] = []
    func decode(_ part: MultipartJPEGPart) -> DecodedImage {
        decodedIndices.append(part.index)
        return liveImage(index: part.index)
    }
    func indices() -> [Int] { decodedIndices }
}

private actor GatedLiveFrameDecoder: MultipartJPEGFrameDecoding {
    private var decodedIndices: [Int] = []
    private var started: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releases: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releasedCounts: [Int: Int] = [:]

    func decode(_ part: MultipartJPEGPart) async -> DecodedImage {
        decodedIndices.append(part.index)
        if let waiters = started.removeValue(forKey: part.index) {
            for waiter in waiters { waiter.resume() }
        }
        let released = releasedCounts[part.index, default: 0]
        if released > 0 {
            releasedCounts[part.index] = released - 1
        } else {
            await withCheckedContinuation { releases[part.index, default: []].append($0) }
        }
        return liveImage(index: part.index)
    }

    func waitUntilStarted(index: Int, occurrence: Int = 1) async {
        if decodedIndices.filter({ $0 == index }).count >= occurrence { return }
        await withCheckedContinuation { started[index, default: []].append($0) }
    }

    func release(index: Int) {
        if var waiters = releases[index], !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            releases[index] = waiters
            waiter.resume()
        } else {
            releasedCounts[index, default: 0] += 1
        }
    }

    func indices() -> [Int] { decodedIndices }
}

private actor LiveOutputRecorder {
    private var stored: [MultipartJPEGLiveFrameOutput] = []
    private var storedFailures: [String] = []
    func record(_ output: MultipartJPEGLiveFrameOutput) { stored.append(output) }
    func fail(_ error: any Error) {
        if error as? MultipartJPEGLivePlaybackError == .sourceIndexRegressed {
            storedFailures.append("source-index-regressed")
        } else if error as? LiveTestError == .sourceFailed {
            storedFailures.append("source-failed")
        } else {
            storedFailures.append(String(describing: error))
        }
    }
    func outputs() -> [MultipartJPEGLiveFrameOutput] { stored }
    func count() -> Int { stored.count }
    func failures() -> [String] { storedFailures }
}

private struct AutoAdvanceLiveClock: AnimationPlaybackClock {
    private let storage = AutoAdvanceLiveClockStorage()
    func nowNanoseconds() async -> UInt64 { await storage.now() }
    func sleep(untilNanoseconds deadline: UInt64) async throws {
        try Task.checkCancellation()
        await storage.advance(to: deadline)
    }
}

private actor AutoAdvanceLiveClockStorage {
    private var value: UInt64 = 0
    func now() -> UInt64 { value }
    func advance(to deadline: UInt64) { value = max(value, deadline) }
}

private actor RecordingLiveClock: AnimationPlaybackClock {
    private var nowValue: UInt64
    private var storedDeadlines: [UInt64] = []
    private var sleepWaiter: CheckedContinuation<Void, Never>?
    private var observationWaiters: [CheckedContinuation<Void, Never>] = []

    init(now: UInt64) { nowValue = now }

    func nowNanoseconds() -> UInt64 { nowValue }

    func sleep(untilNanoseconds deadline: UInt64) async throws {
        try Task.checkCancellation()
        storedDeadlines.append(deadline)
        for waiter in observationWaiters { waiter.resume() }
        observationWaiters.removeAll(keepingCapacity: false)
        await withCheckedContinuation { continuation in
            sleepWaiter = continuation
            for waiter in observationWaiters { waiter.resume() }
            observationWaiters.removeAll(keepingCapacity: false)
        }
        try Task.checkCancellation()
        nowValue = max(nowValue, deadline)
    }

    func waitUntilSleeping(at deadline: UInt64) async {
        while storedDeadlines.last != deadline || sleepWaiter == nil {
            await withCheckedContinuation { observationWaiters.append($0) }
        }
    }

    func releaseSleep() {
        sleepWaiter?.resume()
        sleepWaiter = nil
    }

    func deadlines() -> [UInt64] { storedDeadlines }
}

private enum LiveTestError: Error, Equatable { case sourceFailed }

private func livePart(index: Int) -> MultipartJPEGPart {
    MultipartJPEGPart(index: index, data: Data([0xff, 0xd8, UInt8(index), 0xff, 0xd9]))
}

private func liveImage(index: Int) -> DecodedImage {
    let width = index + 2
    let height = 2
    let bytesPerRow = width * 4
    let data = Data(repeating: UInt8(index), count: bytesPerRow * height)
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
