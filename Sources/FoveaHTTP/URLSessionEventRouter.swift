import Foundation

enum URLSessionStreamEvent: Sendable {
  case response(URLResponse)
  case data(Data)
}

final class URLSessionEventRouter: Sendable {
  private enum Command: Sendable {
    case register(
      Int,
      AsyncThrowingStream<URLSessionStreamEvent, any Error>.Continuation,
      CheckedContinuation<Void, Never>
    )
    case event(Int, URLSessionStreamEvent)
    case complete(Int, (any Error)?)
    case unregister(Int)
  }

  private let commandContinuation: AsyncStream<Command>.Continuation
  private let processor: Task<Void, Never>

  init() {
    let commands = AsyncStream<Command>.makeStream()
    commandContinuation = commands.continuation
    processor = Task { @concurrent in
      var routes: [Int: AsyncThrowingStream<URLSessionStreamEvent, any Error>.Continuation] = [:]
      for await command in commands.stream {
        switch command {
        case .register(let taskID, let continuation, let acknowledgement):
          routes[taskID] = continuation
          acknowledgement.resume()
        case .event(let taskID, let event):
          routes[taskID]?.yield(event)
        case .complete(let taskID, let error):
          let route = routes.removeValue(forKey: taskID)
          if let error {
            route?.finish(throwing: error)
          } else {
            route?.finish()
          }
        case .unregister(let taskID):
          routes.removeValue(forKey: taskID)?.finish(throwing: CancellationError())
        }
      }
    }
  }

  deinit {
    commandContinuation.finish()
    processor.cancel()
  }

  func events(
    for taskID: Int
  ) async -> AsyncThrowingStream<URLSessionStreamEvent, any Error> {
    let events = AsyncThrowingStream<URLSessionStreamEvent, any Error>.makeStream()
    events.continuation.onTermination = { [commandContinuation] _ in
      commandContinuation.yield(.unregister(taskID))
    }
    await withCheckedContinuation { acknowledgement in
      commandContinuation.yield(.register(taskID, events.continuation, acknowledgement))
    }
    return events.stream
  }

  func emit(_ event: URLSessionStreamEvent, for taskID: Int) {
    commandContinuation.yield(.event(taskID, event))
  }

  func complete(taskID: Int, error: (any Error)?) {
    commandContinuation.yield(.complete(taskID, error))
  }

  func unregister(taskID: Int) {
    commandContinuation.yield(.unregister(taskID))
  }
}

final class StreamingURLSessionDelegate: NSObject, URLSessionDataDelegate, Sendable {
  private let router: URLSessionEventRouter

  init(router: URLSessionEventRouter) {
    self.router = router
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    router.emit(.response(response), for: dataTask.taskIdentifier)
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    // URLSession delegate callbacks do not expose an async backpressure hook. Suspend before
    // enqueueing so each request has at most one unconsumed body chunk in the event pipeline.
    dataTask.suspend()
    router.emit(.data(data), for: dataTask.taskIdentifier)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    router.complete(taskID: task.taskIdentifier, error: error)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(
      CredentialHeaderPolicy.sanitizedRedirectRequest(
        original: task.currentRequest ?? task.originalRequest,
        proposed: request
      )
    )
  }
}

extension URLSessionEventRouter {
  static func makeSession(
    configuration: URLSessionConfiguration
  ) -> (router: URLSessionEventRouter, delegate: StreamingURLSessionDelegate, session: URLSession) {
    let router = URLSessionEventRouter()
    let delegate = StreamingURLSessionDelegate(router: router)
    let delegateQueue = OperationQueue()
    delegateQueue.name = "dev.fovea.http.url-session-delegate"
    delegateQueue.maxConcurrentOperationCount = 1
    delegateQueue.qualityOfService = .utility
    let session = URLSession(
      configuration: configuration,
      delegate: delegate,
      delegateQueue: delegateQueue
    )
    return (router, delegate, session)
  }
}
