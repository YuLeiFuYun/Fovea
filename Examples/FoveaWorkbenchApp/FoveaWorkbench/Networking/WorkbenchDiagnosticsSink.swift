import Dispatch
import FoveaCore

actor WorkbenchDiagnosticsSink: DiagnosticsSink {
    private let capacity: Int
    private var storage: [RecordedDiagnosticEvent?]
    private var head = 0
    private var count = 0
    private var nextSequence: UInt64 = 0
    private let startedAt = DispatchTime.now().uptimeNanoseconds
    private var dropped = 0

    init(capacity: Int = 4_096) {
        let capacity = max(1, capacity)
        self.capacity = capacity
        storage = Array(repeating: nil, count: capacity)
    }

    func record(_ event: DiagnosticEvent) {
        nextSequence &+= 1
        let item = RecordedDiagnosticEvent(
            sequence: nextSequence,
            elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds &- startedAt,
            event: event
        )
        if count < capacity {
            storage[(head + count) % capacity] = item
            count += 1
        } else {
            storage[head] = item
            head = (head + 1) % capacity
            dropped += 1
        }
    }

    func snapshot() -> [RecordedDiagnosticEvent] {
        (0..<count).compactMap { storage[(head + $0) % capacity] }
    }

    func droppedEventCount() -> Int { dropped }

    func clear() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
        dropped = 0
    }
}

struct WorkbenchDiagnosticsMultiplexer: DiagnosticsSink {
    let sinks: [any DiagnosticsSink]

    init(_ sinks: [any DiagnosticsSink]) {
        self.sinks = sinks
    }

    func record(_ event: DiagnosticEvent) async {
        for sink in sinks {
            await sink.record(event)
        }
    }
}
