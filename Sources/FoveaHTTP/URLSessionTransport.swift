import Foundation

public actor URLSessionTransport: HTTPTransporting {
  private let redirectDelegate: RedirectCredentialDelegate
  private let session: URLSession
  private let stagingDirectory: URL

  public init(
    configuration: URLSessionConfiguration? = nil,
    stagingDirectory: URL? = nil
  ) {
    let secureConfiguration =
      (configuration?.copy() as? URLSessionConfiguration) ?? URLSessionConfiguration.ephemeral
    secureConfiguration.urlCache = nil
    secureConfiguration.httpCookieStorage = nil
    secureConfiguration.httpShouldSetCookies = false
    secureConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData

    let redirectDelegate = RedirectCredentialDelegate()
    self.redirectDelegate = redirectDelegate
    self.session = URLSession(
      configuration: secureConfiguration,
      delegate: redirectDelegate,
      delegateQueue: nil
    )
    self.stagingDirectory =
      stagingDirectory
      ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("FoveaTransport", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: self.stagingDirectory,
      withIntermediateDirectories: true
    )
  }

  public func execute(_ request: TransportRequest) async throws -> TransportResponse {
    let (bytes, response) = try await session.bytes(for: request.request)
    guard let http = response as? HTTPURLResponse else { throw TransportError.nonHTTPResponse }

    let accumulator = try BoundedStagingAccumulator(
      maximumBytes: request.maximumBytes,
      memoryThreshold: request.memoryThreshold,
      stagingDirectory: stagingDirectory
    )
    var chunk = Data()
    chunk.reserveCapacity(16 * 1024)

    for try await byte in bytes {
      try Task.checkCancellation()
      chunk.append(byte)
      if chunk.count == 16 * 1024 {
        try accumulator.append(chunk)
        chunk.removeAll(keepingCapacity: true)
      }
    }
    try accumulator.append(chunk)
    let staged = try accumulator.finalize()

    if let expected = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
      http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() ?? "identity" == "identity",
      expected != staged.data.count
    {
      throw TransportError.incompleteBody
    }

    let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
      result[String(describing: pair.key)] = String(describing: pair.value)
    }
    return TransportResponse(
      head: TransportResponseHead(statusCode: http.statusCode, headers: headers, url: http.url),
      body: staged.data,
      digestHex: staged.digestHex,
      metrics: staged.metrics
    )
  }
}
