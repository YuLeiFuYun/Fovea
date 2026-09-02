import Foundation
import FoveaHTTP
import ImageCraftCore
import XCTest

@testable import FoveaCore

final class T100ProgressivePreviewSessionOwnershipTests: XCTestCase {
    func testNilProgressiveSessionNeverCreatesResourceOwner_T100_RESOURCE_PT_001() async throws {
        let recorder = FoveaProgressiveResourceRecorder(
            capacity: 64,
            physicalFootprintProvider: { 0 }
        )
        let ownerID = UUID()
        let relay = TransportProgressRelay(
            maximumBufferedBytes: 1_024,
            resourceRecorder: recorder,
            resourceOwnerID: ownerID
        )
        let stage = DecodeStage(
            codec: T100NonProgressiveCodec(),
            limits: .coreV1,
            diagnostics: NullDiagnosticsSink(),
            maximumConcurrentDecodes: 1,
            maximumDecodeWorkingSetBytes: 1_024,
            maximumQueuedDecodes: 4
        )
        let request = try makeT100ProgressiveRequest("nil-session")
        let consumer = PipelineProgressivePreviewConsumer(
            decodeStage: stage,
            request: request,
            resourceRecorder: recorder,
            resourceOwnerID: ownerID,
            publish: { _ in }
        )
        let task = Task { await consumer.consume(relay) }

        relay.observe(.response(try makeT100JPEGHead(statusCode: 200)))
        relay.observe(.complete(digestHex: String(repeating: "a", count: 64), byteCount: 0))

        let candidate = await task.value
        XCTAssertNil(candidate)
        let transitions = recorder.snapshot().samples.map(\.transition)
        XCTAssertFalse(
            transitions.contains(.sessionBegin),
            "A nil ImageProgressiveDecodeSession must not create a logical session owner"
        )
        XCTAssertFalse(
            transitions.contains(.sessionEnd),
            "No session owner was created, so no synthetic session end should be recorded"
        )
    }

    func testRejectedReplacementResponsePreventsDataFromReachingOldSession_T100_RESOURCE_PT_002()
        async throws
    {
        let state = T100ProgressiveSessionState()
        let stage = DecodeStage(
            codec: T100TrackingProgressiveCodec(state: state),
            limits: .coreV1,
            diagnostics: NullDiagnosticsSink(),
            maximumConcurrentDecodes: 1,
            maximumDecodeWorkingSetBytes: 1_024,
            maximumQueuedDecodes: 4
        )
        let request = try makeT100ProgressiveRequest("replacement")
        let ownerID = UUID()
        let recorder = FoveaProgressiveResourceRecorder(
            capacity: 64,
            physicalFootprintProvider: { 0 }
        )
        let relay = TransportProgressRelay(
            maximumBufferedBytes: 1_024,
            resourceRecorder: recorder,
            resourceOwnerID: ownerID
        )
        let consumer = PipelineProgressivePreviewConsumer(
            decodeStage: stage,
            request: request,
            resourceRecorder: recorder,
            resourceOwnerID: ownerID,
            publish: { _ in }
        )
        let task = Task { await consumer.consume(relay) }

        relay.observe(.response(try makeT100JPEGHead(statusCode: 200)))
        try await waitForT100ProgressiveState { state.createdSessionCount == 1 }

        relay.observe(.response(try makeT100JPEGHead(statusCode: 404)))
        relay.observe(.data(Data([1, 2, 3]), cumulativeByteCount: 3))
        relay.observe(.complete(digestHex: String(repeating: "b", count: 64), byteCount: 3))

        _ = await task.value
        XCTAssertEqual(
            state.appendCount,
            0,
            "Data after a rejected replacement response must not reach the stale prior session"
        )
        XCTAssertEqual(state.createdSessionCount, 1)
        XCTAssertGreaterThanOrEqual(state.cancelCount, 1)
    }
}

private struct T100NonProgressiveCodec: TestImageCodec {
    func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
        throw ImageCraftError.decodeFailed
    }

    func decode(
        data: Data,
        probe: ImageProbe,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage {
        throw ImageCraftError.decodeFailed
    }
}

private final class T100TrackingProgressiveCodec:
    ImageCodec, ProgressiveImageDecoding, @unchecked Sendable
{
    let codecDescriptor = ImageCodecDescriptor(
        identifier: ImageCodecIdentifier(rawValue: "test.t100.progressive-session-ownership"),
        implementationVersion: 1,
        capabilities: ImageCodecCapabilities(
            formats: [.jpeg],
            deliveryModes: [.completeFrame, .progressiveGenerations],
            progressiveFormats: [.jpeg],
            trackModes: [.primaryFrame],
            metadata: [.orientation, .sourceColorProfile],
            dynamicRanges: [.standard],
            outputRepresentations: [.coreGraphicsImage],
            cancellationMode: .operationBoundary
        )
    )

    private let state: T100ProgressiveSessionState

    init(state: T100ProgressiveSessionState) {
        self.state = state
    }

    func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
        throw ImageCraftError.decodeFailed
    }

    func decode(
        data: Data,
        probe: ImageProbe,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage {
        throw ImageCraftError.decodeFailed
    }

    func makeProgressiveSession(
        format: EncodedImageFormat,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> any ImageProgressiveDecodeSession {
        guard format == .jpeg else { throw ImageCraftError.progressiveDecodingUnsupported }
        state.recordCreated()
        return Session(state: state)
    }

    private final class Session: ImageProgressiveDecodeSession, @unchecked Sendable {
        private let state: T100ProgressiveSessionState
        private let lock = NSLock()
        private var byteCount = 0

        init(state: T100ProgressiveSessionState) {
            self.state = state
        }

        var receivedByteCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return byteCount
        }

        func append(_ chunk: Data) throws -> ImageProgressiveDecodeGeneration? {
            lock.lock()
            byteCount += chunk.count
            lock.unlock()
            state.recordAppend()
            return nil
        }

        func finish() throws {
            state.recordFinish()
        }

        func cancel() {
            state.recordCancel()
        }
    }
}

private final class T100ProgressiveSessionState: @unchecked Sendable {
    private let lock = NSLock()
    private var created = 0
    private var appended = 0
    private var cancelled = 0
    private var finished = 0

    var createdSessionCount: Int { locked { created } }
    var appendCount: Int { locked { appended } }
    var cancelCount: Int { locked { cancelled } }
    var finishCount: Int { locked { finished } }

    func recordCreated() { locked { created += 1 } }
    func recordAppend() { locked { appended += 1 } }
    func recordCancel() { locked { cancelled += 1 } }
    func recordFinish() { locked { finished += 1 } }

    @discardableResult
    private func locked<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private func makeT100ProgressiveRequest(_ suffix: String) throws -> ImageRequest {
    try ImageRequest.publicImage(
        url: XCTUnwrap(URL(string: "https://example.test/t100-progressive-\(suffix).jpg")),
        target: TargetPixels(width: 8, height: 8),
        appID: "t100-progressive-session-ownership"
    )
}

private func makeT100JPEGHead(statusCode: Int) throws -> TransportResponseHead {
    try TransportResponseHead(
        statusCode: statusCode,
        headers: ["Content-Type": "image/jpeg"],
        url: XCTUnwrap(URL(string: "https://example.test/t100-progressive.jpg"))
    )
}

private func waitForT100ProgressiveState(
    _ condition: @escaping @Sendable () -> Bool
) async throws {
    let deadline = testDeadline(after: .seconds(1))
    while !condition() {
        guard testUptimeNanoseconds() < deadline else {
            XCTFail("timed out waiting for progressive session state")
            return
        }
        await Task.yield()
    }
}
