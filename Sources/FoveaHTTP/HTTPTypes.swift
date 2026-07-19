import CryptoKit
import Foundation

public struct TransportReusePolicy: Hashable, Sendable {
  private enum Scope: Hashable, Sendable {
    case taskLocal
    case reusable(contextIdentifier: String)
  }

  private let scope: Scope

  private init(scope: Scope) {
    self.scope = scope
  }

  public static let taskLocal = TransportReusePolicy(scope: .taskLocal)

  public static func reusable(contextIdentifier: String) -> TransportReusePolicy {
    let normalized = contextIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return .taskLocal }
    return TransportReusePolicy(scope: .reusable(contextIdentifier: normalized))
  }

  public var allowsCrossRequestReuse: Bool {
    if case .reusable = scope { return true }
    return false
  }

  package var executionFingerprint: String {
    switch scope {
    case .taskLocal:
      return "transport-task-local-v1"
    case .reusable(let contextIdentifier):
      var material = Data("transport-context-v1".utf8)
      material.append(0)
      material.append(contentsOf: contextIdentifier.utf8)
      return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }
  }
}

public enum TransportPriority: Int, CaseIterable, Codable, Hashable, Sendable, Comparable {
  case background = 0
  case low = 1
  case normal = 2
  case high = 3
  case userInitiated = 4

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  package var urlSessionTaskValue: Float {
    switch self {
    case .background: URLSessionTask.lowPriority * 0.5
    case .low: URLSessionTask.lowPriority
    case .normal: URLSessionTask.defaultPriority
    case .high: 0.75
    case .userInitiated: URLSessionTask.highPriority
    }
  }
}

package actor TransportPriorityController {
  private var priority: TransportPriority
  private var continuations: [UUID: AsyncStream<TransportPriority>.Continuation] = [:]
  private var isFinished = false

  package init(priority: TransportPriority) {
    self.priority = priority
  }

  package func updates() -> AsyncStream<TransportPriority> {
    let identifier = UUID()
    let stream = AsyncStream<TransportPriority>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    guard !isFinished else {
      stream.continuation.finish()
      return stream.stream
    }
    continuations[identifier] = stream.continuation
    stream.continuation.yield(priority)
    stream.continuation.onTermination = { [weak self] _ in
      Task { await self?.removeContinuation(identifier) }
    }
    return stream.stream
  }

  package func update(_ newPriority: TransportPriority) {
    guard !isFinished, newPriority != priority else { return }
    priority = newPriority
    for continuation in continuations.values { continuation.yield(newPriority) }
  }

  package func finish() {
    guard !isFinished else { return }
    isFinished = true
    for continuation in continuations.values { continuation.finish() }
    continuations.removeAll(keepingCapacity: false)
  }

  private func removeContinuation(_ identifier: UUID) {
    continuations.removeValue(forKey: identifier)
  }
}

public struct TransportRequest: Sendable {
  public let request: URLRequest
  public let maximumBytes: Int
  public let memoryThreshold: Int
  public let credentialHeaderNames: Set<String>
  public let priority: TransportPriority
  package let priorityController: TransportPriorityController?

  public init(
    request: URLRequest,
    maximumBytes: Int,
    memoryThreshold: Int = 512 * 1024,
    credentialHeaderNames: Set<String> = [],
    priority: TransportPriority = .normal
  ) {
    self.request = request
    self.maximumBytes = maximumBytes
    self.memoryThreshold = memoryThreshold
    self.credentialHeaderNames = credentialHeaderNames
    self.priority = priority
    self.priorityController = nil
  }

  package init(
    request: URLRequest,
    maximumBytes: Int,
    memoryThreshold: Int,
    credentialHeaderNames: Set<String>,
    priority: TransportPriority,
    priorityController: TransportPriorityController
  ) {
    self.request = request
    self.maximumBytes = maximumBytes
    self.memoryThreshold = memoryThreshold
    self.credentialHeaderNames = credentialHeaderNames
    self.priority = priority
    self.priorityController = priorityController
  }
}

public struct TransportResponseHead: Sendable {
  public let statusCode: Int
  public let headers: [String: String]
  public let url: URL?

  public init(statusCode: Int, headers: [String: String], url: URL?) {
    self.statusCode = statusCode
    self.headers =
      headers
      .map { (name: $0.key.lowercased(), originalName: $0.key, value: $0.value) }
      .sorted {
        if $0.name != $1.name { return $0.name < $1.name }
        if $0.originalName != $1.originalName { return $0.originalName < $1.originalName }
        return $0.value < $1.value
      }
      .reduce(into: [:]) { result, pair in
        if result[pair.name] == nil { result[pair.name] = pair.value }
      }
    self.url = url
  }

  public func value(forHeader name: String) -> String? {
    headers[name.lowercased()]
  }
}

public struct TransportNetworkMetrics: Codable, Hashable, Sendable {
  public let taskDurationNanoseconds: UInt64
  public let transactionCount: Int
  public let negotiatedProtocolNames: [String]
  public let reusedConnectionCount: Int
  public let proxyConnectionCount: Int
  public let cellularTransactionCount: Int
  public let expensiveTransactionCount: Int
  public let constrainedTransactionCount: Int

  public init(
    taskDurationNanoseconds: UInt64,
    transactionCount: Int,
    negotiatedProtocolNames: [String],
    reusedConnectionCount: Int,
    proxyConnectionCount: Int,
    cellularTransactionCount: Int,
    expensiveTransactionCount: Int,
    constrainedTransactionCount: Int
  ) {
    self.taskDurationNanoseconds = taskDurationNanoseconds
    self.transactionCount = max(0, transactionCount)
    self.negotiatedProtocolNames = negotiatedProtocolNames.sorted()
    self.reusedConnectionCount = max(0, reusedConnectionCount)
    self.proxyConnectionCount = max(0, proxyConnectionCount)
    self.cellularTransactionCount = max(0, cellularTransactionCount)
    self.expensiveTransactionCount = max(0, expensiveTransactionCount)
    self.constrainedTransactionCount = max(0, constrainedTransactionCount)
  }
}

public struct TransportMetrics: Sendable {
  public let receivedBytes: Int
  public let spilledToDisk: Bool
  public let network: TransportNetworkMetrics?

  public init(
    receivedBytes: Int,
    spilledToDisk: Bool,
    network: TransportNetworkMetrics? = nil
  ) {
    self.receivedBytes = receivedBytes
    self.spilledToDisk = spilledToDisk
    self.network = network
  }
}

public struct TransportResponse: Sendable {
  public let head: TransportResponseHead
  public let body: Data
  public let digestHex: String
  public let metrics: TransportMetrics

  public init(head: TransportResponseHead, body: Data, digestHex: String, metrics: TransportMetrics)
  {
    self.head = head
    self.body = body
    self.digestHex = digestHex
    self.metrics = metrics
  }
}

public enum TransportError: Error, Equatable, Sendable {
  case nonHTTPResponse
  case bodyTooLarge
  case invalidContentLength
  case incompleteBody
  case insecureRedirect
}

public protocol HTTPTransporting: Sendable {
  nonisolated var reusePolicy: TransportReusePolicy { get }
  func execute(_ request: TransportRequest) async throws -> TransportResponse
}
