import CoreGraphics
import CryptoKit
import Foundation
import FoveaCore
import FoveaHTTP
import ImageCraftCore

struct MJPEGMechanismTrial: Codable, Sendable {
    let order: String
    let latestElapsedNanoseconds: UInt64
    let decodeEveryElapsedNanoseconds: UInt64
    let latestDecodeCount: Int
    let decodeEveryCount: Int
    let latestDroppedFrameCount: UInt64
    let latestPeakQueuedEncodedBytes: Int
    let decodeEveryPeakQueuedEncodedBytes: Int
    let finalSourceIndex: Int
    let finalPixelDigestEqual: Bool
}

struct MJPEGMechanismReport: Codable, Sendable {
    let schemaVersion: Int
    let mode: String
    let frameCount: Int
    let encodedBytesPerFrame: Int
    let syntheticWorkIterationsPerDecode: Int
    let allCorrect: Bool
    let orderBalanced: Bool
    let trials: [MJPEGMechanismTrial]
    let claimBoundary: [String]
}

enum MJPEGMechanismLab {
    private static let frameCount = 120
    private static let encodedBytesPerFrame = 4 * 1024
    private static let workIterations = 160
    private static let trialCount = 8

    static func run() async throws -> MJPEGMechanismReport {
        _ = try await runTrial(latestFirst: true)
        var trials: [MJPEGMechanismTrial] = []
        trials.reserveCapacity(trialCount)
        for index in 0..<trialCount {
            trials.append(try await runTrial(latestFirst: index.isMultiple(of: 2)))
        }
        let correct = trials.allSatisfy {
            (1...2).contains($0.latestDecodeCount)
                && $0.latestDecodeCount == 2
                && $0.latestDroppedFrameCount == UInt64(frameCount - 2)
                && $0.decodeEveryCount == frameCount
                && $0.finalSourceIndex == frameCount - 1
                && $0.finalPixelDigestEqual
                && $0.latestPeakQueuedEncodedBytes <= encodedBytesPerFrame
                && $0.decodeEveryPeakQueuedEncodedBytes
                    == encodedBytesPerFrame * frameCount
        }
        let latestFirstCount = trials.filter { $0.order == "latest-first" }.count
        return MJPEGMechanismReport(
            schemaVersion: 1,
            mode: "mjpeg-latest-only-mechanism",
            frameCount: frameCount,
            encodedBytesPerFrame: encodedBytesPerFrame,
            syntheticWorkIterationsPerDecode: workIterations,
            allCorrect: correct,
            orderBalanced: latestFirstCount * 2 == trials.count,
            trials: trials,
            claimBoundary: [
                "synthetic CPU decode work; not a codec throughput result",
                "decode-every baseline intentionally queues the full burst and is not memory-equivalent",
                "no network, display deadline, energy, thermal or physical-device evidence",
                "dirty local results are directional and do not establish an overall product winner",
            ]
        )
    }

    private static func runTrial(latestFirst: Bool) async throws -> MJPEGMechanismTrial {
        let frames = makeFrames()
        let latest: LatestResult
        let baseline: BaselineResult
        if latestFirst {
            latest = try await measureLatest(frames)
            baseline = try await measureDecodeEvery(frames)
        } else {
            baseline = try await measureDecodeEvery(frames)
            latest = try await measureLatest(frames)
        }
        return MJPEGMechanismTrial(
            order: latestFirst ? "latest-first" : "decode-every-first",
            latestElapsedNanoseconds: latest.elapsed,
            decodeEveryElapsedNanoseconds: baseline.elapsed,
            latestDecodeCount: latest.decodeCount,
            decodeEveryCount: baseline.decodeCount,
            latestDroppedFrameCount: latest.dropped,
            latestPeakQueuedEncodedBytes: encodedBytesPerFrame,
            decodeEveryPeakQueuedEncodedBytes: encodedBytesPerFrame * frameCount,
            finalSourceIndex: latest.finalIndex,
            finalPixelDigestEqual: latest.finalDigest == baseline.finalDigest
        )
    }

    private struct LatestResult {
        let elapsed: UInt64
        let decodeCount: Int
        let dropped: UInt64
        let finalIndex: Int
        let finalDigest: String
    }

    private struct BaselineResult {
        let elapsed: UInt64
        let decodeCount: Int
        let finalDigest: String
    }

    private static func measureLatest(_ frames: [MultipartJPEGPart]) async throws -> LatestResult {
        let source = LabPartSource()
        let decoder = LabWorkDecoder(iterations: workIterations, gatesFirstDecode: true)
        let recorder = LabOutputRecorder()
        let completion = LabCompletion()
        let session = MultipartJPEGLivePlaybackSession(
            stream: source.stream,
            decoder: decoder,
            policy: MultipartJPEGLivePlaybackPolicy(minimumFrameIntervalNanoseconds: 1),
            clock: LabImmediateClock()
        )
        let started = DispatchTime.now().uptimeNanoseconds
        try await session.start(
            output: { output in await recorder.record(output) },
            completion: { await completion.finish() }
        )
        source.yield(frames[0])
        await decoder.waitUntilFirstDecodeStarts()
        for frame in frames.dropFirst() { source.yield(frame) }
        source.finish()
        try await waitForBurstIngestion(session)
        await decoder.releaseFirstDecode()
        await completion.wait()
        let elapsed = DispatchTime.now().uptimeNanoseconds &- started
        let output = try await recorder.lastOutput()
        return LatestResult(
            elapsed: elapsed,
            decodeCount: await decoder.decodeCount(),
            dropped: output.droppedEncodedFrameCount,
            finalIndex: output.sourcePartIndex,
            finalDigest: pixelDigest(output.image)
        )
    }

    private static func waitForBurstIngestion(
        _ session: MultipartJPEGLivePlaybackSession
    ) async throws {
        for _ in 0..<100_000 {
            let snapshot = await session.snapshotForTesting()
            if snapshot.inputFinished,
                snapshot.pendingPartIndex == frameCount - 1,
                snapshot.droppedEncodedFrameCount == UInt64(frameCount - 2)
            {
                return
            }
            await Task.yield()
        }
        throw LabError.ingestionDidNotConverge
    }

    private static func measureDecodeEvery(_ frames: [MultipartJPEGPart]) async throws
        -> BaselineResult
    {
        let decoder = LabWorkDecoder(iterations: workIterations, gatesFirstDecode: false)
        let started = DispatchTime.now().uptimeNanoseconds
        var final: DecodedImage?
        for frame in frames { final = try await decoder.decode(frame) }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- started
        guard let final else { throw LabError.missingOutput }
        return BaselineResult(
            elapsed: elapsed,
            decodeCount: await decoder.decodeCount(),
            finalDigest: pixelDigest(final)
        )
    }

    private static func makeFrames() -> [MultipartJPEGPart] {
        (0..<frameCount).map { index in
            var data = Data(repeating: UInt8(index & 0xff), count: encodedBytesPerFrame)
            data[0] = 0xff
            data[1] = 0xd8
            data[data.count - 2] = 0xff
            data[data.count - 1] = 0xd9
            return MultipartJPEGPart(index: index, data: data)
        }
    }

    private static func pixelDigest(_ image: DecodedImage) -> String {
        guard let data = image.cgImage.dataProvider?.data as Data? else { return "missing" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct LabPartSource: Sendable {
    let stream: AsyncThrowingStream<MultipartJPEGPart, any Error>
    private let continuation: AsyncThrowingStream<MultipartJPEGPart, any Error>.Continuation

    init() {
        let pair = AsyncThrowingStream<MultipartJPEGPart, any Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func yield(_ part: MultipartJPEGPart) { continuation.yield(part) }
    func finish() { continuation.finish() }
}

private actor LabWorkDecoder: MultipartJPEGFrameDecoding {
    private let iterations: Int
    private let gatesFirstDecode: Bool
    private var count = 0
    private var firstStarted = false
    private var firstStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstReleased = false
    private var firstReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(iterations: Int, gatesFirstDecode: Bool) {
        self.iterations = iterations
        self.gatesFirstDecode = gatesFirstDecode
    }

    func decode(_ part: MultipartJPEGPart) async throws -> DecodedImage {
        count += 1
        if gatesFirstDecode, count == 1 {
            firstStarted = true
            for waiter in firstStartWaiters { waiter.resume() }
            firstStartWaiters.removeAll(keepingCapacity: false)
            if !firstReleased {
                await withCheckedContinuation { firstReleaseWaiters.append($0) }
            }
        }
        var work = part.data
        for _ in 0..<iterations { work = Data(SHA256.hash(data: work)) }
        return makeLabImage(index: part.index, digest: work)
    }

    func waitUntilFirstDecodeStarts() async {
        if firstStarted { return }
        await withCheckedContinuation { firstStartWaiters.append($0) }
    }

    func releaseFirstDecode() {
        firstReleased = true
        for waiter in firstReleaseWaiters { waiter.resume() }
        firstReleaseWaiters.removeAll(keepingCapacity: false)
    }

    func decodeCount() -> Int { count }
}

private actor LabOutputRecorder {
    private var last: MultipartJPEGLiveFrameOutput?
    func record(_ output: MultipartJPEGLiveFrameOutput) { last = output }
    func lastOutput() throws -> MultipartJPEGLiveFrameOutput {
        guard let last else { throw LabError.missingOutput }
        return last
    }
}

private actor LabCompletion {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func finish() {
        guard !finished else { return }
        finished = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll(keepingCapacity: false)
    }
    func wait() async {
        if finished { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor LabImmediateClock: AnimationPlaybackClock {
    private var now: UInt64 = 0
    func nowNanoseconds() -> UInt64 { now }
    func sleep(untilNanoseconds deadline: UInt64) throws {
        try Task.checkCancellation()
        now = max(now, deadline)
    }
}

private enum LabError: Error { case missingOutput, ingestionDidNotConverge }

private func makeLabImage(index: Int, digest: Data) -> DecodedImage {
    let width = 4
    let height = 4
    let bytesPerRow = width * 4
    var pixels = Data(count: bytesPerRow * height)
    pixels.withUnsafeMutableBytes { target in
        for offset in 0..<target.count {
            target[offset] = digest[offset % digest.count] ^ UInt8(index & 0xff)
        }
    }
    let provider = CGDataProvider(data: pixels as CFData)!
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
