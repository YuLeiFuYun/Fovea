import Dispatch
import Foundation
import FoveaHTTP
import ImageCraftCore
import XCTest

@testable import FoveaCore

final class T100ResourceSpineAdoptionTests: XCTestCase {
    func testProgressiveResourceRecorderSaturatesAndReturnsEveryOwnerToZero_T100_AUTH_PT_011() {
        let recorder = FoveaProgressiveResourceRecorder(
            capacity: 4,
            physicalFootprintProvider: { 0 }
        )
        let transportOwner = UUID()
        let sessionOwner = UUID()

        recorder.beginTransport(ownerID: transportOwner)
        recorder.setTransportBytes(
            Int.max,
            ownerID: transportOwner,
            transition: .transportAfterProgressCallback
        )
        recorder.beginSession(ownerID: sessionOwner)
        recorder.setSessionBytes(Int.max, ownerID: sessionOwner)

        var snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.samples.last?.hostVisibleLogicalBytes, Int.max)
        XCTAssertEqual(snapshot.activeTransportOwnerCount, 1)
        XCTAssertEqual(snapshot.activeSessionCount, 1)

        recorder.endTransport(ownerID: transportOwner)
        recorder.endSession(ownerID: sessionOwner)
        snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.activeTransportOwnerCount, 0)
        XCTAssertEqual(snapshot.activeRelayOwnerCount, 0)
        XCTAssertEqual(snapshot.activeSessionCount, 0)
        XCTAssertEqual(snapshot.activePreparationOwnerCount, 0)
        XCTAssertEqual(snapshot.activePreviewOwnerCount, 0)
        XCTAssertEqual(snapshot.transportLogicalBytes, 0)
        XCTAssertEqual(snapshot.relayPendingBytes, 0)
        XCTAssertEqual(snapshot.progressHandoffBytes, 0)
        XCTAssertEqual(snapshot.sessionEncodedBytes, 0)
        XCTAssertEqual(snapshot.preparationEncodedBytes, 0)
        XCTAssertEqual(snapshot.previewLogicalBytes, 0)
        XCTAssertEqual(snapshot.samples.count, 4)
        XCTAssertGreaterThan(snapshot.droppedSampleCount, 0)
    }

    func testPreparationResourceLeaseTransfersAndReleasesIdempotently_T100_AUTH_PT_012() {
        let recorder = FoveaProgressiveResourceRecorder(
            capacity: 32,
            physicalFootprintProvider: { 0 }
        )
        let ownerID = UUID()
        recorder.beginSession(ownerID: ownerID)
        recorder.setSessionBytes(17, ownerID: ownerID)

        let lease = FoveaProgressivePreparationResourceLease(
            recorder: recorder,
            ownerID: ownerID,
            byteCount: 17
        )
        var snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.activeSessionCount, 0)
        XCTAssertEqual(snapshot.activePreparationOwnerCount, 1)
        XCTAssertEqual(snapshot.preparationEncodedBytes, 17)

        lease.release()
        lease.release()
        snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.activePreparationOwnerCount, 0)
        XCTAssertEqual(snapshot.preparationEncodedBytes, 0)
    }

    func
        testProgressivePermitRoutingHoldsLocalWhileQueuedGlobalAndReleasesOnThrow_T100_AUTH_PT_013()
        async throws
    {
        let localDecode = AsyncPermitPool(limit: 2, queueLimit: 8)
        let globalDecode = AsyncPermitPool(limit: 1, queueLimit: 8)
        let controller = FoveaDecodePermitController(
            diagnostics: NullDiagnosticsSink(),
            maximumConcurrentDecodes: 2,
            maximumDecodeWorkingSetBytes: 1,
            maximumQueuedDecodes: 8,
            decodePermits: localDecode,
            workingSetPermits: nil,
            globalDecodePermits: globalDecode,
            globalWorkingSetPermits: nil
        )
        let blocker = try await globalDecode.acquire()
        let probe = T100SpineEntryProbe()
        let first = Task {
            try await controller.withProgressiveDecodePermits(priority: .normal, workEstimate: 1) {
                await probe.recordEntry()
                return 1
            }
        }
        let second = Task {
            try await controller.withProgressiveDecodePermits(priority: .normal, workEstimate: 1) {
                await probe.recordEntry()
                return 2
            }
        }

        try await waitForT100Spine {
            let local = await localDecode.usedUnits
            let queued = await globalDecode.queuedCount()
            return local == 2 && queued == 2
        }
        let blockedEntryCount = await probe.snapshot()
        XCTAssertEqual(blockedEntryCount, 0)
        await blocker.release()
        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual([firstValue, secondValue].sorted(), [1, 2])
        let finalEntryCount = await probe.snapshot()
        let finalLocalUsed = await localDecode.usedUnits
        let finalGlobalUsed = await globalDecode.usedUnits
        XCTAssertEqual(finalEntryCount, 2)
        XCTAssertEqual(finalLocalUsed, 0)
        XCTAssertEqual(finalGlobalUsed, 0)

        do {
            _ =
                try await controller.withProgressiveDecodePermits(
                    priority: .normal, workEstimate: 1
                ) {
                    throw T100SpineError.expected
                } as Int
            XCTFail("throwing operation must propagate")
        } catch T100SpineError.expected {
        }
        let localUsedAfterThrow = await localDecode.usedUnits
        let globalUsedAfterThrow = await globalDecode.usedUnits
        XCTAssertEqual(localUsedAfterThrow, 0)
        XCTAssertEqual(globalUsedAfterThrow, 0)
    }

    func testMeasuredRasterLifetimeRecordsSuccessButNotThrow_T100_AUTH_PT_014() async throws {
        let recorder = FoveaDecodePermitLifetimeRecorder()
        let priorityControl = SharedTaskPriorityControl(priority: .normal)
        let request = try makeT100SpineRequest("measured-raster")
        let controller = FoveaDecodePermitController(
            diagnostics: NullDiagnosticsSink(),
            maximumConcurrentDecodes: 1,
            maximumDecodeWorkingSetBytes: 32,
            maximumQueuedDecodes: 4,
            decodePermits: nil,
            workingSetPermits: nil,
            globalDecodePermits: nil,
            globalWorkingSetPermits: nil,
            lifetimeRecorder: recorder
        )

        let value = try await controller.withRasterPermits(
            bytes: 7,
            request: request,
            keyDigest: request.fetchBaseKey.digestHex,
            priorityControl: priorityControl
        ) {
            42
        }
        XCTAssertEqual(value, 42)
        var snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.completedOperationCount, 1)
        XCTAssertEqual(snapshot.admittedBytes, 7)
        XCTAssertGreaterThan(snapshot.localWorkingSetLeaseNanoseconds, 0)
        XCTAssertGreaterThan(snapshot.localDecodeLeaseNanoseconds, 0)

        do {
            _ =
                try await controller.withRasterPermits(
                    bytes: 11,
                    request: request,
                    keyDigest: request.fetchBaseKey.digestHex,
                    priorityControl: priorityControl
                ) {
                    throw T100SpineError.expected
                } as Int
            XCTFail("throwing raster operation must propagate")
        } catch T100SpineError.expected {
        }
        snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.completedOperationCount, 1)
        XCTAssertEqual(snapshot.admittedBytes, 7)
    }

    func testNilProgressiveSessionCreatesNoResourceOwner_T100_AUTH_PT_015() async throws {
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
            codec: T100SpineNonProgressiveCodec(),
            limits: .coreV1,
            diagnostics: NullDiagnosticsSink(),
            maximumConcurrentDecodes: 1,
            maximumDecodeWorkingSetBytes: 1_024,
            maximumQueuedDecodes: 4
        )
        let request = try makeT100SpineRequest("nil-session")
        let consumer = PipelineProgressivePreviewConsumer(
            decodeStage: stage,
            request: request,
            resourceRecorder: recorder,
            resourceOwnerID: ownerID,
            publish: { _ in }
        )
        let task = Task { await consumer.consume(relay) }
        relay.observe(.response(try makeT100SpineJPEGHead(statusCode: 200)))
        relay.observe(.complete(digestHex: String(repeating: "a", count: 64), byteCount: 0))
        let candidate = await task.value
        XCTAssertNil(candidate)
        let transitions = recorder.snapshot().samples.map(\.transition)
        XCTAssertFalse(transitions.contains(.sessionBegin))
        XCTAssertFalse(transitions.contains(.sessionEnd))
    }

    func testRejectedReplacementResponseCancelsOldSessionBeforeLaterData_T100_AUTH_PT_016()
        async throws
    {
        let state = T100SpineProgressiveState()
        let stage = DecodeStage(
            codec: T100SpineProgressiveCodec(state: state),
            limits: .coreV1,
            diagnostics: NullDiagnosticsSink(),
            maximumConcurrentDecodes: 1,
            maximumDecodeWorkingSetBytes: 1_024,
            maximumQueuedDecodes: 4
        )
        let request = try makeT100SpineRequest("replacement")
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
        let consumer = PipelineProgressivePreviewConsumer(
            decodeStage: stage,
            request: request,
            resourceRecorder: recorder,
            resourceOwnerID: ownerID,
            publish: { _ in }
        )
        let task = Task { await consumer.consume(relay) }

        relay.observe(.response(try makeT100SpineJPEGHead(statusCode: 200)))
        try await waitForT100SpineSync { state.createdSessionCount == 1 }
        relay.observe(.response(try makeT100SpineJPEGHead(statusCode: 404)))
        relay.observe(.data(Data([1, 2, 3]), cumulativeByteCount: 3))
        relay.observe(.complete(digestHex: String(repeating: "b", count: 64), byteCount: 3))
        _ = await task.value

        XCTAssertEqual(state.appendCount, 0)
        XCTAssertEqual(state.createdSessionCount, 1)
        XCTAssertGreaterThanOrEqual(state.cancelCount, 1)
    }

    func testRelayDequeuesPendingBytesIntoHandoffAndDrainsOwners_T100_AUTH_PT_017() async throws {
        let recorder = FoveaProgressiveResourceRecorder(
            capacity: 128,
            physicalFootprintProvider: { 0 }
        )
        let ownerID = UUID()
        recorder.beginRelay(ownerID: ownerID)
        let relay = TransportProgressRelay(
            maximumBufferedBytes: 1_024,
            transportMemoryThreshold: 8,
            resourceRecorder: recorder,
            resourceOwnerID: ownerID
        )
        relay.observe(.response(try makeT100SpineJPEGHead(statusCode: 200)))
        relay.observe(.data(Data(repeating: 7, count: 4), cumulativeByteCount: 4))

        _ = await relay.next()
        let dataEvent = await relay.next()
        guard case .data(let data, let cumulativeByteCount) = dataEvent else {
            return XCTFail("expected relay data event")
        }
        XCTAssertEqual(data.count, 4)
        XCTAssertEqual(cumulativeByteCount, 4)

        var snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.relayPendingBytes, 0)
        XCTAssertEqual(snapshot.progressHandoffBytes, 4)
        XCTAssertEqual(snapshot.transportLogicalBytes, 4)
        XCTAssertTrue(
            snapshot.samples.contains {
                $0.transition == .relayDequeue
                    && $0.relayPendingBytes == 0
                    && $0.progressHandoffBytes == 4
            }
        )

        recorder.clearHandoff(ownerID: ownerID)
        relay.finish()
        snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.activeTransportOwnerCount, 0)
        XCTAssertEqual(snapshot.activeRelayOwnerCount, 0)
        XCTAssertEqual(snapshot.progressHandoffBytes, 0)
    }
}

private enum T100SpineError: Error { case expected }

private actor T100SpineEntryProbe {
    private var entries = 0
    func recordEntry() { entries += 1 }
    func snapshot() -> Int { entries }
}

private struct T100SpineNonProgressiveCodec: ImageCodec {
    let codecDescriptor = ImageCodecDescriptor(
        identifier: ImageCodecIdentifier(rawValue: "test.t100.spine-non-progressive"),
        implementationVersion: 1,
        capabilities: ImageCodecCapabilities(
            formats: [.jpeg],
            deliveryModes: [.completeFrame],
            progressiveFormats: [],
            trackModes: [.primaryFrame],
            metadata: [.orientation, .sourceColorProfile],
            dynamicRanges: [.standard],
            outputRepresentations: [.coreGraphicsImage],
            cancellationMode: .operationBoundary
        )
    )

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

private final class T100SpineProgressiveCodec:
    ImageCodec, ProgressiveImageDecoding, @unchecked Sendable
{
    let codecDescriptor = ImageCodecDescriptor(
        identifier: ImageCodecIdentifier(rawValue: "test.t100.spine-progressive"),
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

    private let state: T100SpineProgressiveState
    init(state: T100SpineProgressiveState) { self.state = state }

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
        private let state: T100SpineProgressiveState
        private let lock = NSLock()
        private var byteCount = 0
        init(state: T100SpineProgressiveState) { self.state = state }
        var receivedByteCount: Int { lock.withLock { byteCount } }
        func append(_ chunk: Data) throws -> ImageProgressiveDecodeGeneration? {
            lock.withLock { byteCount += chunk.count }
            state.recordAppend()
            return nil
        }
        func finish() throws { state.recordFinish() }
        func cancel() { state.recordCancel() }
    }
}

private final class T100SpineProgressiveState: @unchecked Sendable {
    private let lock = NSLock()
    private var created = 0
    private var appended = 0
    private var cancelled = 0
    private var finished = 0
    var createdSessionCount: Int { lock.withLock { created } }
    var appendCount: Int { lock.withLock { appended } }
    var cancelCount: Int { lock.withLock { cancelled } }
    var finishCount: Int { lock.withLock { finished } }
    func recordCreated() { lock.withLock { created += 1 } }
    func recordAppend() { lock.withLock { appended += 1 } }
    func recordCancel() { lock.withLock { cancelled += 1 } }
    func recordFinish() { lock.withLock { finished += 1 } }
}

private func makeT100SpineRequest(_ suffix: String) throws -> ImageRequest {
    try ImageRequest.publicImage(
        url: XCTUnwrap(URL(string: "https://example.test/t100-spine-\(suffix).jpg")),
        target: TargetPixels(width: 8, height: 8),
        appID: "t100-resource-spine"
    )
}

private func makeT100SpineJPEGHead(statusCode: Int) throws -> TransportResponseHead {
    try TransportResponseHead(
        statusCode: statusCode,
        headers: ["Content-Type": "image/jpeg"],
        url: XCTUnwrap(URL(string: "https://example.test/t100-spine.jpg"))
    )
}

private func waitForT100Spine(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let started = DispatchTime.now().uptimeNanoseconds
    while !(await condition()) {
        if DispatchTime.now().uptimeNanoseconds &- started >= timeoutNanoseconds {
            XCTFail("timed out waiting for T100 resource-spine state")
            return
        }
        try await Task.sleep(nanoseconds: 100_000)
    }
}

private func waitForT100SpineSync(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    _ condition: @escaping @Sendable () -> Bool
) async throws {
    let started = DispatchTime.now().uptimeNanoseconds
    while !condition() {
        if DispatchTime.now().uptimeNanoseconds &- started >= timeoutNanoseconds {
            XCTFail("timed out waiting for T100 resource-spine state")
            return
        }
        try await Task.sleep(nanoseconds: 100_000)
    }
}
