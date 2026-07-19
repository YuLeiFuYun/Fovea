import CryptoKit
import Foundation
import FoveaHTTP

public actor DeterministicImageOrigin: HTTPTransporting {
  public nonisolated let reusePolicy = TransportReusePolicy.reusable(
    contextIdentifier: "fovea-testing-deterministic-origin-v1"
  )

  public struct Resource: Sendable {
    public let url: URL
    public let body: Data
    public let headers: [String: String]
    public let delayNanoseconds: UInt64

    public init(
      url: URL,
      body: Data,
      contentType: String,
      cacheControl: String = "max-age=3600",
      etag: String? = nil,
      delayNanoseconds: UInt64 = 0
    ) {
      self.url = url
      self.body = body
      var headers = [
        "Content-Type": contentType,
        "Cache-Control": cacheControl,
      ]
      if let etag { headers["ETag"] = etag }
      self.headers = headers
      self.delayNanoseconds = delayNanoseconds
    }
  }

  public struct Metrics: Codable, Hashable, Sendable {
    public let requestCount: Int
    public let successfulResponseCount: Int
    public let notModifiedCount: Int
    public let cancellationCount: Int
    public let deliveredBytes: Int
    public let duplicateRequestCount: Int
    public let requestsByResource: [String: Int]

    public init(
      requestCount: Int,
      successfulResponseCount: Int,
      notModifiedCount: Int,
      cancellationCount: Int,
      deliveredBytes: Int,
      duplicateRequestCount: Int,
      requestsByResource: [String: Int]
    ) {
      self.requestCount = requestCount
      self.successfulResponseCount = successfulResponseCount
      self.notModifiedCount = notModifiedCount
      self.cancellationCount = cancellationCount
      self.deliveredBytes = deliveredBytes
      self.duplicateRequestCount = duplicateRequestCount
      self.requestsByResource = requestsByResource
    }
  }

  private let resources: [String: Resource]
  private var requestsByResource: [String: Int] = [:]
  private var successfulResponseCount = 0
  private var notModifiedCount = 0
  private var cancellationCount = 0
  private var deliveredBytes = 0

  public init(resources: [Resource]) {
    self.resources = Dictionary(uniqueKeysWithValues: resources.map { ($0.url.absoluteString, $0) })
  }

  public func execute(_ request: TransportRequest) async throws -> TransportResponse {
    guard let url = request.request.url,
      let resource = resources[url.absoluteString]
    else {
      throw URLError(.resourceUnavailable)
    }
    requestsByResource[url.absoluteString, default: 0] += 1

    do {
      if resource.delayNanoseconds > 0 {
        try await Task.sleep(nanoseconds: resource.delayNanoseconds)
      }
      try Task.checkCancellation()
    } catch {
      if error is CancellationError { cancellationCount += 1 }
      throw error
    }

    if let etag = header("ETag", in: resource.headers),
      request.request.value(forHTTPHeaderField: "If-None-Match") == etag
    {
      notModifiedCount += 1
      return TransportResponse(
        head: TransportResponseHead(statusCode: 304, headers: resource.headers, url: url),
        body: Data(),
        digestHex: SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined(),
        metrics: TransportMetrics(receivedBytes: 0, spilledToDisk: false)
      )
    }

    guard resource.body.count <= request.maximumBytes else { throw TransportError.bodyTooLarge }
    successfulResponseCount += 1
    deliveredBytes += resource.body.count
    let digest = SHA256.hash(data: resource.body).map { String(format: "%02x", $0) }.joined()
    return TransportResponse(
      head: TransportResponseHead(statusCode: 200, headers: resource.headers, url: url),
      body: resource.body,
      digestHex: digest,
      metrics: TransportMetrics(
        receivedBytes: resource.body.count,
        spilledToDisk: resource.body.count > request.memoryThreshold
      )
    )
  }

  public func metrics() -> Metrics {
    let requestCount = requestsByResource.values.reduce(0, +)
    let duplicateRequestCount = requestsByResource.values.reduce(0) { total, count in
      total + max(0, count - 1)
    }
    return Metrics(
      requestCount: requestCount,
      successfulResponseCount: successfulResponseCount,
      notModifiedCount: notModifiedCount,
      cancellationCount: cancellationCount,
      deliveredBytes: deliveredBytes,
      duplicateRequestCount: duplicateRequestCount,
      requestsByResource: requestsByResource
    )
  }

  private func header(_ name: String, in headers: [String: String]) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }
}
