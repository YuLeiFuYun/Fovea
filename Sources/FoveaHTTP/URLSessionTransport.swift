import AkashicCore
import Foundation

public actor URLSessionTransport: HTTPTransporting {
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
    stagingDirectory: URL? = nil
  ) {
    let secureConfiguration =
      (configuration?.copy() as? URLSessionConfiguration) ?? URLSessionConfiguration.ephemeral
    secureConfiguration.urlCache = nil
    secureConfiguration.httpCookieStorage = nil
    secureConfiguration.httpShouldSetCookies = false
    secureConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData

    let components = URLSessionEventRouter.makeSession(configuration: secureConfiguration)
    self.eventRouter = components.router
    self.sessionDelegate = components.delegate
    self.session = components.session
    self.stagingDirectory =
      stagingDirectory
      ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("FoveaTransport", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: self.stagingDirectory,
      withIntermediateDirectories: true
    )
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
    let task = session.dataTask(with: request.request)
    let events = await eventRouter.events(for: task.taskIdentifier)

    return try await withTaskCancellationHandler {
      task.resume()
      defer {
        task.cancel()
        eventRouter.unregister(taskID: task.taskIdentifier)
      }

      var response: HTTPURLResponse?
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
        }
      }

      guard let response else { throw TransportError.nonHTTPResponse }
      let staged = try accumulator.finalize()
      if let expected = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
        response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() ?? "identity"
          == "identity",
        expected != staged.data.count
      {
        throw TransportError.incompleteBody
      }

      let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
        result[String(describing: pair.key)] = String(describing: pair.value)
      }
      return TransportResponse(
        head: TransportResponseHead(
          statusCode: response.statusCode,
          headers: headers,
          url: response.url
        ),
        body: staged.data,
        digestHex: staged.digestHex,
        metrics: staged.metrics
      )
    } onCancel: {
      task.cancel()
      eventRouter.unregister(taskID: task.taskIdentifier)
    }
  }
}
