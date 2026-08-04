import Foundation
import FoveaHTTP
import ImageCraftCore

final class TransportProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBufferedBytes: Int
    private var pendingResponse: TransportResponseHead?
    private var pendingData = Data()
    private var pendingCumulativeByteCount = 0
    private var pendingCompletion: (digestHex: String, byteCount: Int)?
    private var waiter: CheckedContinuation<TransportProgressEvent?, Never>?
    private var isFinished = false

    init(maximumBufferedBytes: Int) {
        self.maximumBufferedBytes = max(1, maximumBufferedBytes)
    }

    func observe(_ event: TransportProgressEvent) {
        var resume: (CheckedContinuation<TransportProgressEvent?, Never>, TransportProgressEvent?)?
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        switch event {
        case .response(let head):
            pendingResponse = head
        case .data(let data, let cumulativeByteCount):
            guard cumulativeByteCount <= maximumBufferedBytes,
                pendingData.count <= maximumBufferedBytes - data.count
            else {
                isFinished = true
                pendingResponse = nil
                pendingData.removeAll(keepingCapacity: false)
                pendingCompletion = nil
                if let waiter {
                    self.waiter = nil
                    resume = (waiter, nil)
                }
                lock.unlock()
                resume?.0.resume(returning: resume?.1)
                return
            }
            pendingData.append(data)
            pendingCumulativeByteCount = cumulativeByteCount
        case .complete(let digestHex, let byteCount):
            pendingCompletion = (digestHex, byteCount)
        }
        if let waiter, let next = popPendingLocked() {
            self.waiter = nil
            resume = (waiter, next)
        }
        lock.unlock()
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
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    func finish() {
        var continuation: CheckedContinuation<TransportProgressEvent?, Never>?
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        pendingResponse = nil
        pendingData.removeAll(keepingCapacity: false)
        pendingCompletion = nil
        continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume(returning: nil)
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

struct PipelineProgressivePreparedFinalization: Sendable {
    let preparation: ImageDecodePreparation
    let sourceByteCount: Int
    let transportDigestHex: String
    let transportByteCount: Int
}

actor PipelineProgressiveFinalization {
    private var isCompleted = false
    private var candidate: PipelineProgressivePreparedFinalization?
    private var waiters: [CheckedContinuation<PipelineProgressivePreparedFinalization?, Never>] = []

    init(
        completedWith candidate: PipelineProgressivePreparedFinalization? = nil,
        completed: Bool = false
    ) {
        self.candidate = candidate
        self.isCompleted = completed
    }

    func value() async -> PipelineProgressivePreparedFinalization? {
        if isCompleted { return candidate }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func complete(_ candidate: PipelineProgressivePreparedFinalization?) {
        guard !isCompleted else { return }
        isCompleted = true
        self.candidate = candidate
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        for continuation in continuations { continuation.resume(returning: candidate) }
    }

    func completedCandidate() -> PipelineProgressivePreparedFinalization? {
        guard isCompleted else { return nil }
        return candidate
    }
}

struct PipelineProgressivePreviewSubscription: Sendable {
    let stream: AsyncStream<PipelineProgressivePreview>
    let progressObserver: TransportProgressObserver
    let finalization: PipelineProgressiveFinalization

    private let key: String
    private let identifier: UUID
    private let hub: PipelineProgressivePreviewHub

    init(
        stream: AsyncStream<PipelineProgressivePreview>,
        progressObserver: @escaping TransportProgressObserver,
        finalization: PipelineProgressiveFinalization,
        key: String,
        identifier: UUID,
        hub: PipelineProgressivePreviewHub
    ) {
        self.stream = stream
        self.progressObserver = progressObserver
        self.finalization = finalization
        self.key = key
        self.identifier = identifier
        self.hub = hub
    }

    func cancel() async {
        await hub.unsubscribe(key: key, identifier: identifier)
    }
}

actor PipelineProgressivePreviewHub {
    private struct Entry {
        let relay: TransportProgressRelay
        let finalization: PipelineProgressiveFinalization
        var producer: Task<Void, Never>?
        var subscribers: [UUID: AsyncStream<PipelineProgressivePreview>.Continuation]
        var latest: PipelineProgressivePreview?
    }

    private let decodeStage: DecodeStage
    private let sharesAcrossSubscribers: Bool
    private let supportsProgressObservation: Bool
    private var entries: [String: Entry] = [:]
    private var producerStartCount = 0

    init(
        decodeStage: DecodeStage,
        sharesAcrossSubscribers: Bool,
        supportsProgressObservation: Bool
    ) {
        self.decodeStage = decodeStage
        self.sharesAcrossSubscribers = sharesAcrossSubscribers
        self.supportsProgressObservation = supportsProgressObservation
    }

    func subscribe(request: ImageRequest) -> PipelineProgressivePreviewSubscription {
        let identifier = UUID()
        guard supportsProgressObservation else {
            let pair = AsyncStream<PipelineProgressivePreview>.makeStream()
            pair.continuation.finish()
            return PipelineProgressivePreviewSubscription(
                stream: pair.stream,
                progressObserver: { _ in },
                finalization: PipelineProgressiveFinalization(completed: true),
                key: "unsupported|\(identifier.uuidString)",
                identifier: identifier,
                hub: self
            )
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

        let relay = TransportProgressRelay(
            maximumBufferedBytes: decodeStage.progressiveEncodedByteLimit
        )
        let finalization = PipelineProgressiveFinalization()
        producerStartCount += 1
        entries[key] = Entry(
            relay: relay,
            finalization: finalization,
            producer: nil,
            subscribers: [identifier: pair.continuation],
            latest: nil
        )
        let hub = self
        let producer = Task { [hub, decodeStage, finalization] in
            let consumer = PipelineProgressivePreviewConsumer(
                decodeStage: decodeStage,
                request: request
            ) { preview in
                await hub.publish(preview, key: key)
            }
            let candidate = await consumer.consume(relay)
            relay.finish()
            if Task.isCancelled {
                if let candidate {
                    await decodeStage.discardProgressivePreparation(candidate.preparation)
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
        entry.relay.finish()
        entry.producer?.cancel()
        if let candidate = await entry.finalization.completedCandidate() {
            await decodeStage.discardProgressivePreparation(candidate.preparation)
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
            progressObserver: { event in entry.relay.observe(event) },
            finalization: entry.finalization,
            key: key,
            identifier: identifier,
            hub: self
        )
    }

    private func publish(_ preview: PipelineProgressivePreview, key: String) {
        guard var entry = entries[key] else { return }
        entry.latest = preview
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

struct PipelineProgressivePreviewConsumer: Sendable {
    let decodeStage: DecodeStage
    let request: ImageRequest
    let publish: @Sendable (PipelineProgressivePreview) async -> Void

    func consume(
        _ events: TransportProgressRelay
    ) async -> PipelineProgressivePreparedFinalization? {
        var session: (any ImageProgressiveDecodeSession)?
        var lastGeneration: UInt32 = 0
        defer { session?.cancel() }
        do {
            eventLoop: while let event = await events.next() {
                try Task.checkCancellation()
                switch event {
                case .response(let head):
                    guard Self.accepts(head) else { continue }
                    session = try decodeStage.makeProgressiveSession(
                        for: request,
                        format: .jpeg
                    )
                case .data(let data, _):
                    guard let session,
                        let generation = try await decodeStage.appendProgressive(
                            data, to: session
                        ),
                        generation.generation > lastGeneration
                    else { continue }
                    lastGeneration = generation.generation
                    await publish(
                        PipelineProgressivePreview(
                            image: generation.image,
                            quality: UInt16(
                                min(UInt32(UInt16.max - 1), generation.generation)
                            )
                        )
                    )
                case .complete(let digestHex, let byteCount):
                    guard let session else { break eventLoop }
                    if let preparing = session as? any ProgressiveImagePreparingSession {
                        let finalization = try await decodeStage.finishProgressiveWithPreparation(
                            preparing
                        )
                        guard finalization.sourceByteCount == byteCount else {
                            await decodeStage.discardProgressivePreparation(
                                finalization.preparation
                            )
                            break eventLoop
                        }
                        return PipelineProgressivePreparedFinalization(
                            preparation: finalization.preparation,
                            sourceByteCount: finalization.sourceByteCount,
                            transportDigestHex: digestHex,
                            transportByteCount: byteCount
                        )
                    }
                    try await decodeStage.finishProgressive(session)
                    break eventLoop
                }
            }
        } catch {
            // Progressive output is opportunistic. The complete response still passes through
            // the normal probe, decode, namespace, integrity and persistence boundaries.
        }
        return nil
    }

    private static func accepts(_ head: TransportResponseHead) -> Bool {
        guard head.statusCode == 200 else { return false }
        let contentEncoding =
            head.value(forHeader: "content-encoding")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "identity"
        guard contentEncoding == "identity" else { return false }
        let mime = head.value(forHeader: "content-type")?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mime == "image/jpeg"
    }
}
