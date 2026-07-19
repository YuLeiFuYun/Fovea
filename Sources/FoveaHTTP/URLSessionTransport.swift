import AkashicCore
import Foundation

public actor URLSessionTransport: HTTPTransporting {
  public nonisolated let reusePolicy: TransportReusePolicy

  private nonisolated let ioExecutor = BlockingIOExecutor(label: "dev.fovea.http.transport")

  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    ioExecutor.asUnownedSerialExecutor()
  }

  private let eventRouter: URLSessionEventRouter
  private let sessionDelegate: StreamingURLSessionDelegate
  private let session: URLSession
  private let stagingDirectory: URL

  public init(
    configuration: URLSessionConfiguration? = nil,
    stagingDirectory: URL? = nil,
    policy: URLSessionTransportPolicy? = nil,
    reusePolicy: TransportReusePolicy? = nil
  ) {
    let effectivePolicy = policy ?? (configuration == nil ? .secureDefault : nil)
    self.reusePolicy =
      reusePolicy
      ?? (configuration == nil
        ? .reusable(
          contextIdentifier:
            "fovea-url-session-secure-default-v2:\(effectivePolicy?.fingerprint ?? "none")"
        )
        : .taskLocal)
    let secureConfiguration =
      (configuration?.copy() as? URLSessionConfiguration) ?? URLSessionConfiguration.ephemeral
    secureConfiguration.urlCache = nil
    secureConfiguration.httpCookieStorage = nil
    secureConfiguration.httpShouldSetCookies = false
    secureConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
    effectivePolicy?.apply(to: secureConfiguration)

    let components = URLSessionEventRouter.makeSession(configuration: secureConfiguration)
    self.eventRouter = components.router
    self.sessionDelegate = components.delegate
    self.session = components.session
    self.stagingDirectory =
      stagingDirectory
      ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("FoveaTransport", isDirectory: true)
  }

  deinit {
    session.invalidateAndCancel()
    _ = sessionDelegate
  }

  public func execute(_ request: TransportRequest) async throws -> TransportResponse {
    let accumulator = try BoundedStagingAccumulator(
      maximumBytes: request.maximumBytes,
      memoryThreshold: request.memoryThreshold,
      stagingDirectory: stagingDirectory
    )
    var urlRequest = request.request
    urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
    let task = session.dataTask(with: urlRequest)
    task.priority = request.priority.urlSessionTaskValue
    let priorityUpdates = await request.priorityController?.updates()
    let priorityTask = priorityUpdates.map { updates in
      Task { @concurrent in
        for await priority in updates {
          task.priority = priority.urlSessionTaskValue
        }
      }
    }
    let events = await eventRouter.events(
      for: task.taskIdentifier,
      credentialHeaderNames: request.credentialHeaderNames
    )

    return try await withTaskCancellationHandler {
      task.resume()
      defer {
        priorityTask?.cancel()
        task.cancel()
        eventRouter.unregister(taskID: task.taskIdentifier)
      }

      var response: HTTPURLResponse?
      var networkMetrics: TransportNetworkMetrics?
      for try await event in events {
        try Task.checkCancellation()
        switch event {
        case .response(let receivedResponse):
          guard let http = receivedResponse as? HTTPURLResponse else {
            throw TransportError.nonHTTPResponse
          }
          response = http
        case .data(let data):
          try accumulator.append(data)
          try Task.checkCancellation()
          task.resume()
        case .metrics(let metrics):
          networkMetrics = metrics
        }
      }

      guard let response else { throw TransportError.nonHTTPResponse }
      let staged = try accumulator.finalize()
      if let expected = try Self.expectedIdentityContentLength(from: response),
        expected != staged.data.count
      {
        throw TransportError.incompleteBody
      }

      let headers = Self.headers(from: response)
      return TransportResponse(
        head: TransportResponseHead(
          statusCode: response.statusCode,
          headers: headers,
          url: response.url
        ),
        body: staged.data,
        digestHex: staged.digestHex,
        metrics: TransportMetrics(
          receivedBytes: staged.metrics.receivedBytes,
          spilledToDisk: staged.metrics.spilledToDisk,
          network: networkMetrics
        )
      )
    } onCancel: {
      priorityTask?.cancel()
      task.cancel()
      eventRouter.unregister(taskID: task.taskIdentifier)
    }
  }
  private static func expectedIdentityContentLength(
    from response: HTTPURLResponse
  ) throws -> Int? {
    let encoding =
      response.value(forHTTPHeaderField: "Content-Encoding")?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? "identity"
    guard encoding == "identity" else { return nil }
    guard let raw = response.value(forHTTPHeaderField: "Content-Length") else { return nil }

    let values = raw.split(separator: ",", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !values.isEmpty else { throw TransportError.invalidContentLength }
    var expected: Int?
    for value in values {
      guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
        let parsed = Int(value), parsed >= 0
      else {
        throw TransportError.invalidContentLength
      }
      if let expected, expected != parsed {
        throw TransportError.invalidContentLength
      }
      expected = parsed
    }
    return expected
  }

  private static func headers(from response: HTTPURLResponse) -> [String: String] {
    var pairs: [(name: String, value: String)] = []
    pairs.reserveCapacity(response.allHeaderFields.count)
    for pair in response.allHeaderFields {
      guard let name = pair.key as? String else { continue }
      let value: String
      if let string = pair.value as? String {
        value = string
      } else if let number = pair.value as? NSNumber {
        value = number.stringValue
      } else {
        continue
      }
      pairs.append((name.lowercased(), value))
    }
    pairs.sort {
      if $0.name != $1.name { return $0.name < $1.name }
      return $0.value < $1.value
    }

    var result = pairs.reduce(into: [String: String]()) { result, pair in
      if result[pair.name] == nil { result[pair.name] = pair.value }
    }
    for name in semanticHeaderNames {
      if let value = response.value(forHTTPHeaderField: name) {
        result[name.lowercased()] = value
      }
    }
    return result
  }

  private static let semanticHeaderNames = [
    "Age",
    "Cache-Control",
    "Content-Encoding",
    "Content-Length",
    "Content-Type",
    "Date",
    "ETag",
    "Expires",
    "Last-Modified",
    "Vary",
  ]

}
