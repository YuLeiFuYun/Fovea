import Foundation
import Network

private struct LoopbackBenchmarkOriginResource: Sendable {
    let fileURL: URL
    let mimeType: String
}

private final class LoopbackBenchmarkOriginStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?

    init(_ continuation: CheckedContinuation<URL, any Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<URL, any Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class LoopbackBenchmarkConnectionOutcome: @unchecked Sendable {
    struct Completion: Sendable {
        let isFirst: Bool
        let requestBegan: Bool
    }

    private let lock = NSLock()
    private var finished = false
    private var requestBegan = false

    func markRequestBegan() {
        lock.lock()
        requestBegan = true
        lock.unlock()
    }

    func finish() -> Completion {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else {
            return Completion(isFirst: false, requestBegan: requestBegan)
        }
        finished = true
        return Completion(isFirst: true, requestBegan: requestBegan)
    }
}

final class LoopbackBenchmarkOriginServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.fovea.comparative.loopback-origin")
    private let lock = NSLock()
    private let profile: BenchmarkNetworkProfile
    private let assets: [String: LoopbackBenchmarkOriginResource]
    private let heroes: [String: LoopbackBenchmarkOriginResource]
    private let probes: [String: LoopbackBenchmarkOriginResource]
    private var listener: NWListener?
    private var requestCount = 0
    private var deliveredBytes = 0
    private var completedRequestCount = 0
    private var stoppedRequestCount = 0
    private var activeConnections = 0
    private var peakConcurrentRequestCount = 0
    private var routeRequestCounts: [String: Int] = [:]

    init(catalog: ResourceCatalog, profile: BenchmarkNetworkProfile) throws {
        self.profile = profile
        assets = try Dictionary(
            uniqueKeysWithValues: catalog.dataset.assets.map { asset in
                (
                    asset.assetID,
                    LoopbackBenchmarkOriginResource(
                        fileURL: try catalog.fileURL(for: asset),
                        mimeType: asset.mimeType
                    )
                )
            }
        )
        heroes = try Dictionary(
            uniqueKeysWithValues: [
                "hero-12mp-4000x3000.jpg",
                "hero-24mp-6000x4000.jpg",
                "hero-48mp-8000x6000.jpg",
            ].map { name in
                (
                    name,
                    LoopbackBenchmarkOriginResource(
                        fileURL: try catalog.heroURL(named: name),
                        mimeType: "image/jpeg"
                    )
                )
            }
        )
        probes = try Dictionary(
            uniqueKeysWithValues: catalog.correctnessProbes.probes.map { probe in
                (
                    probe.identifier,
                    LoopbackBenchmarkOriginResource(
                        fileURL: try catalog.probeURL(for: probe),
                        mimeType: probe.mimeType
                    )
                )
            }
        )
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let gate = LoopbackBenchmarkOriginStartGate(continuation)
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters, on: .any)
                self.listener = listener
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard let port = listener.port,
                            let url = URL(string: "http://127.0.0.1:\(port.rawValue)")
                        else {
                            gate.resume(
                                with: .failure(
                                    BenchmarkAppError.runFailed("loopback-origin-port")
                                )
                            )
                            return
                        }
                        gate.resume(with: .success(url))
                    case .failed(let error):
                        gate.resume(with: .failure(error))
                    case .cancelled:
                        gate.resume(
                            with: .failure(
                                BenchmarkAppError.runFailed("loopback-origin-cancelled")
                            )
                        )
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
            } catch {
                gate.resume(with: .failure(error))
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func resetMetrics() {
        lock.lock()
        requestCount = 0
        deliveredBytes = 0
        completedRequestCount = 0
        stoppedRequestCount = 0
        activeConnections = 0
        peakConcurrentRequestCount = 0
        routeRequestCounts.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func snapshot() -> BenchmarkOriginMetrics {
        lock.lock()
        defer { lock.unlock() }
        return BenchmarkOriginMetrics(
            requestCount: requestCount,
            deliveredBytes: deliveredBytes,
            postCancellationBytes: 0,
            completedRequestCount: completedRequestCount,
            stoppedRequestCount: stoppedRequestCount,
            redirectAuthorizationLeakCount: 0,
            peakConcurrentRequestCount: peakConcurrentRequestCount,
            w7SharedPreparationWaitCount: 0,
            w7ServiceStartOrder: [],
            routeRequestCounts: routeRequestCounts
        )
    }

    private func accept(_ connection: NWConnection) {
        let outcome = LoopbackBenchmarkConnectionOutcome()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                let completion = outcome.finish()
                if completion.isFirst, completion.requestBegan { self.recordStopped() }
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data(), outcome: outcome)
    }

    private func receiveRequest(
        on connection: NWConnection,
        accumulated: Data,
        outcome: LoopbackBenchmarkConnectionOutcome
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let error {
                let completion = outcome.finish()
                if completion.isFirst, completion.requestBegan { self.recordStopped() }
                connection.cancel()
                _ = error
                return
            }
            var requestData = accumulated
            if let data { requestData.append(data) }
            if requestData.range(of: Data("\r\n\r\n".utf8)) == nil, !isComplete,
                requestData.count < 32_768
            {
                self.receiveRequest(on: connection, accumulated: requestData, outcome: outcome)
                return
            }
            self.handleRequest(requestData, connection: connection, outcome: outcome)
        }
    }

    private func handleRequest(
        _ requestData: Data,
        connection: NWConnection,
        outcome: LoopbackBenchmarkConnectionOutcome
    ) {
        outcome.markRequestBegan()
        guard let requestText = String(data: requestData, encoding: .utf8),
            let firstLine = requestText.components(separatedBy: "\r\n").first,
            firstLine.hasPrefix("GET "),
            let target = firstLine.split(separator: " ").dropFirst().first,
            let components = URLComponents(string: String(target))
        else {
            recordBegin(route: "<invalid>")
            sendStatus(400, connection: connection, outcome: outcome)
            return
        }
        let route = components.path
        recordBegin(route: route)
        guard let resource = resource(for: route) else {
            sendStatus(404, connection: connection, outcome: outcome)
            return
        }
        do {
            let body = try Data(contentsOf: resource.fileURL, options: [.mappedIfSafe])
            var response = Data(
                "HTTP/1.1 200 OK\r\nContent-Type: \(resource.mimeType)\r\nContent-Length: \(body.count)\r\nCache-Control: public, max-age=3600\r\nConnection: close\r\n\r\n"
                    .utf8
            )
            response.append(body)
            let payload = response
            let bodyCount = body.count
            let transfer = UInt64(
                (Double(bodyCount) / Double(max(1, profile.bytesPerSecond))) * 1_000_000_000
            )
            let delay = profile.initialDelayNanoseconds + transfer
            queue.asyncAfter(
                deadline: .now() + .nanoseconds(Int(min(UInt64(Int.max), delay)))
            ) { [weak self] in
                guard let self else {
                    connection.cancel()
                    return
                }
                connection.send(
                    content: payload,
                    completion: .contentProcessed { error in
                        let completion = outcome.finish()
                        if completion.isFirst {
                            if error == nil {
                                self.recordCompleted(bytes: bodyCount)
                            } else if completion.requestBegan {
                                self.recordStopped()
                            }
                        }
                        connection.cancel()
                    }
                )
            }
        } catch {
            sendStatus(500, connection: connection, outcome: outcome)
        }
    }

    private func resource(for route: String) -> LoopbackBenchmarkOriginResource? {
        if route.hasPrefix("/asset/") {
            let identifier = String(route.dropFirst("/asset/".count)).removingPercentEncoding ?? ""
            return assets[identifier]
        }
        if route.hasPrefix("/hero/") {
            let name = String(route.dropFirst("/hero/".count)).removingPercentEncoding ?? ""
            return heroes[name]
        }
        if route.hasPrefix("/probe/") {
            let identifier =
                String(route.dropFirst("/probe/".count)).removingPercentEncoding ?? ""
            return probes[identifier]
        }
        return nil
    }

    private func sendStatus(
        _ status: Int,
        connection: NWConnection,
        outcome: LoopbackBenchmarkConnectionOutcome
    ) {
        let reason = status == 404 ? "Not Found" : "Bad Request"
        let body = Data("\(status) \(reason)".utf8)
        let response =
            Data(
                "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                    .utf8
            ) + body
        connection.send(
            content: response,
            completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                if outcome.finish().isFirst { self.recordCompleted(bytes: body.count) }
                connection.cancel()
            })
    }

    private func recordBegin(route: String) {
        lock.lock()
        requestCount += 1
        activeConnections += 1
        peakConcurrentRequestCount = max(peakConcurrentRequestCount, activeConnections)
        routeRequestCounts[route, default: 0] += 1
        lock.unlock()
    }

    private func recordCompleted(bytes: Int) {
        lock.lock()
        completedRequestCount += 1
        deliveredBytes += bytes
        activeConnections = max(0, activeConnections - 1)
        lock.unlock()
    }

    private func recordStopped() {
        lock.lock()
        stoppedRequestCount += 1
        activeConnections = max(0, activeConnections - 1)
        lock.unlock()
    }
}
