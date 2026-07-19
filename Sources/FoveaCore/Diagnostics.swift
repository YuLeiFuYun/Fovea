import CryptoKit
import Foundation

public enum DiagnosticEventKind: String, Codable, Hashable, Sendable {
  case fetchQueued
  case fetchStarted
  case fetchJoined
  case fetchCompleted
  case fetchRetryScheduled
  case fetchCancelled
  case originalEncodedHit
  case staleFallbackUsed
  case renderedMemoryHit
  case decodeQueued
  case decodeJoined
  case decodeStarted
  case decodeCompleted
  case cacheReadFailed
  case cacheWriteFailed
  case responseAnomaly
  case namespaceRevoked
  case pipelineFailed
  case diagnosticsDropped
}

public struct DiagnosticEvent: Codable, Hashable, Sendable {
  public static let currentSchemaVersion: UInt16 = 2

  public let schemaVersion: UInt16
  public let kind: DiagnosticEventKind
  public let keyDigest: String?
  public let statusCode: Int?
  public let byteCount: Int?
  public let sourcePixelCount: Int?
  public let outputPixelCount: Int?
  public let targetWidth: Int?
  public let targetHeight: Int?
  public let reason: String?
  public let attempt: Int?
  public let retryDelayNanoseconds: UInt64?
  public let requestedPriority: ImageRequestPriority?
  public let effectivePriority: ImageRequestPriority?
  public let failureCategory: PipelineFailure.Category?
  public let failureStage: PipelineFailure.Stage?
  public let failureDisposition: PipelineFailure.Disposition?

  public init(
    schemaVersion: UInt16 = DiagnosticEvent.currentSchemaVersion,
    kind: DiagnosticEventKind,
    keyDigest: String? = nil,
    statusCode: Int? = nil,
    byteCount: Int? = nil,
    sourcePixelCount: Int? = nil,
    outputPixelCount: Int? = nil,
    targetWidth: Int? = nil,
    targetHeight: Int? = nil,
    reason: String? = nil,
    attempt: Int? = nil,
    retryDelayNanoseconds: UInt64? = nil,
    requestedPriority: ImageRequestPriority? = nil,
    effectivePriority: ImageRequestPriority? = nil,
    failureCategory: PipelineFailure.Category? = nil,
    failureStage: PipelineFailure.Stage? = nil,
    failureDisposition: PipelineFailure.Disposition? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.kind = kind
    self.keyDigest = keyDigest
    self.statusCode = statusCode
    self.byteCount = byteCount
    self.sourcePixelCount = sourcePixelCount
    self.outputPixelCount = outputPixelCount
    self.targetWidth = targetWidth
    self.targetHeight = targetHeight
    self.reason = reason
    self.attempt = attempt
    self.retryDelayNanoseconds = retryDelayNanoseconds
    self.requestedPriority = requestedPriority
    self.effectivePriority = effectivePriority
    self.failureCategory = failureCategory
    self.failureStage = failureStage
    self.failureDisposition = failureDisposition
  }

  package func replacingKeyDigest(_ keyDigest: String?) -> DiagnosticEvent {
    DiagnosticEvent(
      schemaVersion: schemaVersion,
      kind: kind,
      keyDigest: keyDigest,
      statusCode: statusCode,
      byteCount: byteCount,
      sourcePixelCount: sourcePixelCount,
      outputPixelCount: outputPixelCount,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      reason: reason,
      attempt: attempt,
      retryDelayNanoseconds: retryDelayNanoseconds,
      requestedPriority: requestedPriority,
      effectivePriority: effectivePriority,
      failureCategory: failureCategory,
      failureStage: failureStage,
      failureDisposition: failureDisposition
    )
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
      droppedSinceLastReport += 1
      droppedEventCount += 1
    }
  }

  private func flushDroppedSummaryIfPossible() {
    guard droppedSinceLastReport > 0 else { return }
    let summary = DiagnosticEvent(
      kind: .diagnosticsDropped,
      byteCount: droppedSinceLastReport,
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
