import Foundation
import FoveaHTTP
import XCTest

@testable import FoveaCore

final class ProgressiveResourceEnvelopeTests: XCTestCase {
    func testRelayTransfersPendingBytesIntoHandoff_H013_PT_001() async throws {
        let recorder = FoveaProgressiveResourceRecorder(
            capacity: 128,
            physicalFootprintProvider: { 1_000_000 }
        )
        let ownerID = UUID()
        recorder.beginRelay(ownerID: ownerID)
        let relay = TransportProgressRelay(
            maximumBufferedBytes: 1_024,
            transportMemoryThreshold: 8,
            resourceRecorder: recorder,
            resourceOwnerID: ownerID
        )
        let head = try TransportResponseHead(
            statusCode: 200,
            headers: ["Content-Type": "image/jpeg"],
            url: URL(string: "https://example.test/image.jpg")
        )

        relay.observe(.response(head))
        relay.observe(.data(Data(repeating: 7, count: 4), cumulativeByteCount: 4))

        _ = await relay.next()
        let dataEvent = await relay.next()
        guard case .data(let data, let cumulativeByteCount) = dataEvent else {
            return XCTFail("Expected relay data event")
        }
        XCTAssertEqual(data.count, 4)
        XCTAssertEqual(cumulativeByteCount, 4)

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.relayPendingBytes, 0)
        XCTAssertEqual(snapshot.progressHandoffBytes, 4)
        XCTAssertEqual(snapshot.transportLogicalBytes, 4)
        XCTAssertTrue(
            snapshot.samples.contains {
                $0.transition == .transportBeforeProgressCallback
                    && $0.transportLogicalBytes == 8
            }
        )
        XCTAssertTrue(
            snapshot.samples.contains {
                $0.transition == .relayEnqueue && $0.relayPendingBytes == 4
            }
        )
        XCTAssertTrue(
            snapshot.samples.contains {
                $0.transition == .relayDequeue
                    && $0.relayPendingBytes == 0
                    && $0.progressHandoffBytes == 4
            }
        )

        recorder.clearHandoff(ownerID: ownerID)
        relay.finish()
        let drained = recorder.snapshot()
        XCTAssertEqual(drained.activeTransportOwnerCount, 0)
        XCTAssertEqual(drained.activeRelayOwnerCount, 0)
        XCTAssertEqual(drained.progressHandoffBytes, 0)
    }

    func testRecorderReturnsEveryOwnerToZeroAndBoundsSamples_H013_PT_002() {
        let recorder = FoveaProgressiveResourceRecorder(
            capacity: 10,
            physicalFootprintProvider: { 2_000_000 }
        )
        let ownerID = UUID()

        recorder.recordBaseline()
        recorder.beginTransport(ownerID: ownerID)
        recorder.beginRelay(ownerID: ownerID)
        recorder.setTransportBytes(
            12,
            ownerID: ownerID,
            transition: .transportBeforeProgressCallback
        )
        recorder.setRelayPendingBytes(4, ownerID: ownerID)
        recorder.transferRelayToHandoff(4, ownerID: ownerID)
        recorder.beginSession(ownerID: ownerID)
        recorder.setSessionBytes(20, ownerID: ownerID)
        recorder.clearHandoff(ownerID: ownerID)
        recorder.setPreviewBytes(30, ownerID: ownerID)
        recorder.endSession(ownerID: ownerID)
        recorder.clearPreview(ownerID: ownerID)
        recorder.endRelay(ownerID: ownerID)
        recorder.endTransport(ownerID: ownerID)
        recorder.recordAllRequestsDrained()

        let snapshot = recorder.snapshot()
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
        XCTAssertEqual(snapshot.samples.count, 10)
        XCTAssertGreaterThan(snapshot.droppedSampleCount, 0)
        XCTAssertTrue(
            snapshot.samples.contains {
                $0.hostVisibleLogicalBytes >= 36
                    && $0.taskPhysicalFootprintBytes == 2_000_000
            }
        )
    }

    func testPreparationLeaseTransfersSessionChargeAndReleasesExactlyOnce_H013_PT_003() {
        let recorder = FoveaProgressiveResourceRecorder(
            capacity: 32,
            physicalFootprintProvider: { 3_000_000 }
        )
        let ownerID = UUID()
        recorder.beginSession(ownerID: ownerID)
        recorder.setSessionBytes(370_199, ownerID: ownerID)

        let lease = FoveaProgressivePreparationResourceLease(
            recorder: recorder,
            ownerID: ownerID,
            byteCount: 370_199
        )
        let transferred = recorder.snapshot()
        XCTAssertEqual(transferred.activeSessionCount, 0)
        XCTAssertEqual(transferred.sessionEncodedBytes, 0)
        XCTAssertEqual(transferred.activePreparationOwnerCount, 1)
        XCTAssertEqual(transferred.preparationEncodedBytes, 370_199)
        XCTAssertEqual(transferred.samples.last?.transition, .preparationTransferred)
        XCTAssertEqual(transferred.samples.last?.hostVisibleLogicalBytes, 370_199)

        lease.release()
        lease.release()
        let released = recorder.snapshot()
        XCTAssertEqual(released.activePreparationOwnerCount, 0)
        XCTAssertEqual(released.preparationEncodedBytes, 0)
        XCTAssertEqual(
            released.samples.filter { $0.transition == .preparationEnd }.count,
            1
        )
    }

    func testRecorderSeparatesCurrentAndKernelLifetimePeak_H013_PT_004() {
        let observations = ProgressiveFootprintObservationSequence([
            (current: 10, lifetimePeak: 10),
            (current: 20, lifetimePeak: 20),
            (current: 5, lifetimePeak: 20),
        ])
        let recorder = FoveaProgressiveResourceRecorder(
            capacity: 8,
            taskFootprintProvider: { observations.next() }
        )

        recorder.recordBaseline()
        recorder.beginSession(ownerID: UUID())
        recorder.recordPeriodicFootprint()

        let samples = recorder.snapshot().samples
        XCTAssertEqual(samples.map(\.taskPhysicalFootprintBytes), [10, 20, 5])
        XCTAssertEqual(samples.map(\.taskPhysicalFootprintLifetimePeakBytes), [10, 20, 20])
    }

    func testPreparationBarrierWaitsForAllConfiguredArrivals_H013_PT_005() async {
        let recorder = FoveaProgressiveResourceRecorder(
            capacity: 16,
            taskFootprintProvider: {
                FoveaProgressiveResourceRecorder.TaskFootprintObservation(
                    currentBytes: 100,
                    lifetimePeakBytes: 100
                )
            },
            preparationBarrierTarget: 2
        )
        let completion = ProgressiveCompletionFlag()
        let first = Task {
            await recorder.waitAtPreparationBarrierIfConfigured()
            completion.markCompleted()
        }

        await waitForPreparationBarrierArrival(recorder, minimum: 1)
        XCTAssertFalse(completion.isCompleted)

        let second = Task {
            await recorder.waitAtPreparationBarrierIfConfigured()
        }
        await second.value
        await first.value

        let state = recorder.preparationBarrierStateForTesting()
        XCTAssertEqual(state.arrivalCount, 2)
        XCTAssertTrue(state.ready)
        XCTAssertFalse(state.aborted)
        XCTAssertTrue(completion.isCompleted)
        XCTAssertEqual(
            recorder.snapshot().samples.filter {
                $0.transition == .progressivePhaseBarrierReady
            }.count,
            1
        )
    }

    func testPreparationBarrierAbortReleasesWaitersWithoutReadySample_H013_PT_006() async {
        let recorder = FoveaProgressiveResourceRecorder(
            capacity: 16,
            taskFootprintProvider: {
                FoveaProgressiveResourceRecorder.TaskFootprintObservation(
                    currentBytes: 100,
                    lifetimePeakBytes: 100
                )
            },
            preparationBarrierTarget: 2
        )
        let completion = ProgressiveCompletionFlag()
        let waiter = Task {
            await recorder.waitAtPreparationBarrierIfConfigured()
            completion.markCompleted()
        }

        await waitForPreparationBarrierArrival(recorder, minimum: 1)
        XCTAssertFalse(completion.isCompleted)
        recorder.abortPreparationBarrierIfConfigured()
        await waiter.value

        let state = recorder.preparationBarrierStateForTesting()
        XCTAssertEqual(state.arrivalCount, 1)
        XCTAssertFalse(state.ready)
        XCTAssertTrue(state.aborted)
        XCTAssertTrue(completion.isCompleted)
        XCTAssertFalse(
            recorder.snapshot().samples.contains {
                $0.transition == .progressivePhaseBarrierReady
            }
        )
    }

    func testPreparationBarrierReadySampleCarriesAllPreparationOwners_H013_PT_007() async {
        let recorder = FoveaProgressiveResourceRecorder(
            capacity: 32,
            taskFootprintProvider: {
                FoveaProgressiveResourceRecorder.TaskFootprintObservation(
                    currentBytes: 100,
                    lifetimePeakBytes: 120
                )
            },
            preparationBarrierTarget: 2
        )
        let ownerA = UUID()
        let ownerB = UUID()
        recorder.beginSession(ownerID: ownerA)
        recorder.setSessionBytes(11, ownerID: ownerA)
        let leaseA = FoveaProgressivePreparationResourceLease(
            recorder: recorder,
            ownerID: ownerA,
            byteCount: 11
        )

        let completion = ProgressiveCompletionFlag()
        let first = Task {
            await recorder.waitAtPreparationBarrierIfConfigured()
            completion.markCompleted()
        }
        await waitForPreparationBarrierArrival(recorder, minimum: 1)
        XCTAssertFalse(completion.isCompleted)

        recorder.beginSession(ownerID: ownerB)
        recorder.setSessionBytes(13, ownerID: ownerB)
        let leaseB = FoveaProgressivePreparationResourceLease(
            recorder: recorder,
            ownerID: ownerB,
            byteCount: 13
        )
        let second = Task {
            await recorder.waitAtPreparationBarrierIfConfigured()
        }
        await second.value
        await first.value

        let readySamples = recorder.snapshot().samples.filter {
            $0.transition == .progressivePhaseBarrierReady
        }
        XCTAssertEqual(readySamples.count, 1)
        XCTAssertEqual(readySamples[0].activePreparationOwnerCount, 2)
        XCTAssertEqual(readySamples[0].preparationEncodedBytes, 24)
        XCTAssertEqual(readySamples[0].taskPhysicalFootprintLifetimePeakBytes, 120)
        XCTAssertTrue(completion.isCompleted)

        leaseA.release()
        leaseB.release()
    }

    private func waitForPreparationBarrierArrival(
        _ recorder: FoveaProgressiveResourceRecorder,
        minimum: Int
    ) async {
        for _ in 0..<10_000 {
            if recorder.preparationBarrierStateForTesting().arrivalCount >= minimum { return }
            await Task.yield()
        }
        XCTFail("preparation barrier arrival did not become observable")
    }
}

private final class ProgressiveCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var isCompleted: Bool {
        lock.withLock { completed }
    }

    func markCompleted() {
        lock.withLock { completed = true }
    }
}

private final class ProgressiveFootprintObservationSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let observations: [(current: UInt64, lifetimePeak: UInt64)]
    private var index = 0

    init(_ observations: [(current: UInt64, lifetimePeak: UInt64)]) {
        precondition(!observations.isEmpty)
        self.observations = observations
    }

    func next() -> FoveaProgressiveResourceRecorder.TaskFootprintObservation {
        lock.withLock {
            let observation = observations[min(index, observations.count - 1)]
            index += 1
            return FoveaProgressiveResourceRecorder.TaskFootprintObservation(
                currentBytes: observation.current,
                lifetimePeakBytes: observation.lifetimePeak
            )
        }
    }
}
