import Foundation

package struct URLSessionRedirectContext: Sendable {
    package let credentialHeaderNames: Set<String>
    package let destinationPolicy: HTTPDestinationPolicy
}

package enum URLSessionStreamEvent: Sendable {
    case response(URLResponse)
    case data(Data)
    case metrics(TransportNetworkMetrics)
}

package final class URLSessionEventRouter: Sendable {
    private enum Command: Sendable {
        case register(
            Int,
            AsyncThrowingStream<URLSessionStreamEvent, any Error>.Continuation,
            Set<String>,
            HTTPDestinationPolicy,
            CheckedContinuation<Void, Never>
        )
        case event(Int, URLSessionStreamEvent)
        case complete(Int, (any Error)?)
        case unregister(Int)
        case redirectContext(Int, CheckedContinuation<URLSessionRedirectContext?, Never>)
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
                let destinationPolicy: HTTPDestinationPolicy
            }
            var routes: [Int: Route] = [:]
            for await command in commands.stream {
                switch command {
                case .register(
                    let taskID,
                    let continuation,
                    let credentialHeaderNames,
                    let destinationPolicy,
                    let acknowledgement
                ):
                    routes[taskID] = Route(
                        continuation: continuation,
                        credentialHeaderNames: credentialHeaderNames,
                        destinationPolicy: destinationPolicy
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
                case .redirectContext(let taskID, let continuation):
                    continuation.resume(
                        returning: routes[taskID].map { route in
                            URLSessionRedirectContext(
                                credentialHeaderNames: route.credentialHeaderNames,
                                destinationPolicy: route.destinationPolicy
                            )
                        }
                    )
                }
            }
            for route in routes.values {
                route.continuation.finish(throwing: CancellationError())
            }
            routes.removeAll(keepingCapacity: false)
        }
    }

    deinit {
        commandContinuation.finish()
        processor.cancel()
    }

    package func events(
        for taskID: Int,
        credentialHeaderNames: Set<String>,
        destinationPolicy: HTTPDestinationPolicy
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
                    destinationPolicy,
                    acknowledgement
                ))
        }
        return events.stream
    }

    package func redirectContext(for taskID: Int) async -> URLSessionRedirectContext? {
        await withCheckedContinuation { continuation in
            commandContinuation.yield(.redirectContext(taskID, continuation))
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
        // URLSession 委托回调不提供异步背压钩子。这里在转发当前回调前暂停任务，
        // 只用于降低后续读取速率；已排队回调和 URLSession 的数据合并不受此边界控制，
        // 因而它不是“一次仅一个分块”或驻留内存上限。
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
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let transactions = metrics.transactionMetrics
        let durationSeconds = max(0, metrics.taskInterval.duration)
        let durationNanoseconds =
            durationSeconds >= Double(UInt64.max) / 1_000_000_000
            ? UInt64.max
            : UInt64(durationSeconds * 1_000_000_000)
        let summary = TransportNetworkMetrics(
            taskDurationNanoseconds: durationNanoseconds,
            transactionCount: transactions.count,
            negotiatedProtocolNames: Array(
                Set(transactions.compactMap(\.networkProtocolName))
            ),
            reusedConnectionCount: transactions.filter(\.isReusedConnection).count,
            proxyConnectionCount: transactions.filter(\.isProxyConnection).count,
            cellularTransactionCount: transactions.filter(\.isCellular).count,
            expensiveTransactionCount: transactions.filter(\.isExpensive).count,
            constrainedTransactionCount: transactions.filter(\.isConstrained).count,
            redirectCount: metrics.redirectCount,
            domainLookupDurationNanoseconds: Self.aggregateDuration(
                transactions,
                from: \.domainLookupStartDate,
                to: \.domainLookupEndDate
            ),
            connectionDurationNanoseconds: Self.aggregateDuration(
                transactions,
                from: \.connectStartDate,
                to: \.connectEndDate
            ),
            secureConnectionDurationNanoseconds: Self.aggregateDuration(
                transactions,
                from: \.secureConnectionStartDate,
                to: \.secureConnectionEndDate
            ),
            requestDurationNanoseconds: Self.aggregateDuration(
                transactions,
                from: \.requestStartDate,
                to: \.requestEndDate
            ),
            timeToFirstByteNanoseconds: Self.aggregateDuration(
                transactions,
                from: \.fetchStartDate,
                to: \.responseStartDate
            ),
            responseDurationNanoseconds: Self.aggregateDuration(
                transactions,
                from: \.responseStartDate,
                to: \.responseEndDate
            )
        )
        router.emit(.metrics(summary), for: task.taskIdentifier)
    }

    private static func aggregateDuration(
        _ transactions: [URLSessionTaskTransactionMetrics],
        from start: KeyPath<URLSessionTaskTransactionMetrics, Date?>,
        to end: KeyPath<URLSessionTaskTransactionMetrics, Date?>
    ) -> UInt64? {
        var total: UInt64 = 0
        var observed = false
        for transaction in transactions {
            guard let startDate = transaction[keyPath: start],
                let endDate = transaction[keyPath: end]
            else { continue }
            observed = true
            let interval = max(0, endDate.timeIntervalSince(startDate))
            let value =
                interval >= Double(UInt64.max) / 1_000_000_000
                ? UInt64.max
                : UInt64(interval * 1_000_000_000)
            let (sum, overflow) = total.addingReportingOverflow(value)
            total = overflow ? UInt64.max : sum
        }
        return observed ? total : nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        Task { @concurrent [router] in
            guard let context = await router.redirectContext(for: task.taskIdentifier) else {
                completionHandler(nil)
                router.complete(
                    taskID: task.taskIdentifier,
                    error: TransportError.destinationDisallowed
                )
                task.cancel()
                return
            }
            do {
                completionHandler(
                    try HTTPRedirectPolicy.request(
                        original: task.currentRequest ?? task.originalRequest,
                        proposed: request,
                        additionalSensitiveNames: context.credentialHeaderNames,
                        destinationPolicy: context.destinationPolicy
                    )
                )
            } catch {
                completionHandler(nil)
                router.complete(taskID: task.taskIdentifier, error: error)
                task.cancel()
            }
        }
    }
}

extension URLSessionEventRouter {
    static func makeSession(
        configuration: URLSessionConfiguration
    ) -> (router: URLSessionEventRouter, delegate: StreamingURLSessionDelegate, session: URLSession)
    {
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
