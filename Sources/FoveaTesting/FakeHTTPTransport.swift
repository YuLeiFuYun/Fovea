import CryptoKit
import Foundation
import FoveaHTTP

public actor FakeHTTPTransport: HTTPTransporting {
  public struct Stub: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
    public let delayNanoseconds: UInt64

    public init(
      statusCode: Int, headers: [String: String] = [:], body: Data = Data(),
      delayNanoseconds: UInt64 = 0
    ) {
      self.statusCode = statusCode
      self.headers = headers
      self.body = body
      self.delayNanoseconds = delayNanoseconds
    }
  }

  private var stubs: [Stub]
  private var requests: [URLRequest] = []

  public init(stubs: [Stub]) {
    self.stubs = stubs
  }

  public func execute(_ request: TransportRequest) async throws -> TransportResponse {
    requests.append(request.request)
    guard !stubs.isEmpty else { throw URLError(.resourceUnavailable) }
    let stub = stubs.removeFirst()
    if stub.delayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: stub.delayNanoseconds)
    }
    try Task.checkCancellation()
    guard stub.body.count <= request.maximumBytes else { throw TransportError.bodyTooLarge }
    let digest = SHA256.hash(data: stub.body).map { String(format: "%02x", $0) }.joined()
    return TransportResponse(
      head: TransportResponseHead(
        statusCode: stub.statusCode, headers: stub.headers, url: request.request.url),
      body: stub.body,
      digestHex: digest,
      metrics: TransportMetrics(
        receivedBytes: stub.body.count, spilledToDisk: stub.body.count > request.memoryThreshold)
    )
  }

  public func capturedRequests() -> [URLRequest] { requests }
}
