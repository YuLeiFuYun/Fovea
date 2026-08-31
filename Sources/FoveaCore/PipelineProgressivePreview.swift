import Foundation
import FoveaHTTP
import ImageCraftCore

final class TransportProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBufferedBytes: Int
    private let transportMemoryThreshold: Int
    private let resourceRecorder: FoveaProgressiveResourceRecorder?
    private let resourceOwnerID: UUID?
    private var pendingResponse: TransportResponseHead?
    private var pendingData = Data()
    private var pendingCumulativeByteCount = 0
    private var pendingCompletion: (digestHex: String, byteCount: Int)?
    private var waiter: CheckedContinuation<TransportProgressEvent?, Never>?
    private var isFinished = false

    init(
        maximumBufferedBytes: Int,
        transportMemoryThreshold: Int = 1,
        resourceRecorder: FoveaProgressiveResourceRecorder? = nil,
        resourceOwnerID: UUID? = nil
    ) {
        self.maximumBufferedBytes = max(1, maximumBufferedBytes)
        self.transportMemoryThreshold = max(1, transportMemoryThreshold)
        self.resourceRecorder = resourceRecorder
        self.resourceOwnerID = resourceOwnerID
    }

    func observe(_ event: TransportProgressEvent) {
        var resume: (CheckedContinuation<TransportProgressEvent?, Never>, TransportProgressEvent?)?
        var beginTransport = false
        var transportBeforeCallbackBytes: Int?
        var transportAfterCallbackBytes: Int?
        var relayEnqueuedBytes: Int?
        var shouldEndRelay = false
        var shouldEndTransport = false

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        switch event {
        case .response(let head):
            pendingResponse = head
            beginTransport = true
        case .data(let data, let cumulativeByteCount):
            guard cumulativeByteCount <= maximumBufferedBytes,
                pendingData.count <= maximumBufferedBytes - data.count
            else {
                isFinished = true
                pendingResponse = nil
                pendingData.removeAll(keepingCapacity: false)
                pendingCompletion = nil
                shouldEndRelay = true
                shouldEndTransport = true
                if let waiter {
                    self.waiter = nil
                    resume = (waiter, nil)
                }
                lock.unlock()
                recordResourceTransitions(
                    beginTransport: false,
                    transportBeforeCallbackBytes: nil,
                    relayEnqueuedBytes: nil,
                    dequeuedEvent: nil,
                    transportAfterCallbackBytes: nil,
                    shouldEndRelay: shouldEndRelay,
                    shouldEndTransport: shouldEndTransport
                )
                resume?.0.resume(returning: resume?.1)
                return
            }
            pendingData.append(data)
            pendingCumulativeByteCount = cumulativeByteCount
            relayEnqueuedBytes = pendingData.count
            let accumulatorMemoryBytes =
                cumulativeByteCount <= transportMemoryThreshold ? cumulativeByteCount : 0
            transportBeforeCallbackBytes = saturatedAdd(accumulatorMemoryBytes, data.count)
            transportAfterCallbackBytes = accumulatorMemoryBytes
        case .complete(let digestHex, let byteCount):
            pendingCompletion = (digestHex, byteCount)
            // URLSessionTransport constructs/materializes TransportResponse before emitting
            // `.complete`, so the full encoded response is a live host-visible owner here.
            transportBeforeCallbackBytes = max(0, byteCount)
            transportAfterCallbackBytes = max(0, byteCount)
        }
        var dequeuedEvent: TransportProgressEvent?
        if let waiter, let next = popPendingLocked() {
            self.waiter = nil
            dequeuedEvent = next
            resume = (waiter, next)
        }
        lock.unlock()

        recordResourceTransitions(
            beginTransport: beginTransport,
            transportBeforeCallbackBytes: transportBeforeCallbackBytes,
            relayEnqueuedBytes: relayEnqueuedBytes,
            dequeuedEvent: dequeuedEvent,
            transportAfterCallbackBytes: transportAfterCallbackBytes,
            shouldEndRelay: shouldEndRelay,
            shouldEndTransport: shouldEndTransport
        )
        if let resume { resume.0.resume(returning: resume.1) }
    }

    func next() async -> TransportProgressEvent? {
        await withCheckedContinuation { continuation in
            var immediate: TransportProgressEvent??
            lock.lock()
            if let next = popPendingLocked() {
                immediate = .some(next)
            } else if isFinished {
                immediate = .some(nil)
            } else {
                precondition(waiter == nil, "TransportProgressRelay supports one consumer")
                waiter = continuation
            }
            lock.unlock()
            if let immediate {
                if let event = immediate {
                    recordDequeuedEvent(event)
                }
                continuation.resume(returning: immediate)
            }
        }
    }

    func finish() {
        var continuation: CheckedContinuation<TransportProgressEvent?, Never>?
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            if let resourceRecorder, let resourceOwnerID {
                resourceRecorder.endRelay(ownerID: resourceOwnerID)
                resourceRecorder.endTransport(ownerID: resourceOwnerID)
            }
            return
        }
        isFinished = true
        pendingResponse = nil
        pendingData.removeAll(keepingCapacity: false)
        pendingCompletion = nil
        continuation = waiter
        waiter = nil
        lock.unlock()
        if let resourceRecorder, let resourceOwnerID {
            resourceRecorder.endRelay(ownerID: resourceOwnerID)
            resourceRecorder.endTransport(ownerID: resourceOwnerID)
        }
        continuation?.resume(returning: nil)
    }

    private func recordResourceTransitions(
        beginTransport: Bool,
        transportBeforeCallbackBytes: Int?,
        relayEnqueuedBytes: Int?,
        dequeuedEvent: TransportProgressEvent?,
        transportAfterCallbackBytes: Int?,
        shouldEndRelay: Bool,
        shouldEndTransport: Bool
    ) {
        guard let resourceRecorder, let resourceOwnerID else { return }
        if beginTransport {
            resourceRecorder.beginTransport(ownerID: resourceOwnerID)
        }
        if let transportBeforeCallbackBytes {
            resourceRecorder.setTransportBytes(
                transportBeforeCallbackBytes,
                ownerID: resourceOwnerID,
                transition: .transportBeforeProgressCallback
            )
        }
        if let relayEnqueuedBytes {
            resourceRecorder.setRelayPendingBytes(relayEnqueuedBytes, ownerID: resourceOwnerID)
        }
        if let dequeuedEvent {
            recordDequeuedEvent(dequeuedEvent)
        }
        if let transportAfterCallbackBytes {
            resourceRecorder.setTransportBytes(
                transportAfterCallbackBytes,
                ownerID: resourceOwnerID,
                transition: .transportAfterProgressCallback
            )
        }
        if shouldEndRelay {
            resourceRecorder.endRelay(ownerID: resourceOwnerID)
        }
        if shouldEndTransport {
            resourceRecorder.endTransport(ownerID: resourceOwnerID)
        }
    }

    private func recordDequeuedEvent(_ event: TransportProgressEvent) {
        guard let resourceRecorder, let resourceOwnerID else { return }
        switch event {
        case .data(let data, _):
            resourceRecorder.transferRelayToHandoff(data.count, ownerID: resourceOwnerID)
        case .complete:
            resourceRecorder.endRelay(ownerID: resourceOwnerID)
        case .response:
            break
        }
    }

    private func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(max(0, rhs))
        return result.overflow ? Int.max : result.partialValue
    }

    private func popPendingLocked() -> TransportProgressEvent? {
        if let head = pendingResponse {
            pendingResponse = nil
            return .response(head)
        }
        if !pendingData.isEmpty {
            let data = pendingData
            let cumulative = pendingCumulativeByteCount
            pendingData.removeAll(keepingCapacity: false)
            return .data(data, cumulativeByteCount: cumulative)
        }
        if let completion = pendingCompletion {
            pendingCompletion = nil
            isFinished = true
            return .complete(
                digestHex: completion.digestHex,
                byteCount: completion.byteCount
            )
        }
        return nil
    }
}

actor ProgressivePreviewPublicationFence {
    private var isOpen = true

    func requireOpen() throws {
        guard isOpen else { throw CancellationError() }
    }

    func close() {
        isOpen = false
    }
}

struct PipelineProgressivePreview: Sendable {
    let image: DecodedImage
    let quality: UInt16
}

actor PipelineProgressivePreviewHub {
    private struct Entry {
        let resourceOwnerID: UUID
        let relay: TransportProgressRelay
        let progressObservation: PipelineProgressiveObservationState
        let finalization: PipelineProgressiveFinalization
        var producer: Task<Void, Never>?
        var subscribers: [UUID: AsyncStream<PipelineProgressivePreview>.Continuation]
        var latest: PipelineProgressivePreview?
    }

    private let decodeStage: DecodeStage
    private let sharesAcrossSubscribers: Bool
    private let supportsProgressObservation: Bool
    private let transportMemoryThreshold: Int
    private let resourceRecorder: FoveaProgressiveResourceRecorder?
    private var entries: [String: Entry] = [:]
    private var producerStartCount = 0

    init(
        decodeStage: DecodeStage,
        sharesAcrossSubscribers: Bool,
        supportsProgressObservation: Bool,
        transportMemoryThreshold: Int = 1,
        resourceRecorder: FoveaProgressiveResourceRecorder? = nil
    ) {
        self.decodeStage = decodeStage
        self.sharesAcrossSubscribers = sharesAcrossSubscribers
        self.supportsProgressObservation = supportsProgressObservation
        self.transportMemoryThreshold = max(1, transportMemoryThreshold)
        self.resourceRecorder = resourceRecorder
    }

    func subscribe(request: ImageRequest) -> PipelineProgressivePreviewSubscription {
        let identifier = UUID()
        guard supportsProgressObservation else {
            return unsupportedSubscription(identifier: identifier)
        }

        let key =
            sharesAcrossSubscribers
            ? request.displayIdentity
            : "\(request.displayIdentity)|task-local|\(identifier.uuidString)"
        let pair = AsyncStream<PipelineProgressivePreview>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )

        if var entry = entries[key] {
            entry.subscribers[identifier] = pair.continuation
            if let latest = entry.latest { pair.continuation.yield(latest) }
            entries[key] = entry
            return subscription(
                key: key,
                identifier: identifier,
                stream: pair.stream,
                entry: entry
            )
        }

        let resourceOwnerID = UUID()
        let relay = TransportProgressRelay(
            maximumBufferedBytes: decodeStage.progressiveEncodedByteLimit,
            transportMemoryThreshold: transportMemoryThreshold,
            resourceRecorder: resourceRecorder,
            resourceOwnerID: resourceOwnerID
        )
        resourceRecorder?.beginRelay(ownerID: resourceOwnerID)
        let progressObservation = PipelineProgressiveObservationState()
        let finalization = PipelineProgressiveFinalization(
            progressObservation: progressObservation
        )
        producerStartCount += 1
        entries[key] = Entry(
            resourceOwnerID: resourceOwnerID,
            relay: relay,
            progressObservation: progressObservation,
            finalization: finalization,
            producer: nil,
            subscribers: [identifier: pair.continuation],
            latest: nil
        )
        let hub = self
        let resourceRecorder = self.resourceRecorder
        let producer = Task { [hub, decodeStage, finalization, resourceRecorder, resourceOwnerID] in
            let consumer = PipelineProgressivePreviewConsumer(
                decodeStage: decodeStage,
                request: request,
                resourceRecorder: resourceRecorder,
                resourceOwnerID: resourceOwnerID
            ) { preview in
                await hub.publish(preview, key: key)
            }
            let candidate = await consumer.consume(relay)
            relay.finish()
            if Task.isCancelled {
                if let candidate {
                    await decodeStage.discardProgressivePreparation(candidate.preparation)
                    candidate.resourceLease?.release()
                }
                await finalization.complete(nil)
            } else {
                await finalization.complete(candidate)
            }
            await hub.producerFinished(key: key)
        }
        entries[key]?.producer = producer
        return subscription(
            key: key,
            identifier: identifier,
            stream: pair.stream,
            entry: entries[key]!
        )
    }

    private func unsupportedSubscription(
        identifier: UUID
    ) -> PipelineProgressivePreviewSubscription {
        let pair = AsyncStream<PipelineProgressivePreview>.makeStream()
        pair.continuation.finish()
        return PipelineProgressivePreviewSubscription(
            stream: pair.stream,
            progressObserver: { _ in },
            progressObservationSupported: false,
            finalization: PipelineProgressiveFinalization(completed: true),
            key: "unsupported|\(identifier.uuidString)",
            identifier: identifier,
            hub: self
        )
    }

    package func producerStartCountForTesting() -> Int {
        producerStartCount
    }

    func unsubscribe(key: String, identifier: UUID) async {
        guard var entry = entries[key],
            let continuation = entry.subscribers.removeValue(forKey: identifier)
        else { return }
        continuation.finish()
        guard entry.subscribers.isEmpty else {
            entries[key] = entry
            return
        }
        entries.removeValue(forKey: key)
        resourceRecorder?.clearPreview(ownerID: entry.resourceOwnerID)
        entry.relay.finish()
        entry.producer?.cancel()
        if let candidate = await entry.finalization.completedCandidate() {
            await decodeStage.discardProgressivePreparation(candidate.preparation)
            candidate.resourceLease?.release()
        }
        await entry.finalization.complete(nil)
    }

    private func subscription(
        key: String,
        identifier: UUID,
        stream: AsyncStream<PipelineProgressivePreview>,
        entry: Entry
    ) -> PipelineProgressivePreviewSubscription {
        PipelineProgressivePreviewSubscription(
            stream: stream,
            progressObserver: { event in
                entry.progressObservation.markObserved()
                entry.relay.observe(event)
            },
            progressObservationSupported: true,
            finalization: entry.finalization,
            key: key,
            identifier: identifier,
            hub: self
        )
    }

    private func publish(_ preview: PipelineProgressivePreview, key: String) {
        guard var entry = entries[key] else { return }
        entry.latest = preview
        resourceRecorder?.setPreviewBytes(
            preview.image.estimatedByteCost,
            ownerID: entry.resourceOwnerID
        )
        let continuations = Array(entry.subscribers.values)
        entries[key] = entry
        for continuation in continuations { continuation.yield(preview) }
    }

    private func producerFinished(key: String) {
        guard var entry = entries[key] else { return }
        entry.producer = nil
        entries[key] = entry
    }
}
