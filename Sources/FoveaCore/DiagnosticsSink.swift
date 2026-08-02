import CryptoKit
import Foundation

/// 带单调序列号的诊断事件。

public struct RecordedDiagnosticEvent: Codable, Hashable, Sendable {
    public let sequence: UInt64
    public let elapsedNanoseconds: UInt64
    public let event: DiagnosticEvent

    public init(sequence: UInt64, elapsedNanoseconds: UInt64, event: DiagnosticEvent) {
        self.sequence = sequence
        self.elapsedNanoseconds = elapsedNanoseconds
        self.event = event
    }
}

/// 接收结构化诊断事件，但不得影响管线正确性。

public protocol DiagnosticsSink: Sendable {
    func record(_ event: DiagnosticEvent) async
}

/// 有意丢弃所有事件的诊断接收器。

public struct NullDiagnosticsSink: DiagnosticsSink {
    public init() {}
    public func record(_ event: DiagnosticEvent) async {}
}

/// 带显式丢弃计数的内存诊断环形缓冲区。

public actor BoundedDiagnosticsSink: DiagnosticsSink {
    private static let maximumCapacity = 65_536

    private let capacity: Int
    private let startedAtNanoseconds: UInt64
    private var nextSequence: UInt64 = 0
    private var storage: [RecordedDiagnosticEvent?]
    private var head = 0
    private var count = 0
    private var dropped = 0

    public init(capacity: Int = 4_096) {
        let capacity = min(Self.maximumCapacity, max(1, capacity))
        self.capacity = capacity
        self.startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        self.storage = Array(repeating: nil, count: capacity)
    }

    package init(capacity: Int, initialSequence: UInt64) {
        let capacity = min(Self.maximumCapacity, max(1, capacity))
        self.capacity = capacity
        self.startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        self.nextSequence = initialSequence
        self.storage = Array(repeating: nil, count: capacity)
    }

    public func record(_ event: DiagnosticEvent) {
        let sequence = nextSequenceValue()
        let now = DispatchTime.now().uptimeNanoseconds
        let recorded = RecordedDiagnosticEvent(
            sequence: sequence,
            elapsedNanoseconds: now &- startedAtNanoseconds,
            event: event
        )

        if count < capacity {
            storage[(head + count) % capacity] = recorded
            count += 1
        } else {
            storage[head] = recorded
            head = (head + 1) % capacity
            if dropped < Int.max { dropped += 1 }
        }
    }

    private func nextSequenceValue() -> UInt64 {
        if nextSequence == UInt64.max {
            for offset in 0..<count {
                let index = (head + offset) % capacity
                guard let item = storage[index] else { continue }
                storage[index] = RecordedDiagnosticEvent(
                    sequence: UInt64(offset + 1),
                    elapsedNanoseconds: item.elapsedNanoseconds,
                    event: item.event
                )
            }
            nextSequence = UInt64(count)
        }
        nextSequence += 1
        return nextSequence
    }

    public func snapshot() -> [RecordedDiagnosticEvent] {
        (0..<count).compactMap { storage[(head + $0) % capacity] }
    }

    public var droppedEventCount: Int { dropped }
}

package actor BufferedDiagnosticsRelay: DiagnosticsSink {
    private let continuation: AsyncStream<DiagnosticEvent>.Continuation
    private let processor: Task<Void, Never>
    private var droppedSinceLastReport = 0
    package private(set) var droppedEventCount = 0

    package init(
        downstream: any DiagnosticsSink,
        capacity: Int = 1_024
    ) {
        let stream = AsyncStream<DiagnosticEvent>.makeStream(
            bufferingPolicy: .bufferingOldest(max(1, capacity))
        )
        self.continuation = stream.continuation
        self.processor = Task { @concurrent in
            for await event in stream.stream {
                await downstream.record(event)
            }
        }
    }

    deinit {
        continuation.finish()
        processor.cancel()
    }

    package func record(_ event: DiagnosticEvent) {
        flushDroppedSummaryIfPossible()
        if case .dropped = continuation.yield(event) {
            if droppedSinceLastReport < Int.max { droppedSinceLastReport += 1 }
            if droppedEventCount < Int.max { droppedEventCount += 1 }
        }
    }

    private func flushDroppedSummaryIfPossible() {
        guard droppedSinceLastReport > 0 else { return }
        let summary = DiagnosticEvent(
            kind: .diagnosticsDropped,
            itemCount: droppedSinceLastReport,
            reason: "external-sink-backpressure"
        )
        if case .enqueued = continuation.yield(summary) {
            droppedSinceLastReport = 0
        }
    }
}

package func nonBlockingDiagnosticsSink(
    _ sink: any DiagnosticsSink
) -> any DiagnosticsSink {
    if sink is NullDiagnosticsSink || sink is BoundedDiagnosticsSink { return sink }
    return BufferedDiagnosticsRelay(downstream: sink)
}

package struct RedactingDiagnosticsSink: DiagnosticsSink, Sendable {
    private let downstream: any DiagnosticsSink
    private let salt: Data

    package init(
        downstream: any DiagnosticsSink,
        salt: Data = Data(UUID().uuidString.utf8)
    ) {
        self.downstream = downstream
        self.salt = salt
    }

    package func record(_ event: DiagnosticEvent) async {
        guard let stableDigest = event.keyDigest else {
            await downstream.record(event)
            return
        }
        var material = Data("fovea-diagnostic-correlation-v1\u{0}".utf8)
        material.append(salt)
        material.append(0)
        material.append(contentsOf: stableDigest.utf8)
        let correlation = SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
        await downstream.record(event.replacingKeyDigest(correlation))
    }
}

package func pipelineDiagnosticsSink(
    _ sink: any DiagnosticsSink
) -> any DiagnosticsSink {
    if sink is NullDiagnosticsSink { return sink }
    return RedactingDiagnosticsSink(downstream: nonBlockingDiagnosticsSink(sink))
}

/// 细粒度诊断只能在真实 sink 存在时构造和等待；正式 Null 路径保持零事件开销。
package func detailedDiagnosticsAreEnabled(_ sink: any DiagnosticsSink) -> Bool {
    !(sink is NullDiagnosticsSink)
}
