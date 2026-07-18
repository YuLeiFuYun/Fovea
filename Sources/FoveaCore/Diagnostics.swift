import Foundation

public enum DiagnosticEventKind: String, Codable, Hashable, Sendable {
  case fetchStarted
  case fetchJoined
  case fetchCompleted
  case fetchCancelled
  case originalEncodedHit
  case renderedMemoryHit
  case decodeCompleted
  case cacheWriteFailed
  case namespaceRevoked
}

public struct DiagnosticEvent: Codable, Hashable, Sendable {
  public let kind: DiagnosticEventKind
  public let keyDigest: String?
  public let statusCode: Int?
  public let byteCount: Int?
  public let sourcePixelCount: Int?
  public let outputPixelCount: Int?
  public let targetWidth: Int?
  public let targetHeight: Int?
  public let reason: String?

  public init(
    kind: DiagnosticEventKind,
    keyDigest: String? = nil,
    statusCode: Int? = nil,
    byteCount: Int? = nil,
    sourcePixelCount: Int? = nil,
    outputPixelCount: Int? = nil,
    targetWidth: Int? = nil,
    targetHeight: Int? = nil,
    reason: String? = nil
  ) {
    self.kind = kind
    self.keyDigest = keyDigest
    self.statusCode = statusCode
    self.byteCount = byteCount
    self.sourcePixelCount = sourcePixelCount
    self.outputPixelCount = outputPixelCount
    self.targetWidth = targetWidth
    self.targetHeight = targetHeight
    self.reason = reason
  }
}

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

public protocol DiagnosticsSink: Sendable {
  func record(_ event: DiagnosticEvent) async
}

public struct NullDiagnosticsSink: DiagnosticsSink {
  public init() {}
  public func record(_ event: DiagnosticEvent) async {}
}

public actor BoundedDiagnosticsSink: DiagnosticsSink {
  private let capacity: Int
  private let startedAtNanoseconds: UInt64
  private var nextSequence: UInt64 = 0
  private var storage: [RecordedDiagnosticEvent?]
  private var head = 0
  private var count = 0
  private var dropped = 0

  public init(capacity: Int = 4_096) {
    let capacity = max(1, capacity)
    self.capacity = capacity
    self.startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
    self.storage = Array(repeating: nil, count: capacity)
  }

  public func record(_ event: DiagnosticEvent) {
    nextSequence &+= 1
    let now = DispatchTime.now().uptimeNanoseconds
    let recorded = RecordedDiagnosticEvent(
      sequence: nextSequence,
      elapsedNanoseconds: now &- startedAtNanoseconds,
      event: event
    )

    if count < capacity {
      storage[(head + count) % capacity] = recorded
      count += 1
    } else {
      storage[head] = recorded
      head = (head + 1) % capacity
      dropped += 1
    }
  }

  public func snapshot() -> [RecordedDiagnosticEvent] {
    (0..<count).compactMap { storage[(head + $0) % capacity] }
  }

  public var droppedEventCount: Int { dropped }
}
