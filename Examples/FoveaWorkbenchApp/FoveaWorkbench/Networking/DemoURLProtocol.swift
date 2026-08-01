import Foundation

/// Foundation 的 URLProtocol 回调对象会跨入并发任务；任务句柄与停止状态由 `lock` 保护。
final class DemoURLProtocol: URLProtocol {
    static let host = "fovea-demo.test"

    private let lock = NSLock()
    private var loadingOperationID: UUID?
    private var loadingOperation: Task<Void, Never>?
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.lowercased() == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let identifier = UUID()
        let shouldStart = lock.withLock { () -> Bool in
            guard !stopped, loadingOperationID == nil else { return false }
            loadingOperationID = identifier
            return true
        }
        guard shouldStart else { return }

        let bridge = DemoURLProtocolBridge(value: self)
        let operation = Task {
            defer { bridge.value.clearLoadingOperation(identifier: identifier) }
            await bridge.value.serve()
        }
        let shouldCancel = lock.withLock { () -> Bool in
            guard loadingOperationID == identifier, !stopped else { return true }
            loadingOperation = operation
            return false
        }
        if shouldCancel { operation.cancel() }
    }

    private func clearLoadingOperation(identifier: UUID) {
        lock.withLock {
            guard loadingOperationID == identifier else { return }
            loadingOperationID = nil
            loadingOperation = nil
        }
    }

    override func stopLoading() {
        let operation = lock.withLock { () -> Task<Void, Never>? in
            stopped = true
            let current = loadingOperation
            loadingOperationID = nil
            loadingOperation = nil
            return current
        }
        operation?.cancel()
    }

    private func serve() async {
        guard let url = request.url else {
            fail(URLError(.badURL))
            return
        }
        await DemoOriginMetrics.shared.record(url: url)

        do {
            switch url.path {
            case "/image/cacheable":
                try await imageResponse(
                    data: fixture(.mistyMountains),
                    cacheControl: "public, max-age=3600",
                    etag: "\"cacheable-v1\""
                )
            case "/image/no-store":
                try await imageResponse(
                    data: fixture(.flamingStarNebula),
                    cacheControl: "no-store"
                )
            case "/image/revalidate":
                let etag = "\"revalidate-v1\""
                if request.value(forHTTPHeaderField: "If-None-Match") == etag {
                    try await send(
                        status: 304, headers: ["ETag": etag, "Cache-Control": "max-age=0"])
                } else {
                    try await imageResponse(
                        data: fixture(.mistyMountains),
                        cacheControl: "max-age=0, must-revalidate",
                        etag: etag
                    )
                }
            case "/image/vary":
                let language = request.value(forHTTPHeaderField: "Accept-Language") ?? "en"
                let chinese = language.lowercased().hasPrefix("zh")
                try await imageResponse(
                    data: fixture(chinese ? .flamingStarNebula : .mistyMountains),
                    cacheControl: "public, max-age=600",
                    etag: chinese ? "\"vary-zh-v1\"" : "\"vary-en-v1\"",
                    additionalHeaders: ["Vary": "Accept-Language"]
                )
            case "/image/vary-star":
                try await imageResponse(
                    data: fixture(.flamingStarNebula),
                    cacheControl: "public, max-age=600",
                    additionalHeaders: ["Vary": "*"]
                )
            case "/image/authenticated":
                let authorization = request.value(forHTTPHeaderField: "Authorization")
                let fixtureName: WorkbenchDeterministicFixture
                switch authorization {
                case "Bearer workbench-token-a":
                    fixtureName = .flamingStarNebula
                case "Bearer workbench-token-b":
                    fixtureName = .mistyMountains
                default:
                    try await send(status: 401, headers: ["Cache-Control": "no-store"])
                    return
                }
                try await imageResponse(
                    data: fixture(fixtureName),
                    cacheControl: "private, max-age=120",
                    additionalHeaders: ["Vary": "Authorization"]
                )
            case "/image/slow":
                let delay = milliseconds(
                    named: "delay", defaultValue: 900, maximum: 10_000, url: url)
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                try await imageResponse(
                    data: fixture(.mistyMountains),
                    cacheControl: "no-store"
                )
            case "/image/chunked":
                let chunks = integer(named: "chunks", defaultValue: 8, range: 2...64, url: url)
                let interval = milliseconds(
                    named: "interval", defaultValue: 80, maximum: 1_000, url: url)
                try await chunkedImageResponse(
                    data: fixture(.flamingStarNebula),
                    chunks: chunks,
                    intervalMilliseconds: interval
                )
            case "/image/missing-content-type":
                try await send(
                    status: 200,
                    headers: ["Cache-Control": "no-store"],
                    body: fixture(.mistyMountains)
                )
            case "/redirect/image":
                try redirect(
                    to: url.deletingLastPathComponent().appendingPathComponent("final-image"))
            case "/redirect/final-image":
                try await imageResponse(
                    data: fixture(.mistyMountains),
                    cacheControl: "public, max-age=120"
                )
            case "/failure/wrong-mime":
                try await send(
                    status: 200,
                    headers: ["Content-Type": "text/html", "Cache-Control": "no-store"],
                    body: Data("<html>not an image</html>".utf8)
                )
            case "/failure/corrupt-image":
                try await send(
                    status: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                    body: Data("not-a-valid-png".utf8)
                )
            case "/failure/empty-image":
                try await send(
                    status: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "no-store"]
                )
            case "/failure/oversized":
                let bytes = integer(
                    named: "bytes",
                    defaultValue: 9 * 1024 * 1024,
                    range: 1...(40 * 1024 * 1024),
                    url: url
                )
                try await send(
                    status: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                    body: Data(repeating: 0xA5, count: bytes)
                )
            case "/failure/incomplete":
                let body = try fixture(.mistyMountains).prefix(1024)
                try await send(
                    status: 200,
                    headers: [
                        "Content-Type": "image/png",
                        "Content-Length": String(body.count + 4096),
                        "Cache-Control": "no-store",
                    ],
                    body: Data(body),
                    insertContentLength: false
                )
            default:
                if url.path.hasPrefix("/feed/asset-") {
                    let delay = milliseconds(
                        named: "delay", defaultValue: 0, maximum: 2_000, url: url)
                    if delay > 0 {
                        try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                    }
                    let assetID =
                        Int(url.lastPathComponent.replacingOccurrences(of: "asset-", with: "")) ?? 0
                    try await imageResponse(
                        data: fixture(
                            assetID.isMultiple(of: 2)
                                ? .mistyMountains : .flamingStarNebula),
                        cacheControl: "public, max-age=600",
                        etag: "\"feed-asset-\(assetID)-v1\""
                    )
                } else if url.path.hasPrefix("/failure/status/") {
                    let status = Int(url.lastPathComponent) ?? 500
                    try await send(status: status, headers: ["Cache-Control": "no-store"])
                } else {
                    try await send(status: 404, headers: ["Cache-Control": "no-store"])
                }
            }
        } catch is CancellationError {
            return
        } catch {
            fail(error)
        }
    }

    private func redirect(to destination: URL) throws {
        try Task.checkCancellation()
        guard !isStopped, let source = request.url,
            let response = HTTPURLResponse(
                url: source,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Location": destination.absoluteString,
                    "Cache-Control": "no-store",
                ]
            )
        else { return }
        client?.urlProtocol(
            self,
            wasRedirectedTo: URLRequest(url: destination),
            redirectResponse: response
        )
    }

    private func imageResponse(
        data: Data,
        cacheControl: String,
        etag: String? = nil,
        additionalHeaders: [String: String] = [:]
    ) async throws {
        var headers = additionalHeaders
        headers["Content-Type"] = "image/png"
        headers["Cache-Control"] = cacheControl
        headers["ETag"] = etag
        try await send(status: 200, headers: headers, body: data)
    }

    private func chunkedImageResponse(
        data: Data,
        chunks: Int,
        intervalMilliseconds: Int
    ) async throws {
        guard !isStopped, let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png", "Cache-Control": "no-store"]
            )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let stride = max(1, data.count / chunks)
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            guard !isStopped else { return }
            let end = min(data.count, offset + stride)
            client?.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
            offset = end
            if offset < data.count {
                try await Task.sleep(nanoseconds: UInt64(intervalMilliseconds) * 1_000_000)
            }
        }
        guard !isStopped else { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func send(
        status: Int,
        headers: [String: String],
        body: Data = Data(),
        insertContentLength: Bool = true
    ) async throws {
        try Task.checkCancellation()
        guard !isStopped, let url = request.url else { return }
        var fields = headers
        if insertContentLength, fields["Content-Length"] == nil {
            fields["Content-Length"] = String(body.count)
        }
        guard
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: fields
            )
        else {
            throw URLError(.badServerResponse)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        guard !isStopped else { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fixture(_ fixture: WorkbenchDeterministicFixture) throws -> Data {
        guard let url = fixture.bundledURL else {
            throw URLError(.fileDoesNotExist)
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func fail(_ error: Error) {
        guard !isStopped else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func integer(
        named name: String,
        defaultValue: Int,
        range: ClosedRange<Int>,
        url: URL
    ) -> Int {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let raw = components.queryItems?.first(where: { $0.name == name })?.value,
            let value = Int(raw)
        else { return defaultValue }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    private func milliseconds(
        named name: String,
        defaultValue: Int,
        maximum: Int,
        url: URL
    ) -> Int {
        integer(named: name, defaultValue: defaultValue, range: 0...maximum, url: url)
    }
}

actor DemoOriginMetrics {
    static let shared = DemoOriginMetrics()

    private var counts: [String: Int] = [:]
    private var runCounts: [String: Int] = [:]

    func record(url: URL) {
        counts[url.path, default: 0] += 1
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let runIdentifier = components.queryItems?.first(where: { $0.name == "workbench-run" })?
                .value,
            !runIdentifier.isEmpty
        else { return }
        runCounts[runIdentifier, default: 0] += 1
    }

    func snapshot() -> [String: Int] { counts }

    func consumeCount(runIdentifier: String) -> Int {
        runCounts.removeValue(forKey: runIdentifier) ?? 0
    }

    func reset() {
        counts.removeAll(keepingCapacity: false)
        runCounts.removeAll(keepingCapacity: false)
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}

/// iOS 15 的 `URLProtocol` 没有 Sendable 契约。该包装器是唯一经过审计的桥接点；
/// `DemoURLProtocol` 使用私有锁保护全部可变状态。
private struct DemoURLProtocolBridge: @unchecked Sendable {
    let value: DemoURLProtocol
}
