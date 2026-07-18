import Foundation

package enum URLSessionStreamEvent: Sendable {
  case response(URLResponse)
  case data(Data)
}

package final class URLSessionEventRouter: Sendable {
  private enum Command: Sendable {
    case register(
      Int,
      AsyncThrowingStream<URLSessionStreamEvent, any Error>.Continuation,
      Set<String>,
      CheckedContinuation<Void, Never>
    )
    case event(Int, URLSessionStreamEvent)
    case complete(Int, (any Error)?)
    case unregister(Int)
    case credentialHeaders(Int, CheckedContinuation<Set<String>, Never>)
  }

  private let commandContinuation: AsyncStream<Command>.Continuation
  private let processor: Task<Void, Never>

  package init() {
    let commands = AsyncStream<Command>.makeStream()
    commandContinuation = commands.continuation
    processor = Task { @concurrent in
      struct Route {
        let continuation: AsyncThrowingStream<URLSessionStreamEvent, any Error>.Continuation
        let credentialHeaderNames: Set<String>
      }
      var routes: [Int: Route] = [:]
      for await command in commands.stream {
        switch command {
        case .register(
          let taskID,
          let continuation,
          let credentialHeaderNames,
          let acknowledgement
        ):
          routes[taskID] = Route(
            continuation: continuation,
            credentialHeaderNames: credentialHeaderNames
          )
          acknowledgement.resume()
        case .event(let taskID, let event):
          routes[taskID]?.continuation.yield(event)
        case .complete(let taskID, let error):
          let route = routes.removeValue(forKey: taskID)
          if let error {
            route?.continuation.finish(throwing: error)
          } else {
            route?.continuation.finish()
          }
        case .unregister(let taskID):
          routes.removeValue(forKey: taskID)?.continuation.finish(
            throwing: CancellationError()
          )
        case .credentialHeaders(let taskID, let continuation):
          continuation.resume(returning: routes[taskID]?.credentialHeaderNames ?? [])
        }
      }
    }
  }

  deinit {
    commandContinuation.finish()
    processor.cancel()
  }

  package func events(
    for taskID: Int,
    credentialHeaderNames: Set<String>
  ) async -> AsyncThrowingStream<URLSessionStreamEvent, any Error> {
    let events = AsyncThrowingStream<URLSessionStreamEvent, any Error>.makeStream()
    events.continuation.onTermination = { [commandContinuation] _ in
      commandContinuation.yield(.unregister(taskID))
    }
    await withCheckedContinuation { acknowledgement in
      commandContinuation.yield(
        .register(
          taskID,
          events.continuation,
          credentialHeaderNames,
          acknowledgement
        ))
    }
    return events.stream
  }

  package func credentialHeaderNames(for taskID: Int) async -> Set<String> {
    await withCheckedContinuation { continuation in
      commandContinuation.yield(.credentialHeaders(taskID, continuation))
    }
  }

  package func emit(_ event: URLSessionStreamEvent, for taskID: Int) {
    commandContinuation.yield(.event(taskID, event))
  }

  func complete(taskID: Int, error: (any Error)?) {
    commandContinuation.yield(.complete(taskID, error))
  }

  package func unregister(taskID: Int) {
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
    Task { @concurrent [router] in
      let customCredentialHeaders = await router.credentialHeaderNames(
        for: task.taskIdentifier
      )
      completionHandler(
        CredentialHeaderPolicy.sanitizedRedirectRequest(
          original: task.currentRequest ?? task.originalRequest,
          proposed: request,
          additionalSensitiveNames: customCredentialHeaders
        )
      )
    }
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
