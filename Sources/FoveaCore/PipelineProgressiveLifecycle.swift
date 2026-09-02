import Foundation
import FoveaHTTP
import ImageCraftCore

struct PipelineProgressivePreparedFinalization: Sendable {
    let preparation: ImageDecodePreparation
    let sourceByteCount: Int
    let transportDigestHex: String
    let transportByteCount: Int
    let resourceLease: FoveaProgressivePreparationResourceLease?
}

final class PipelineProgressiveObservationState: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false

    func markObserved() {
        lock.withLock { observed = true }
    }

    func hasObservedProgress() -> Bool {
        lock.withLock { observed }
    }
}

actor PipelineProgressiveFinalization {
    private let progressObservation: PipelineProgressiveObservationState
    private var isCompleted = false
    private var candidate: PipelineProgressivePreparedFinalization?
    private var waiters: [CheckedContinuation<PipelineProgressivePreparedFinalization?, Never>] = []

    init(
        completedWith candidate: PipelineProgressivePreparedFinalization? = nil,
        completed: Bool = false,
        progressObservation: PipelineProgressiveObservationState =
            PipelineProgressiveObservationState()
    ) {
        self.progressObservation = progressObservation
        self.candidate = candidate
        self.isCompleted = completed
    }

    func value() async -> PipelineProgressivePreparedFinalization? {
        if isCompleted { return candidate }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func valueAfterResponseCompletion() async -> PipelineProgressivePreparedFinalization? {
        if isCompleted { return candidate }
        guard progressObservation.hasObservedProgress() else {
            complete(nil)
            return nil
        }
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
    let progressObservationSupported: Bool
    let finalization: PipelineProgressiveFinalization

    private let key: String
    private let identifier: UUID
    private let hub: PipelineProgressivePreviewHub

    init(
        stream: AsyncStream<PipelineProgressivePreview>,
        progressObserver: @escaping TransportProgressObserver,
        progressObservationSupported: Bool,
        finalization: PipelineProgressiveFinalization,
        key: String,
        identifier: UUID,
        hub: PipelineProgressivePreviewHub
    ) {
        self.stream = stream
        self.progressObserver = progressObserver
        self.progressObservationSupported = progressObservationSupported
        self.finalization = finalization
        self.key = key
        self.identifier = identifier
        self.hub = hub
    }

    func cancel() async {
        await hub.unsubscribe(key: key, identifier: identifier)
    }
}

struct PipelineProgressivePreviewConsumer: Sendable {
    let decodeStage: DecodeStage
    let request: ImageRequest
    let resourceRecorder: FoveaProgressiveResourceRecorder?
    let resourceOwnerID: UUID
    let publish: @Sendable (PipelineProgressivePreview) async -> Void

    func consume(
        _ events: TransportProgressRelay
    ) async -> PipelineProgressivePreparedFinalization? {
        var session: (any ImageProgressiveDecodeSession)?
        var sessionResourceActive = false
        var reachedPreparationBarrier = false
        var lastGeneration: UInt32 = 0
        defer {
            session?.cancel()
            resourceRecorder?.clearHandoff(ownerID: resourceOwnerID)
            if sessionResourceActive {
                resourceRecorder?.endSession(ownerID: resourceOwnerID)
            }
            if !reachedPreparationBarrier {
                resourceRecorder?.abortPreparationBarrierIfConfigured()
            }
        }
        do {
            eventLoop: while let event = await events.next() {
                try Task.checkCancellation()
                switch event {
                case .response(let head):
                    try replaceProgressiveSession(
                        for: head,
                        session: &session,
                        resourceActive: &sessionResourceActive
                    )
                case .data(let data, _):
                    lastGeneration = try await consumeProgressiveData(
                        data,
                        session: session,
                        after: lastGeneration
                    )
                case .complete(let digestHex, let byteCount):
                    guard let session else { break eventLoop }
                    let candidate = try await finalizeProgressiveSession(
                        session, transportDigestHex: digestHex, transportByteCount: byteCount
                    )
                    reachedPreparationBarrier = candidate != nil
                    return candidate
                }
            }
        } catch {
            // 渐进输出只是机会性结果；完整响应仍须通过常规 probe、decode、
            // namespace、完整性与持久化边界。
        }
        return nil
    }

    private func replaceProgressiveSession(
        for head: TransportResponseHead,
        session: inout (any ImageProgressiveDecodeSession)?,
        resourceActive: inout Bool
    ) throws {
        session?.cancel()
        session = nil
        if resourceActive {
            resourceRecorder?.endSession(ownerID: resourceOwnerID)
            resourceActive = false
        }
        guard Self.accepts(head) else { return }
        let replacement = try decodeStage.makeProgressiveSession(
            for: request,
            format: .jpeg
        )
        session = replacement
        guard replacement != nil else { return }
        resourceActive = true
        resourceRecorder?.beginSession(ownerID: resourceOwnerID)
    }

    private func consumeProgressiveData(
        _ data: Data,
        session: (any ImageProgressiveDecodeSession)?,
        after lastGeneration: UInt32
    ) async throws -> UInt32 {
        guard let session else {
            resourceRecorder?.clearHandoff(ownerID: resourceOwnerID)
            return lastGeneration
        }
        return try await publishProgressiveGeneration(
            data,
            to: session,
            after: lastGeneration
        )
    }

    private func publishProgressiveGeneration(
        _ data: Data,
        to session: any ImageProgressiveDecodeSession,
        after lastGeneration: UInt32
    ) async throws -> UInt32 {
        defer { resourceRecorder?.clearHandoff(ownerID: resourceOwnerID) }
        let candidate = try await decodeStage.appendProgressive(
            data,
            to: session,
            for: request
        )
        resourceRecorder?.setSessionBytes(session.receivedByteCount, ownerID: resourceOwnerID)
        guard let generation = candidate, generation.generation > lastGeneration else {
            return lastGeneration
        }
        await publish(
            PipelineProgressivePreview(
                image: generation.image,
                quality: UInt16(min(UInt32(UInt16.max - 1), generation.generation))
            )
        )
        return generation.generation
    }

    private func finalizeProgressiveSession(
        _ session: any ImageProgressiveDecodeSession,
        transportDigestHex: String,
        transportByteCount: Int
    ) async throws -> PipelineProgressivePreparedFinalization? {
        guard let preparing = session as? any ProgressiveImagePreparingSession else {
            try await decodeStage.finishProgressive(session, for: request)
            return nil
        }
        let finalization = try await decodeStage.finishProgressiveWithPreparation(
            preparing,
            for: request
        )
        let resourceLease = resourceRecorder.map {
            FoveaProgressivePreparationResourceLease(
                recorder: $0,
                ownerID: resourceOwnerID,
                byteCount: finalization.sourceByteCount
            )
        }
        guard finalization.sourceByteCount == transportByteCount else {
            await decodeStage.discardProgressivePreparation(finalization.preparation)
            resourceLease?.release()
            return nil
        }
        if let resourceRecorder {
            await resourceRecorder.waitAtPreparationBarrierIfConfigured()
        }
        return PipelineProgressivePreparedFinalization(
            preparation: finalization.preparation,
            sourceByteCount: finalization.sourceByteCount,
            transportDigestHex: transportDigestHex,
            transportByteCount: transportByteCount,
            resourceLease: resourceLease
        )
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
