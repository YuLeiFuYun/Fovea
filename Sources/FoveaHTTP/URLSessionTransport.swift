import AkashicCore
import CryptoKit
import Foundation
import FoveaStorage

private final class URLSessionTaskLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private let priorityTask: Task<Void, Never>?
    private let task: URLSessionTask
    private let eventRouter: URLSessionEventRouter
    private var isFinished = false
    private var isRegistered = false
    private var didUnregister = false

    init(
        priorityTask: Task<Void, Never>?,
        task: URLSessionTask,
        eventRouter: URLSessionEventRouter
    ) {
        self.priorityTask = priorityTask
        self.task = task
        self.eventRouter = eventRouter
    }

    func didRegister() {
        lock.lock()
        isRegistered = true
        let shouldUnregister = isFinished && !didUnregister
        if shouldUnregister { didUnregister = true }
        lock.unlock()

        if shouldUnregister {
            eventRouter.unregister(taskID: task.taskIdentifier)
        }
    }

    func finishOnce() {
        lock.lock()
        let shouldCancelTask = !isFinished
        if shouldCancelTask { isFinished = true }
        let shouldUnregister = isRegistered && !didUnregister
        if shouldUnregister { didUnregister = true }
        lock.unlock()

        if shouldCancelTask {
            priorityTask?.cancel()
            task.cancel()
        }
        if shouldUnregister {
            eventRouter.unregister(taskID: task.taskIdentifier)
        }
    }
}

/// 具备硬上限、重定向防护、环境状态净化与网络指标的 URLSession transport。

public actor URLSessionTransport: HTTPTransporting, TransportProgressOnlyExecuting {
    public nonisolated let reusePolicy: TransportReusePolicy

    private nonisolated let ioExecutor = FoveaBlockingIOExecutor(label: "dev.fovea.http.transport")

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        ioExecutor.asUnownedSerialExecutor()
    }

    private let eventRouter: URLSessionEventRouter
    private let sessionDelegate: StreamingURLSessionDelegate
    private let session: URLSession
    private let stagingRoot: URL
    private var stagingLease: StagingDirectoryLease?
    private var isInvalidated = false
    private let proxyPolicy: URLSessionProxyPolicy
    private let destinationPolicy: HTTPDestinationPolicy

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
        let secureConfiguration = Self.sanitizedConfiguration(
            configuration,
            policy: effectivePolicy
        )

        let components = URLSessionEventRouter.makeSession(configuration: secureConfiguration)
        self.eventRouter = components.router
        self.sessionDelegate = components.delegate
        self.session = components.session
        self.proxyPolicy = effectivePolicy?.proxyPolicy ?? .system
        self.destinationPolicy = effectivePolicy?.destinationPolicy ?? .secureDefault
        self.stagingRoot =
            stagingDirectory
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("FoveaTransport", isDirectory: true)
        self.stagingLease = nil
    }

    deinit {
        session.invalidateAndCancel()
        _ = sessionDelegate
    }

    package static func sanitizedConfiguration(
        _ source: URLSessionConfiguration?,
        policy: URLSessionTransportPolicy?
    ) -> URLSessionConfiguration {
        let configuration =
            (source?.copy() as? URLSessionConfiguration) ?? URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        policy?.apply(to: configuration)
        return configuration
    }

    /// 取消进行中的任务、释放 staging lease，并永久关闭该 transport。
    /// 重复调用安全；关闭后的新执行请求统一表现为取消。
    package func invalidateAndCancel() {
        guard !isInvalidated else { return }
        isInvalidated = true
        session.invalidateAndCancel()
        stagingLease = nil
    }

    public func execute(_ request: TransportRequest) async throws -> TransportResponse {
        try Task.checkCancellation()
        guard !isInvalidated else { throw CancellationError() }
        guard let url = request.request.url, destinationPolicy.permits(url) else {
            throw TransportError.destinationDisallowed
        }

        let stagingLease = try await activeStagingLease()
        try Task.checkCancellation()
        guard !isInvalidated else { throw CancellationError() }
        let accumulator = try BoundedStagingAccumulator(
            maximumBytes: request.maximumBytes,
            memoryThreshold: request.memoryThreshold,
            stagingLease: stagingLease
        )
        let priorityUpdates = await request.priorityController?.updates()
        try Task.checkCancellation()

        var urlRequest = request.request
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.dataTask(with: urlRequest)
        task.priority = request.priority.urlSessionTaskValue
        let priorityTask = makePriorityPropagation(
            updates: priorityUpdates,
            task: task
        )
        let lifetime = URLSessionTaskLifetime(
            priorityTask: priorityTask,
            task: task,
            eventRouter: eventRouter
        )

        return try await withTaskCancellationHandler {
            let events = await eventRouter.events(
                for: task.taskIdentifier,
                credentialHeaderNames: request.credentialHeaderNames,
                destinationPolicy: destinationPolicy
            )
            lifetime.didRegister()
            defer { lifetime.finishOnce() }
            // 取消回调可能先于 register 命令到达；注册确认后必须再次检查并注销。
            try Task.checkCancellation()
            task.resume()
            let received: (
                response: HTTPURLResponse,
                networkMetrics: TransportNetworkMetrics?
            )
            do {
                received = try await consume(
                    events: events,
                    task: task,
                    accumulator: accumulator,
                    progressObserver: request.progressObserver
                )
            } catch {
                try Task.checkCancellation()
                throw error
            }
            try Task.checkCancellation()
            let response = try makeResponse(
                response: received.response,
                networkMetrics: received.networkMetrics,
                accumulator: accumulator,
                bodyDelivery: request.bodyDelivery
            )
            try Task.checkCancellation()
            request.progressObserver?(
                .complete(
                    digestHex: response.digestHex,
                    byteCount: response.bodyByteCount
                )
            )
            return response
        } onCancel: {
            lifetime.finishOnce()
        }
    }

    /// 执行不保留完整正文的 progress-only 长流。该路径仍使用相同 URLSession、
    /// destination/redirect/proxy/credential 约束和响应字节硬上限。
    package func executeProgressOnly(
        _ request: TransportRequest
    ) async throws -> TransportProgressCompletion {
        try Task.checkCancellation()
        guard !isInvalidated else { throw CancellationError() }
        guard let url = request.request.url, destinationPolicy.permits(url) else {
            throw TransportError.destinationDisallowed
        }
        let priorityUpdates = await request.priorityController?.updates()
        try Task.checkCancellation()

        var urlRequest = request.request
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.dataTask(with: urlRequest)
        task.priority = request.priority.urlSessionTaskValue
        let priorityTask = makePriorityPropagation(updates: priorityUpdates, task: task)
        let lifetime = URLSessionTaskLifetime(
            priorityTask: priorityTask,
            task: task,
            eventRouter: eventRouter
        )

        return try await withTaskCancellationHandler {
            let events = await eventRouter.events(
                for: task.taskIdentifier,
                credentialHeaderNames: request.credentialHeaderNames,
                destinationPolicy: destinationPolicy
            )
            lifetime.didRegister()
            defer { lifetime.finishOnce() }
            try Task.checkCancellation()
            task.resume()
            let received: (
                response: HTTPURLResponse,
                networkMetrics: TransportNetworkMetrics?,
                digest: SHA256,
                byteCount: Int
            )
            do {
                received = try await consumeProgressOnly(
                    events: events,
                    task: task,
                    maximumBytes: request.maximumBytes,
                    progressObserver: request.progressObserver
                )
            } catch {
                try Task.checkCancellation()
                throw error
            }
            try Task.checkCancellation()
            try proxyPolicy.validate(received.networkMetrics)
            if let expected = try Self.expectedIdentityContentLength(from: received.response),
                expected != received.byteCount
            {
                throw TransportError.incompleteBody
            }
            let digestHex = httpLowercaseHexString(received.digest.finalize())
            let completion = TransportProgressCompletion(
                head: try Self.responseHead(from: received.response),
                digestHex: digestHex,
                byteCount: received.byteCount,
                metrics: TransportMetrics(
                    receivedBytes: received.byteCount,
                    spilledToDisk: false,
                    network: received.networkMetrics
                )
            )
            try Task.checkCancellation()
            request.progressObserver?(
                .complete(
                    digestHex: completion.digestHex,
                    byteCount: completion.byteCount
                )
            )
            return completion
        } onCancel: {
            lifetime.finishOnce()
        }
    }

    private func consumeProgressOnly(
        events: AsyncThrowingStream<URLSessionStreamEvent, any Error>,
        task: URLSessionDataTask,
        maximumBytes: Int,
        progressObserver: TransportProgressObserver?
    ) async throws -> (
        response: HTTPURLResponse,
        networkMetrics: TransportNetworkMetrics?,
        digest: SHA256,
        byteCount: Int
    ) {
        var response: HTTPURLResponse?
        var networkMetrics: TransportNetworkMetrics?
        var digest = SHA256()
        var byteCount = 0
        for try await event in events {
            try Task.checkCancellation()
            switch event {
            case .response(let receivedResponse):
                guard let http = receivedResponse as? HTTPURLResponse else {
                    throw TransportError.nonHTTPResponse
                }
                if let expected = try Self.expectedIdentityContentLength(from: http),
                    expected > maximumBytes
                {
                    throw TransportError.bodyTooLarge
                }
                response = http
                progressObserver?(.response(try Self.responseHead(from: http)))
            case .data(let data):
                let next = byteCount.addingReportingOverflow(data.count)
                guard !next.overflow, next.partialValue <= maximumBytes else {
                    throw TransportError.bodyTooLarge
                }
                byteCount = next.partialValue
                digest.update(data: data)
                progressObserver?(.data(data, cumulativeByteCount: byteCount))
                try Task.checkCancellation()
                task.resume()
            case .metrics(let metrics):
                networkMetrics = metrics
            }
        }
        guard let response else { throw TransportError.nonHTTPResponse }
        return (response, networkMetrics, digest, byteCount)
    }

    private func makePriorityPropagation(
        updates: AsyncStream<TransportPriority>?,
        task: URLSessionTask
    ) -> Task<Void, Never>? {
        updates.map { updates in
            Task { @concurrent in
                for await priority in updates {
                    task.priority = priority.urlSessionTaskValue
                }
            }
        }
    }

    private func consume(
        events: AsyncThrowingStream<URLSessionStreamEvent, any Error>,
        task: URLSessionDataTask,
        accumulator: BoundedStagingAccumulator,
        progressObserver: TransportProgressObserver?
    ) async throws -> (response: HTTPURLResponse, networkMetrics: TransportNetworkMetrics?) {
        var response: HTTPURLResponse?
        var networkMetrics: TransportNetworkMetrics?
        for try await event in events {
            try Task.checkCancellation()
            switch event {
            case .response(let receivedResponse):
                guard let http = receivedResponse as? HTTPURLResponse else {
                    throw TransportError.nonHTTPResponse
                }
                if let expected = try Self.expectedIdentityContentLength(from: http) {
                    try accumulator.reserveCapacity(forExpectedByteCount: expected)
                }
                response = http
                if let progressObserver {
                    progressObserver(.response(try Self.responseHead(from: http)))
                }
            case .data(let data):
                try accumulator.append(data)
                if let progressObserver {
                    progressObserver(
                        .data(data, cumulativeByteCount: accumulator.receivedByteCount)
                    )
                }
                try Task.checkCancellation()
                task.resume()
            case .metrics(let metrics):
                networkMetrics = metrics
            }
        }
        guard let response else { throw TransportError.nonHTTPResponse }
        return (response, networkMetrics)
    }

    private func makeResponse(
        response: HTTPURLResponse,
        networkMetrics: TransportNetworkMetrics?,
        accumulator: BoundedStagingAccumulator,
        bodyDelivery: TransportBodyDelivery
    ) throws -> TransportResponse {
        try proxyPolicy.validate(networkMetrics)
        let staged = try accumulator.finalize(bodyDelivery: bodyDelivery)
        if let expected = try Self.expectedIdentityContentLength(from: response),
            expected != staged.byteCount
        {
            throw TransportError.incompleteBody
        }
        return TransportResponse(
            head: try Self.responseHead(from: response),
            bodyStorage: staged.storage,
            verifiedDigest: staged.verifiedDigest,
            metrics: TransportMetrics(
                receivedBytes: staged.metrics.receivedBytes,
                spilledToDisk: staged.metrics.spilledToDisk,
                network: networkMetrics
            )
        )
    }

    private func activeStagingLease() async throws -> StagingDirectoryLease {
        try Task.checkCancellation()
        guard !isInvalidated else { throw CancellationError() }
        if let stagingLease { return stagingLease }
        let acquired = try await StagingDirectoryLease.acquire(root: stagingRoot)
        try Task.checkCancellation()
        guard !isInvalidated else { throw CancellationError() }
        stagingLease = acquired
        return acquired
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

    package static func responseHead(from response: HTTPURLResponse) throws -> TransportResponseHead
    {
        guard response.allHeaderFields.count <= HTTPMetadataLimits.maximumHeaderCount else {
            throw TransportError.responseHeadersTooLarge
        }
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
            pairs.append((name, value))
        }
        pairs.sort {
            let lhs = $0.name.lowercased()
            let rhs = $1.name.lowercased()
            if lhs != rhs { return lhs < rhs }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.value < $1.value
        }

        var headers = pairs.reduce(into: [String: String]()) { result, pair in
            let name = pair.name.lowercased()
            if result[name] == nil { result[name] = pair.value }
        }
        for name in semanticHeaderNames {
            if let value = response.value(forHTTPHeaderField: name) {
                headers[name.lowercased()] = value
            }
        }
        return try TransportResponseHead(
            statusCode: response.statusCode,
            headers: headers,
            url: response.url
        )
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
