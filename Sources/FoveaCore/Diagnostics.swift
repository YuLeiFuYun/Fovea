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
  private var buffered: [RecordedDiagnosticEvent] = []
  private var dropped = 0

  public init(capacity: Int = 4_096) {
    self.capacity = max(1, capacity)
    self.startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
    self.buffered.reserveCapacity(min(capacity, 4_096))
  }

  public func record(_ event: DiagnosticEvent) {
    nextSequence &+= 1
    let now = DispatchTime.now().uptimeNanoseconds
    let recorded = RecordedDiagnosticEvent(
      sequence: nextSequence,
      elapsedNanoseconds: now &- startedAtNanoseconds,
      event: event
    )
    if buffered.count == capacity {
      buffered.removeFirst()
      dropped += 1
    }
    buffered.append(recorded)
  }

  public func snapshot() -> [RecordedDiagnosticEvent] { buffered }
  public var droppedEventCount: Int { dropped }
}
