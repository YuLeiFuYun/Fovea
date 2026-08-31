import Darwin
import Foundation

/// H013 default-off progressive resource attribution transition.
package enum FoveaProgressiveResourceTransition: String, Codable, Sendable {
    case baselineAfterSetup = "baseline-after-setup"
    case transportOwnerBegin = "transport-owner-begin"
    case transportBeforeProgressCallback = "transport-before-progress-callback"
    case transportAfterProgressCallback = "transport-after-progress-callback"
    case relayEnqueue = "relay-enqueue"
    case relayDequeue = "relay-dequeue"
    case sessionBegin = "session-begin"
    case sessionAfterAppend = "session-after-append"
    case preparationTransferred = "preparation-transferred"
    case preparationEnd = "preparation-end"
    case progressivePhaseBarrierReady = "progressive-phase-barrier-ready"
    case periodicFootprint = "periodic-footprint"
    case previewPublished = "preview-published"
    case sessionEnd = "session-end"
    case relayEnd = "relay-end"
    case transportEnd = "transport-end"
    case allRequestsDrained = "all-requests-drained"
}

/// One source-ordered H013 owner-state sample.
///
/// Logical byte columns are accounting owners, not physical-page ownership. In particular,
/// Data/CGImage/provider storage may alias allocator or framework pages. `taskPhysicalFootprintBytes`
/// is therefore kept as an independent task-level observation rather than being subtracted here.
package struct FoveaProgressiveResourceSample: Codable, Equatable, Sendable {
    package let sequence: UInt64
    package let uptimeNanoseconds: UInt64
    package let transition: FoveaProgressiveResourceTransition
    package let activeTransportOwnerCount: Int
    package let activeRelayOwnerCount: Int
    package let activeSessionCount: Int
    package let activePreparationOwnerCount: Int
    package let activePreviewOwnerCount: Int
    package let transportLogicalBytes: Int
    package let relayPendingBytes: Int
    package let progressHandoffBytes: Int
    package let sessionEncodedBytes: Int
    package let preparationEncodedBytes: Int
    package let previewLogicalBytes: Int
    package let hostVisibleLogicalBytes: Int
    package let taskPhysicalFootprintBytes: UInt64?
    package let taskPhysicalFootprintLifetimePeakBytes: UInt64?
}

package struct FoveaProgressiveResourceSnapshot: Codable, Equatable, Sendable {
    package let samples: [FoveaProgressiveResourceSample]
    package let droppedSampleCount: UInt64
    package let activeTransportOwnerCount: Int
    package let activeRelayOwnerCount: Int
    package let activeSessionCount: Int
    package let activePreparationOwnerCount: Int
    package let activePreviewOwnerCount: Int
    package let transportLogicalBytes: Int
    package let relayPendingBytes: Int
    package let progressHandoffBytes: Int
    package let sessionEncodedBytes: Int
    package let preparationEncodedBytes: Int
    package let previewLogicalBytes: Int
}

/// Package-only, fixed-capacity H013 recorder.
///
/// Production construction paths pass `nil`, so they do not sample clocks/footprint or take this
/// lock. The recorder deliberately accepts independent UUIDs for transport/relay/session/preview
/// owners: the experiment needs simultaneous aggregate residency, not a new cross-layer identity
/// contract.
package final class FoveaProgressiveResourceRecorder: @unchecked Sendable {
    package struct TaskFootprintObservation: Sendable {
        package let currentBytes: UInt64?
        package let lifetimePeakBytes: UInt64?
    }

    package typealias PhysicalFootprintProvider = @Sendable () -> UInt64?
    package typealias TaskFootprintProvider = @Sendable () -> TaskFootprintObservation

    private let lock = NSLock()
    private let capacity: Int
    private let taskFootprintProvider: TaskFootprintProvider
    private let preparationBarrierTarget: Int?
    private var preparationBarrierArrivalCount = 0
    private var preparationBarrierReady = false
    private var preparationBarrierAborted = false
    private var preparationBarrierWaiters: [CheckedContinuation<Void, Never>] = []
    private var sequence: UInt64 = 0
    private var droppedSampleCount: UInt64 = 0
    private var samples: [FoveaProgressiveResourceSample] = []
    private var transportBytes: [UUID: Int] = [:]
    private var relayBytes: [UUID: Int] = [:]
    private var handoffBytes: [UUID: Int] = [:]
    private var sessionBytes: [UUID: Int] = [:]
    private var preparationBytes: [UUID: Int] = [:]
    private var previewBytes: [UUID: Int] = [:]

    package convenience init(
        capacity: Int = 8_192,
        preparationBarrierTarget: Int? = nil
    ) {
        self.init(
            capacity: capacity,
            taskFootprintProvider: FoveaProgressiveResourceRecorder.liveTaskFootprint,
            preparationBarrierTarget: preparationBarrierTarget
        )
    }

    package convenience init(
        capacity: Int,
        physicalFootprintProvider: @escaping PhysicalFootprintProvider
    ) {
        self.init(
            capacity: capacity,
            taskFootprintProvider: {
                TaskFootprintObservation(
                    currentBytes: physicalFootprintProvider(),
                    lifetimePeakBytes: nil
                )
            }
        )
    }

    package init(
        capacity: Int,
        taskFootprintProvider: @escaping TaskFootprintProvider,
        preparationBarrierTarget: Int? = nil
    ) {
        self.capacity = max(1, capacity)
        self.taskFootprintProvider = taskFootprintProvider
        self.preparationBarrierTarget = preparationBarrierTarget.map { max(1, $0) }
        samples.reserveCapacity(min(max(1, capacity), 8_192))
    }

    package func recordBaseline() {
        mutate(.baselineAfterSetup) {}
    }

    package func beginTransport(ownerID: UUID) {
        mutate(.transportOwnerBegin) {
            transportBytes[ownerID] = 0
        }
    }

    package func setTransportBytes(
        _ bytes: Int,
        ownerID: UUID,
        transition: FoveaProgressiveResourceTransition
    ) {
        precondition(
            transition == .transportBeforeProgressCallback
                || transition == .transportAfterProgressCallback,
            "invalid transport-byte transition"
        )
        mutate(transition) {
            transportBytes[ownerID] = max(0, bytes)
        }
    }

    package func endTransport(ownerID: UUID) {
        mutate(.transportEnd) {
            transportBytes.removeValue(forKey: ownerID)
        }
    }

    package func beginRelay(ownerID: UUID) {
        mutate(.relayEnqueue) {
            relayBytes[ownerID] = 0
        }
    }

    package func setRelayPendingBytes(_ bytes: Int, ownerID: UUID) {
        mutate(.relayEnqueue) {
            relayBytes[ownerID] = max(0, bytes)
        }
    }

    package func transferRelayToHandoff(_ bytes: Int, ownerID: UUID) {
        mutate(.relayDequeue) {
            relayBytes[ownerID] = 0
            if bytes > 0 {
                handoffBytes[ownerID] = bytes
            } else {
                handoffBytes.removeValue(forKey: ownerID)
            }
        }
    }

    package func clearHandoff(ownerID: UUID) {
        mutate(.sessionAfterAppend) {
            handoffBytes.removeValue(forKey: ownerID)
        }
    }

    package func endRelay(ownerID: UUID) {
        mutate(.relayEnd) {
            relayBytes.removeValue(forKey: ownerID)
            handoffBytes.removeValue(forKey: ownerID)
        }
    }

    package func beginSession(ownerID: UUID) {
        mutate(.sessionBegin) {
            sessionBytes[ownerID] = 0
        }
    }

    package func setSessionBytes(_ bytes: Int, ownerID: UUID) {
        mutate(.sessionAfterAppend) {
            sessionBytes[ownerID] = max(0, bytes)
        }
    }

    package func endSession(ownerID: UUID) {
        mutate(.sessionEnd) {
            sessionBytes.removeValue(forKey: ownerID)
            handoffBytes.removeValue(forKey: ownerID)
        }
    }

    package func transferSessionToPreparation(_ bytes: Int, ownerID: UUID) {
        mutate(.preparationTransferred) {
            sessionBytes.removeValue(forKey: ownerID)
            handoffBytes.removeValue(forKey: ownerID)
            preparationBytes[ownerID] = max(0, bytes)
        }
    }

    package func endPreparation(ownerID: UUID) {
        mutate(.preparationEnd) {
            preparationBytes.removeValue(forKey: ownerID)
        }
    }

    package func setPreviewBytes(_ bytes: Int, ownerID: UUID) {
        mutate(.previewPublished) {
            if bytes > 0 {
                previewBytes[ownerID] = bytes
            } else {
                previewBytes.removeValue(forKey: ownerID)
            }
        }
    }

    package func clearPreview(ownerID: UUID) {
        mutate(.previewPublished) {
            previewBytes.removeValue(forKey: ownerID)
        }
    }

    package func recordPeriodicFootprint() {
        mutate(.periodicFootprint) {}
    }

    package func waitAtPreparationBarrierIfConfigured() async {
        guard let preparationBarrierTarget else { return }
        await withCheckedContinuation { continuation in
            var waitersToResume: [CheckedContinuation<Void, Never>] = []
            var reachedBarrier = false

            lock.lock()
            if preparationBarrierAborted || preparationBarrierReady {
                lock.unlock()
                continuation.resume()
                return
            }
            precondition(preparationBarrierArrivalCount < preparationBarrierTarget)
            preparationBarrierArrivalCount += 1
            if preparationBarrierArrivalCount == preparationBarrierTarget {
                preparationBarrierReady = true
                reachedBarrier = true
                waitersToResume = preparationBarrierWaiters
                preparationBarrierWaiters.removeAll(keepingCapacity: false)
            } else {
                preparationBarrierWaiters.append(continuation)
            }
            lock.unlock()

            guard reachedBarrier else { return }
            // No waiter is resumed until after this sample, so no prepared final decode can start.
            mutate(.progressivePhaseBarrierReady) {}
            continuation.resume()
            for waiter in waitersToResume { waiter.resume() }
        }
    }

    package func abortPreparationBarrierIfConfigured() {
        guard preparationBarrierTarget != nil else { return }
        var waitersToResume: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        guard !preparationBarrierReady, !preparationBarrierAborted else {
            lock.unlock()
            return
        }
        preparationBarrierAborted = true
        waitersToResume = preparationBarrierWaiters
        preparationBarrierWaiters.removeAll(keepingCapacity: false)
        lock.unlock()
        for waiter in waitersToResume { waiter.resume() }
    }

    package func preparationBarrierStateForTesting() -> (
        arrivalCount: Int,
        ready: Bool,
        aborted: Bool
    ) {
        lock.withLock {
            (
                preparationBarrierArrivalCount,
                preparationBarrierReady,
                preparationBarrierAborted
            )
        }
    }

    package func recordAllRequestsDrained() {
        mutate(.allRequestsDrained) {}
    }

    package func snapshot() -> FoveaProgressiveResourceSnapshot {
        lock.withLock {
            FoveaProgressiveResourceSnapshot(
                samples: samples,
                droppedSampleCount: droppedSampleCount,
                activeTransportOwnerCount: transportBytes.count,
                activeRelayOwnerCount: relayBytes.count,
                activeSessionCount: sessionBytes.count,
                activePreparationOwnerCount: preparationBytes.count,
                activePreviewOwnerCount: previewBytes.count,
                transportLogicalBytes: saturatedSum(transportBytes.values),
                relayPendingBytes: saturatedSum(relayBytes.values),
                progressHandoffBytes: saturatedSum(handoffBytes.values),
                sessionEncodedBytes: saturatedSum(sessionBytes.values),
                preparationEncodedBytes: saturatedSum(preparationBytes.values),
                previewLogicalBytes: saturatedSum(previewBytes.values)
            )
        }
    }

    private func mutate(
        _ transition: FoveaProgressiveResourceTransition,
        operation: () -> Void
    ) {
        let footprint = taskFootprintProvider()
        let uptime = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        operation()
        let transport = saturatedSum(transportBytes.values)
        let relay = saturatedSum(relayBytes.values)
        let handoff = saturatedSum(handoffBytes.values)
        let session = saturatedSum(sessionBytes.values)
        let preparation = saturatedSum(preparationBytes.values)
        let preview = saturatedSum(previewBytes.values)
        let visible = saturatedSum([transport, relay, handoff, session, preparation, preview])
        let currentSequence = sequence
        sequence = saturatedIncrement(sequence)
        let sample = FoveaProgressiveResourceSample(
            sequence: currentSequence,
            uptimeNanoseconds: uptime,
            transition: transition,
            activeTransportOwnerCount: transportBytes.count,
            activeRelayOwnerCount: relayBytes.count,
            activeSessionCount: sessionBytes.count,
            activePreparationOwnerCount: preparationBytes.count,
            activePreviewOwnerCount: previewBytes.count,
            transportLogicalBytes: transport,
            relayPendingBytes: relay,
            progressHandoffBytes: handoff,
            sessionEncodedBytes: session,
            preparationEncodedBytes: preparation,
            previewLogicalBytes: preview,
            hostVisibleLogicalBytes: visible,
            taskPhysicalFootprintBytes: footprint.currentBytes,
            taskPhysicalFootprintLifetimePeakBytes: footprint.lifetimePeakBytes
        )
        if samples.count < capacity {
            samples.append(sample)
        } else {
            droppedSampleCount = saturatedIncrement(droppedSampleCount)
        }
        lock.unlock()
    }

    private func saturatedSum<S: Sequence>(_ values: S) -> Int where S.Element == Int {
        values.reduce(0) { partial, value in
            let result = partial.addingReportingOverflow(max(0, value))
            return result.overflow ? Int.max : result.partialValue
        }
    }

    private func saturatedIncrement(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? UInt64.max : value + 1
    }

    private static func liveTaskFootprint() -> TaskFootprintObservation {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return TaskFootprintObservation(currentBytes: nil, lifetimePeakBytes: nil)
        }
        let current = info.phys_footprint
        let rawLifetimePeak = info.ledger_phys_footprint_peak
        let lifetimePeak: UInt64?
        if rawLifetimePeak > 0 {
            let candidate = UInt64(rawLifetimePeak)
            lifetimePeak = candidate >= current ? candidate : nil
        } else {
            lifetimePeak = nil
        }
        return TaskFootprintObservation(
            currentBytes: current,
            lifetimePeakBytes: lifetimePeak
        )
    }
}

/// H013-only lifetime token for ImageCraft prepared state retained after progressive finish.
/// The token is idempotent because decode/discard/cancellation paths may converge on the same
/// one-shot ImageDecodePreparation.
package final class FoveaProgressivePreparationResourceLease: @unchecked Sendable {
    private let lock = NSLock()
    private let recorder: FoveaProgressiveResourceRecorder
    private let ownerID: UUID
    private var released = false

    package init(
        recorder: FoveaProgressiveResourceRecorder,
        ownerID: UUID,
        byteCount: Int
    ) {
        self.recorder = recorder
        self.ownerID = ownerID
        recorder.transferSessionToPreparation(byteCount, ownerID: ownerID)
    }

    package func release() {
        let shouldRelease = lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        guard shouldRelease else { return }
        recorder.endPreparation(ownerID: ownerID)
    }
}
