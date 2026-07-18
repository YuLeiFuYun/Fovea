import Foundation

public struct TransportRequest: Sendable {
  public let request: URLRequest
  public let maximumBytes: Int
  public let memoryThreshold: Int
  public let credentialHeaderNames: Set<String>

  public init(
    request: URLRequest,
    maximumBytes: Int,
    memoryThreshold: Int = 512 * 1024,
    credentialHeaderNames: Set<String> = []
  ) {
    self.request = request
    self.maximumBytes = maximumBytes
    self.memoryThreshold = memoryThreshold
    self.credentialHeaderNames = credentialHeaderNames
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

public struct TransportMetrics: Sendable {
  public let receivedBytes: Int
  public let spilledToDisk: Bool

  public init(receivedBytes: Int, spilledToDisk: Bool) {
    self.receivedBytes = receivedBytes
    self.spilledToDisk = spilledToDisk
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
  case incompleteBody
}

public protocol HTTPTransporting: Sendable {
  func execute(_ request: TransportRequest) async throws -> TransportResponse
}
