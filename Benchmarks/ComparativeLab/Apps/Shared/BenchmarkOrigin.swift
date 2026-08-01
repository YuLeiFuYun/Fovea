import Foundation
import UIKit

private struct OriginResource: Sendable {
    let data: Data
    let mimeType: String
    let statusCode: Int
    let headers: [String: String]
    let delayNanoseconds: UInt64
}

private struct OriginServiceReservation: Sendable {
    let identifier: UUID
    let startsImmediately: Bool
}

private final class BenchmarkOriginState: @unchecked Sendable {
    static let shared = BenchmarkOriginState()

    private static let w7ConcurrentServiceLimit = 8

    private let lock = NSLock()
    private let w7ServiceQueue = DispatchQueue(
        label: "dev.fovea.comparative.origin.w7-service",
        attributes: .concurrent
    )
    private var assetFiles: [String: (URL, String)] = [:]
    private var heroFiles: [String: URL] = [:]
    private var probeFiles: [String: (URL, String)] = [:]
    private var profile: BenchmarkNetworkProfile = .local
    private var cancelledRequestIDs: Set<String> = []
    private var offlineRoutes: Set<String> = []
    private var requestCount = 0
    private var deliveredBytes = 0
    private var postCancellationBytes = 0
    private var completedRequestCount = 0
    private var stoppedRequestCount = 0
    private var redirectAuthorizationLeakCount = 0
    private var peakConcurrentRequestCount = 0
    private var w7ActiveServiceIDs: Set<UUID> = []
    private var w7QueuedServiceIDs: [UUID] = []
    private var w7ServiceLabels: [UUID: String] = [:]
    private var w7ServiceStartOrder: [String] = []
    private var w7ServiceOperations: [UUID: @Sendable (UUID) -> Void] = [:]
    private var routeRequestCounts: [String: Int] = [:]
    private var accountAData = Data()
    private var accountBData = Data()
    private var neutralData = Data()

    func configure(catalog: ResourceCatalog, profile: BenchmarkNetworkProfile) throws {
        var files: [String: (URL, String)] = [:]
        for asset in catalog.dataset.assets {
            files[asset.assetID] = (try catalog.fileURL(for: asset), asset.mimeType)
        }
        var heroes: [String: URL] = [:]
        for name in [
            "hero-12mp-4000x3000.jpg",
            "hero-24mp-6000x4000.jpg",
            "hero-48mp-8000x6000.jpg",
        ] {
            heroes[name] = try catalog.heroURL(named: name)
        }
        var probes: [String: (URL, String)] = [:]
        for probe in catalog.correctnessProbes.probes {
            probes[probe.identifier] = (try catalog.probeURL(for: probe), probe.mimeType)
        }
        let accountA = Self.solidPNG(red: 0.92, green: 0.12, blue: 0.10)
        let accountB = Self.solidPNG(red: 0.10, green: 0.22, blue: 0.92)
        let neutral = Self.solidPNG(red: 0.18, green: 0.72, blue: 0.35)
        lock.lock()
        assetFiles = files
        heroFiles = heroes
        probeFiles = probes
        self.profile = profile
        accountAData = accountA
        accountBData = accountB
        neutralData = neutral
        resetLocked()
        lock.unlock()
    }

    func resetMetrics() {
        lock.lock()
        resetLocked()
        lock.unlock()
    }

    private func resetLocked() {
        cancelledRequestIDs.removeAll(keepingCapacity: true)
        offlineRoutes.removeAll(keepingCapacity: true)
        requestCount = 0
        deliveredBytes = 0
        postCancellationBytes = 0
        completedRequestCount = 0
        stoppedRequestCount = 0
        redirectAuthorizationLeakCount = 0
        peakConcurrentRequestCount = 0
        w7ActiveServiceIDs.removeAll(keepingCapacity: true)
        w7QueuedServiceIDs.removeAll(keepingCapacity: true)
        w7ServiceLabels.removeAll(keepingCapacity: true)
        w7ServiceStartOrder.removeAll(keepingCapacity: true)
        w7ServiceOperations.removeAll(keepingCapacity: true)
        routeRequestCounts.removeAll(keepingCapacity: true)
    }

    func markCancellation(requestID: String) {
        lock.lock()
        cancelledRequestIDs.insert(requestID)
        lock.unlock()
    }

    func setOffline(_ route: String, value: Bool) {
        lock.lock()
        if value { offlineRoutes.insert(route) } else { offlineRoutes.remove(route) }
        lock.unlock()
    }

    func begin(route: String) {
        lock.lock()
        requestCount += 1
        routeRequestCounts[route, default: 0] += 1
        lock.unlock()
    }

    func record(bytes: Int, requestID: String?) {
        lock.lock()
        deliveredBytes += bytes
        if let requestID, cancelledRequestIDs.contains(requestID) {
            postCancellationBytes += bytes
        }
        lock.unlock()
    }

    func complete() {
        lock.lock()
        completedRequestCount += 1
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stoppedRequestCount += 1
        lock.unlock()
    }

    func recordRedirectAuthorizationLeak() {
        lock.lock()
        redirectAuthorizationLeakCount += 1
        lock.unlock()
    }

    func reserveW7Service(
        label: String,
        operation: @escaping @Sendable (UUID) -> Void
    ) -> OriginServiceReservation {
        let identifier = UUID()
        lock.lock()
        w7ServiceOperations[identifier] = operation
        w7ServiceLabels[identifier] = label
        let startsImmediately: Bool
        if w7ActiveServiceIDs.count < Self.w7ConcurrentServiceLimit {
            w7ActiveServiceIDs.insert(identifier)
            peakConcurrentRequestCount = max(
                peakConcurrentRequestCount,
                w7ActiveServiceIDs.count
            )
            w7ServiceStartOrder.append(label)
            startsImmediately = true
        } else {
            w7QueuedServiceIDs.append(identifier)
            startsImmediately = false
        }
        lock.unlock()
        return OriginServiceReservation(
            identifier: identifier,
            startsImmediately: startsImmediately
        )
    }

    func startReservedW7Service(_ identifier: UUID) {
        let operation: (@Sendable (UUID) -> Void)?
        lock.lock()
        if w7ActiveServiceIDs.contains(identifier) {
            operation = w7ServiceOperations.removeValue(forKey: identifier)
        } else {
            operation = nil
        }
        lock.unlock()
        if let operation {
            w7ServiceQueue.async { operation(identifier) }
        }
    }

    func releaseW7Service(_ identifier: UUID) {
        let next: (UUID, @Sendable (UUID) -> Void)?
        lock.lock()
        if w7ActiveServiceIDs.remove(identifier) != nil {
            w7ServiceOperations.removeValue(forKey: identifier)
            w7ServiceLabels.removeValue(forKey: identifier)
            next = promoteNextW7ServiceLocked()
        } else if let index = w7QueuedServiceIDs.firstIndex(of: identifier) {
            w7QueuedServiceIDs.remove(at: index)
            w7ServiceOperations.removeValue(forKey: identifier)
            w7ServiceLabels.removeValue(forKey: identifier)
            next = nil
        } else {
            next = nil
        }
        lock.unlock()
        if let next {
            w7ServiceQueue.async { next.1(next.0) }
        }
    }

    private func promoteNextW7ServiceLocked() -> (UUID, @Sendable (UUID) -> Void)? {
        while !w7QueuedServiceIDs.isEmpty {
            let identifier = w7QueuedServiceIDs.removeFirst()
            guard let operation = w7ServiceOperations.removeValue(forKey: identifier),
                let label = w7ServiceLabels[identifier]
            else {
                w7ServiceLabels.removeValue(forKey: identifier)
                continue
            }
            w7ActiveServiceIDs.insert(identifier)
            peakConcurrentRequestCount = max(
                peakConcurrentRequestCount,
                w7ActiveServiceIDs.count
            )
            w7ServiceStartOrder.append(label)
            return (identifier, operation)
        }
        return nil
    }

    func snapshot() -> BenchmarkOriginMetrics {
        lock.lock()
        let value = BenchmarkOriginMetrics(
            requestCount: requestCount,
            deliveredBytes: deliveredBytes,
            postCancellationBytes: postCancellationBytes,
            completedRequestCount: completedRequestCount,
            stoppedRequestCount: stoppedRequestCount,
            redirectAuthorizationLeakCount: redirectAuthorizationLeakCount,
            peakConcurrentRequestCount: peakConcurrentRequestCount,
            w7ServiceStartOrder: w7ServiceStartOrder,
            routeRequestCounts: routeRequestCounts
        )
        lock.unlock()
        return value
    }

    func timing() -> (initialDelay: UInt64, bytesPerSecond: Int) {
        lock.lock()
        let value = (profile.initialDelayNanoseconds, profile.bytesPerSecond)
        lock.unlock()
        return value
    }

    func resource(for request: URLRequest) throws -> OriginResource? {
        guard let url = request.url else { return nil }
        let route = url.path
        lock.lock()
        let isOffline = offlineRoutes.contains(route)
        let files = assetFiles
        let heroes = heroFiles
        let probes = probeFiles
        let a = accountAData
        let b = accountBData
        let neutral = neutralData
        lock.unlock()
        if isOffline {
            return OriginResource(
                data: Data("offline".utf8),
                mimeType: "text/plain",
                statusCode: 503,
                headers: ["Cache-Control": "no-store"],
                delayNanoseconds: 1_000_000
            )
        }
        if route.hasPrefix("/asset/") {
            let assetID = String(route.dropFirst("/asset/".count)).removingPercentEncoding ?? ""
            guard let (file, mime) = files[assetID] else { return nil }
            return OriginResource(
                data: try Data(contentsOf: file, options: [.mappedIfSafe]),
                mimeType: mime,
                statusCode: 200,
                headers: ["Cache-Control": "public, max-age=3600", "ETag": "\"fixture-v1\""],
                delayNanoseconds: 0
            )
        }
        if route.hasPrefix("/hero/") {
            let name = String(route.dropFirst("/hero/".count)).removingPercentEncoding ?? ""
            guard let file = heroes[name] else { return nil }
            return OriginResource(
                data: try Data(contentsOf: file, options: [.mappedIfSafe]),
                mimeType: "image/jpeg",
                statusCode: 200,
                headers: ["Cache-Control": "public, max-age=3600", "ETag": "\"hero-v1\""],
                delayNanoseconds: 0
            )
        }
        if route.hasPrefix("/probe/") {
            let identifier =
                String(route.dropFirst("/probe/".count)).removingPercentEncoding ?? ""
            guard let (file, mimeType) = probes[identifier] else { return nil }
            return OriginResource(
                data: try Data(contentsOf: file, options: [.mappedIfSafe]),
                mimeType: mimeType,
                statusCode: 200,
                headers: ["Cache-Control": "no-store"],
                delayNanoseconds: 0
            )
        }
        if route == "/w7/blocker" {
            return OriginResource(
                data: neutral,
                mimeType: "image/png",
                statusCode: 200,
                headers: ["Cache-Control": "no-store"],
                delayNanoseconds: 1_500_000_000
            )
        }
        if route == "/w7/shared" {
            return OriginResource(
                data: neutral,
                mimeType: "image/png",
                statusCode: 200,
                headers: ["Cache-Control": "no-store"],
                delayNanoseconds: 750_000_000
            )
        }
        if route == "/w7/unique" {
            return OriginResource(
                data: neutral,
                mimeType: "image/png",
                statusCode: 200,
                headers: ["Cache-Control": "no-store"],
                delayNanoseconds: 50_000_000
            )
        }
        if route == "/w3/auth" {
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let data = authorization.contains("account-a") ? a : b
            return OriginResource(
                data: data,
                mimeType: "image/png",
                statusCode: 200,
                headers: ["Cache-Control": "private, max-age=3600"],
                delayNanoseconds: 0
            )
        }
        if route == "/w3/no-store" {
            return OriginResource(
                data: neutral,
                mimeType: "image/png",
                statusCode: 200,
                headers: ["Cache-Control": "no-store"],
                delayNanoseconds: 0
            )
        }
        if route == "/w3/delayed" {
            return OriginResource(
                data: a,
                mimeType: "image/png",
                statusCode: 200,
                headers: ["Cache-Control": "private, max-age=3600"],
                delayNanoseconds: 500_000_000
            )
        }
        if route == "/w3/redirect-target" {
            if request.value(forHTTPHeaderField: "Authorization") != nil {
                recordRedirectAuthorizationLeak()
            }
            return OriginResource(
                data: neutral,
                mimeType: "image/png",
                statusCode: 200,
                headers: ["Cache-Control": "no-store"],
                delayNanoseconds: 0
            )
        }
        return nil
    }

    private static func solidPNG(red: CGFloat, green: CGFloat, blue: CGFloat) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32))
        return renderer.pngData { context in
            UIColor(red: red, green: green, blue: blue, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
    }
}

final class DeterministicBenchmarkURLProtocol: URLProtocol, @unchecked Sendable {
    private let state = BenchmarkOriginState.shared
    private let deliveryQueue = DispatchQueue(label: "dev.fovea.comparative.origin.delivery")
    private var stopped = false
    private var w7ServiceIdentifier: UUID?
    private let stopLock = NSLock()

    static func configure(catalog: ResourceCatalog, profile: BenchmarkNetworkProfile) throws {
        try BenchmarkOriginState.shared.configure(catalog: catalog, profile: profile)
    }

    static func resetMetrics() { BenchmarkOriginState.shared.resetMetrics() }
    static func markCancellation(requestID: String) {
        BenchmarkOriginState.shared.markCancellation(requestID: requestID)
    }
    static func setOffline(route: String, value: Bool) {
        BenchmarkOriginState.shared.setOffline(route, value: value)
    }
    static func metrics() -> BenchmarkOriginMetrics { BenchmarkOriginState.shared.snapshot() }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host?.lowercased() else { return false }
        return host == "benchmark.invalid" || host == "other.benchmark.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let route = url.path
        state.begin(route: route)
        if route.hasPrefix("/w7/") {
            let label = Self.w7ServiceLabel(for: url, route: route)
            let reservation = state.reserveW7Service(label: label) {
                [weak self, state] identifier in
                guard let self else {
                    state.releaseW7Service(identifier)
                    return
                }
                self.deliver(url: url, route: route, w7ServiceIdentifier: identifier)
            }
            stopLock.lock()
            w7ServiceIdentifier = reservation.identifier
            let alreadyStopped = stopped
            stopLock.unlock()
            if alreadyStopped {
                state.releaseW7Service(reservation.identifier)
            } else if reservation.startsImmediately {
                state.startReservedW7Service(reservation.identifier)
            }
            return
        }
        deliver(url: url, route: route, w7ServiceIdentifier: nil)
    }

    private static func w7ServiceLabel(for url: URL, route: String) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let label = components.queryItems?.first(where: { $0.name == "label" })?.value,
            !label.isEmpty,
            label.count <= 96
        else {
            return route
        }
        return label
    }

    private func deliver(url: URL, route: String, w7ServiceIdentifier: UUID?) {
        if isStopped {
            if let w7ServiceIdentifier { state.releaseW7Service(w7ServiceIdentifier) }
            return
        }
        if route == "/w3/redirect" {
            guard
                let redirectedURL = URL(
                    string: "https://other.benchmark.invalid/w3/redirect-target"),
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 302,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Location": redirectedURL.absoluteString, "Cache-Control": "no-store",
                    ]
                )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                finishW7Service(w7ServiceIdentifier)
                return
            }
            var redirected = URLRequest(url: redirectedURL)
            redirected.httpMethod = request.httpMethod
            redirected.allHTTPHeaderFields = request.allHTTPHeaderFields
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            state.complete()
            finishW7Service(w7ServiceIdentifier)
            return
        }
        do {
            guard let resource = try state.resource(for: request),
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: resource.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: resource.headers.merging([
                        "Content-Type": resource.mimeType,
                        "Content-Length": String(resource.data.count),
                    ]) { current, _ in current }
                )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                finishW7Service(w7ServiceIdentifier)
                return
            }
            let timing = state.timing()
            let initialDelay = timing.initialDelay + resource.delayNanoseconds
            let requestID = request.value(forHTTPHeaderField: "X-Benchmark-Request-ID")
            let chunkSize = 32 * 1024
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for offset in stride(from: 0, to: resource.data.count, by: chunkSize) {
                let end = min(resource.data.count, offset + chunkSize)
                let chunk = resource.data.subdata(in: offset..<end)
                let transferDelay = UInt64(
                    (Double(end) / Double(max(1, timing.bytesPerSecond))) * 1_000_000_000
                )
                deliveryQueue.asyncAfter(
                    deadline: .now()
                        + .nanoseconds(Int(min(UInt64(Int.max), initialDelay + transferDelay)))
                ) { [weak self] in
                    guard let self, !self.isStopped else { return }
                    self.state.record(bytes: chunk.count, requestID: requestID)
                    self.client?.urlProtocol(self, didLoad: chunk)
                    if end == resource.data.count {
                        self.client?.urlProtocolDidFinishLoading(self)
                        self.state.complete()
                        self.finishW7Service(w7ServiceIdentifier)
                    }
                }
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            finishW7Service(w7ServiceIdentifier)
        }
    }

    private func finishW7Service(_ identifier: UUID?) {
        guard let identifier else { return }
        state.releaseW7Service(identifier)
    }

    override func stopLoading() {
        stopLock.lock()
        let wasStopped = stopped
        stopped = true
        let serviceIdentifier = w7ServiceIdentifier
        w7ServiceIdentifier = nil
        stopLock.unlock()
        if !wasStopped {
            state.stop()
            if let serviceIdentifier { state.releaseW7Service(serviceIdentifier) }
        }
    }

    private var isStopped: Bool {
        stopLock.lock()
        let value = stopped
        stopLock.unlock()
        return value
    }
}
