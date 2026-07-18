import Foundation

public struct TransportRequest: Sendable {
  public let request: URLRequest
  public let maximumBytes: Int
  public let memoryThreshold: Int

  public init(request: URLRequest, maximumBytes: Int, memoryThreshold: Int = 512 * 1024) {
    self.request = request
    self.maximumBytes = maximumBytes
    self.memoryThreshold = memoryThreshold
  }
}

public struct TransportResponseHead: Sendable {
  public let statusCode: Int
  public let headers: [String: String]
  public let url: URL?

  public init(statusCode: Int, headers: [String: String], url: URL?) {
    self.statusCode = statusCode
    self.headers = headers
    self.url = url
  }

  public func value(forHeader name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
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
