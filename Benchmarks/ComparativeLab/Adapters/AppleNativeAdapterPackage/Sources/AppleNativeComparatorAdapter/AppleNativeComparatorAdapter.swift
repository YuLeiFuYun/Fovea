import ComparativeLabCore
import CoreGraphics
import Foundation
import ImageIO

private struct NativeFetchKey: Hashable, Sendable {
    let namespace: String
    let url: URL
    let semanticHeaders: [(String, String)]

    init(request: ComparatorRequest) {
        namespace = request.securityNamespace
        url = request.url
        semanticHeaders = request.headers
            .filter { $0.key != "x-benchmark-request-id" }
            .sorted { lhs, rhs in
                lhs.key == rhs.key ? lhs.value < rhs.value : lhs.key < rhs.key
            }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.namespace == rhs.namespace
            && lhs.url == rhs.url
            && lhs.semanticHeaders.elementsEqual(rhs.semanticHeaders, by: ==)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(namespace)
        hasher.combine(url)
        for header in semanticHeaders {
            hasher.combine(header.0)
            hasher.combine(header.1)
        }
    }
}

private struct NativeFetchPayload: @unchecked Sendable {
    let data: Data
    let response: HTTPURLResponse
    let source: ComparatorCacheSource
    let reusable: Bool
}

private final class NativeDataTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancellationRequested = false

    func install(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func taskIdentifier() -> Int? {
        lock.lock()
        let identifier = task?.taskIdentifier
        lock.unlock()
        return identifier
    }
}

private final class NativeTaskMetricsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int: URLSessionTaskMetrics] = [:]
    private var completed: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<URLSessionTaskMetrics?, Never>] = [:]

    func record(_ metrics: URLSessionTaskMetrics, taskIdentifier: Int) {
        lock.lock()
        if let waiter = waiters.removeValue(forKey: taskIdentifier) {
            lock.unlock()
            waiter.resume(returning: metrics)
            return
        }
        recorded[taskIdentifier] = metrics
        lock.unlock()
    }

    func markCompleted(taskIdentifier: Int) {
        lock.lock()
        guard recorded[taskIdentifier] == nil else {
            lock.unlock()
            return
        }
        if let waiter = waiters.removeValue(forKey: taskIdentifier) {
            lock.unlock()
            waiter.resume(returning: nil)
            return
        }
        completed.insert(taskIdentifier)
        lock.unlock()
    }

    func metrics(for taskIdentifier: Int) async -> URLSessionTaskMetrics? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let metrics = recorded.removeValue(forKey: taskIdentifier) {
                completed.remove(taskIdentifier)
                lock.unlock()
                continuation.resume(returning: metrics)
                return
            }
            if completed.remove(taskIdentifier) != nil {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            waiters[taskIdentifier] = continuation
            lock.unlock()
        }
    }
}

private actor NativeResultRelay<Value: Sendable> {
    private enum State {
        case empty
        case waiting(CheckedContinuation<Value, any Error>)
        case resolved(Result<Value, any Error>)
        case finished
    }

    private var state: State = .empty

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        switch state {
        case .empty:
            state = .waiting(continuation)
        case .resolved(let result):
            state = .finished
            continuation.resume(with: result)
        case .waiting, .finished:
            continuation.resume(throwing: CancellationError())
        }
    }

    func resolve(_ result: Result<Value, any Error>) {
        switch state {
        case .empty:
            state = .resolved(result)
        case .waiting(let continuation):
            state = .finished
            continuation.resume(with: result)
        case .resolved, .finished:
            break
        }
    }
}

private actor NativeFetchCoordinator {
    private struct Entry {
        let id: UUID
        let task: Task<NativeFetchPayload, Error>
        var subscribers: Set<UUID>
    }

    struct Subscription: Sendable {
        let key: NativeFetchKey
        let entryID: UUID
        let subscriberID: UUID
        let task: Task<NativeFetchPayload, Error>
        let coordinator: NativeFetchCoordinator
        let joined: Bool

        func value() async throws -> NativeFetchPayload {
            let relay = NativeResultRelay<NativeFetchPayload>()
            let waiter = Task { await relay.resolve(task.result) }
            defer { waiter.cancel() }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    Task { await relay.install(continuation) }
                }
            } onCancel: {
                Task { await relay.resolve(.failure(CancellationError())) }
            }
        }

        func release() async {
            await coordinator.release(
                key: key,
                entryID: entryID,
                subscriberID: subscriberID
            )
        }
    }

    private var entries: [NativeFetchKey: Entry] = [:]

    func subscribe(
        key: NativeFetchKey,
        operation: @escaping @Sendable () async throws -> NativeFetchPayload
    ) -> Subscription {
        let subscriberID = UUID()
        if var entry = entries[key] {
            entry.subscribers.insert(subscriberID)
            entries[key] = entry
            return Subscription(
                key: key,
                entryID: entry.id,
                subscriberID: subscriberID,
                task: entry.task,
                coordinator: self,
                joined: true
            )
        }
        let entryID = UUID()
        let task = Task { try await operation() }
        entries[key] = Entry(
            id: entryID,
            task: task,
            subscribers: [subscriberID]
        )
        Task { [weak self] in
            _ = await task.result
            await self?.completed(key: key, entryID: entryID)
        }
        return Subscription(
            key: key,
            entryID: entryID,
            subscriberID: subscriberID,
            task: task,
            coordinator: self,
            joined: false
        )
    }

    func release(key: NativeFetchKey, entryID: UUID, subscriberID: UUID) {
        guard var entry = entries[key], entry.id == entryID else { return }
        guard entry.subscribers.remove(subscriberID) != nil else { return }
        if entry.subscribers.isEmpty {
            entry.task.cancel()
            entries.removeValue(forKey: key)
        } else {
            entries[key] = entry
        }
    }

    func cancelAll() {
        for entry in entries.values { entry.task.cancel() }
        entries.removeAll(keepingCapacity: false)
    }

    private func completed(key: NativeFetchKey, entryID: UUID) {
        guard let entry = entries[key], entry.id == entryID else { return }
        entries.removeValue(forKey: key)
    }
}

private final class NativeSessionDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    let metricsStore = NativeTaskMetricsStore()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        metricsStore.record(metrics, taskIdentifier: task.taskIdentifier)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        metricsStore.markCompleted(taskIdentifier: task.taskIdentifier)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard Self.origin(of: task.currentRequest?.url) != Self.origin(of: request.url) else {
            completionHandler(request)
            return
        }
        var sanitized = request
        sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        sanitized.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(sanitized)
    }

    private static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(),
            let host = url.host?.lowercased()
        else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        return "\(scheme)://\(host):\(port)"
    }
}

private final class NativeImageBox: NSObject, @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

public final class AppleNativeComparatorAdapter: ComparatorAdapter, @unchecked Sendable {
    public let identity: ComparatorIdentity

    private let session: URLSession
    private let sessionDelegate: NativeSessionDelegate
    private let urlCache: URLCache
    private let imageCache = NSCache<NSString, NativeImageBox>()
    private let coordinator = NativeFetchCoordinator()

    public init(
        identity: ComparatorIdentity,
        cacheDirectory: URL,
        memoryCostLimit: Int = 128 * 1_024 * 1_024,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) throws {
        guard identity.sourceKind == .platformBuild else {
            throw ComparativeLabError.invalidIdentifier
        }
        self.identity = identity
        let cacheDirectory = cacheDirectory.appendingPathComponent(
            "AppleNativeURLCache",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let urlCache = URLCache(
            memoryCapacity: 0,
            diskCapacity: 256 * 1_024 * 1_024,
            directory: cacheDirectory
        )
        self.urlCache = urlCache
        imageCache.totalCostLimit = max(1, memoryCostLimit)
        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        configuration.urlCache = urlCache
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        let sessionDelegate = NativeSessionDelegate()
        self.sessionDelegate = sessionDelegate
        session = URLSession(
            configuration: configuration,
            delegate: sessionDelegate,
            delegateQueue: nil
        )
    }

    public func makeLoad(_ request: ComparatorRequest) async throws -> ComparatorLoad {
        let started = DispatchTime.now().uptimeNanoseconds
        let decodedKey = decodedCacheKey(request)
        if let cached = imageCache.object(forKey: decodedKey as NSString) {
            let measurement = try ComparatorLoadResult(
                outcome: .completed,
                cacheSource: .memory,
                latencyNanoseconds: DispatchTime.now().uptimeNanoseconds &- started,
                pixelWidth: cached.image.width,
                pixelHeight: cached.image.height
            )
            return ComparatorLoad(
                cancel: {},
                result: {
                    ComparatorLoadOutput(
                        measurement: measurement,
                        image: ComparatorRenderImage(cgImage: cached.image)
                    )
                }
            )
        }

        let urlRequest = makeURLRequest(request)
        let fetchKey = NativeFetchKey(request: request)
        let priority = Self.taskPriority(request.priority)
        let metricsStore = sessionDelegate.metricsStore
        let subscription = await coordinator.subscribe(key: fetchKey) { [session, metricsStore] in
            try await Self.fetch(
                request: urlRequest,
                priority: priority,
                session: session,
                metricsStore: metricsStore
            )
        }
        let resultTask = Task<ComparatorLoadOutput, Never> { [imageCache] in
            do {
                let payload = try await subscription.value()
                await subscription.release()
                try Task.checkCancellation()
                let image = try Self.decode(
                    payload.data,
                    target: request.target,
                    contentMode: request.contentMode
                )
                if payload.reusable {
                    imageCache.setObject(
                        NativeImageBox(image),
                        forKey: decodedKey as NSString,
                        cost: Self.imageCost(image)
                    )
                }
                let measurement = try ComparatorLoadResult(
                    outcome: .completed,
                    cacheSource: payload.source,
                    latencyNanoseconds: DispatchTime.now().uptimeNanoseconds &- started,
                    pixelWidth: image.width,
                    pixelHeight: image.height,
                    receivedBytes: payload.data.count
                )
                return ComparatorLoadOutput(
                    measurement: measurement,
                    image: ComparatorRenderImage(cgImage: image)
                )
            } catch is CancellationError {
                await subscription.release()
                return Self.failureOutput(
                    outcome: .cancelled,
                    started: started,
                    category: nil
                )
            } catch let error as URLError where error.code == .cancelled {
                await subscription.release()
                return Self.failureOutput(
                    outcome: .cancelled,
                    started: started,
                    category: nil
                )
            } catch {
                await subscription.release()
                return Self.failureOutput(
                    outcome: .failed,
                    started: started,
                    category: error is NativeDecodeError ? "decode" : "transport"
                )
            }
        }
        return ComparatorLoad(
            cancel: {
                resultTask.cancel()
                Task { await subscription.release() }
            },
            result: { await resultTask.value }
        )
    }

    public func purgeMemory() async {
        imageCache.removeAllObjects()
    }

    public func purgeDisk() async throws {
        imageCache.removeAllObjects()
        urlCache.removeAllCachedResponses()
    }

    public func revoke(namespace: String) async throws {
        await coordinator.cancelAll()
        imageCache.removeAllObjects()
        urlCache.removeAllCachedResponses()
    }

    public func cancelAll() async {
        await coordinator.cancelAll()
        session.invalidateAndCancel()
    }

    private func decodedCacheKey(_ request: ComparatorRequest) -> String {
        "\(request.scopedCacheKey)|\(request.url.absoluteString)|\(request.target.width)x\(request.target.height)|\(request.contentMode.rawValue)"
    }

    private func makeURLRequest(_ request: ComparatorRequest) -> URLRequest {
        var value = URLRequest(url: request.url)
        value.cachePolicy = .useProtocolCachePolicy
        for (name, headerValue) in request.headers {
            value.setValue(headerValue, forHTTPHeaderField: name)
        }
        return value
    }

    private static func fetch(
        request: URLRequest,
        priority: Float,
        session: URLSession,
        metricsStore: NativeTaskMetricsStore
    ) async throws -> NativeFetchPayload {
        let box = NativeDataTaskBox()
        let tuple: (Data, URLResponse, Int) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let data, let response, let taskIdentifier = box.taskIdentifier() else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    continuation.resume(returning: (data, response, taskIdentifier))
                }
                task.priority = priority
                box.install(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
        guard let response = tuple.1 as? HTTPURLResponse,
            (200...299).contains(response.statusCode)
        else {
            throw URLError(.badServerResponse)
        }
        let metrics = await metricsStore.metrics(for: tuple.2)
        return NativeFetchPayload(
            data: tuple.0,
            response: response,
            source: cacheSource(from: metrics),
            reusable: reusableResponse(response, request: request)
        )
    }

    private static func cacheSource(
        from metrics: URLSessionTaskMetrics?
    ) -> ComparatorCacheSource {
        guard let fetchType = metrics?.transactionMetrics.last?.resourceFetchType else {
            return .unknown
        }
        switch fetchType {
        case .networkLoad, .serverPush:
            return .network
        case .localCache:
            return .disk
        case .unknown:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    private static func reusableResponse(
        _ response: HTTPURLResponse,
        request: URLRequest
    ) -> Bool {
        if request.value(forHTTPHeaderField: "Authorization") != nil { return false }
        let cacheControl = response.value(forHTTPHeaderField: "Cache-Control")?.lowercased() ?? ""
        if cacheControl.contains("no-store")
            || cacheControl.contains("no-cache")
            || cacheControl.contains("must-revalidate")
        {
            return false
        }
        return response.value(forHTTPHeaderField: "Vary") != "*"
    }

    private static func taskPriority(_ priority: ComparatorPriority) -> Float {
        switch priority {
        case .background: URLSessionTask.lowPriority
        case .utility: 0.35
        case .visible: 0.75
        case .immediate: URLSessionTask.highPriority
        }
    }

    private static func decode(
        _ data: Data,
        target: ComparatorPixelTarget,
        contentMode: ComparatorContentMode
    ) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
            let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
            rawWidth > 0, rawHeight > 0
        else {
            throw NativeDecodeError.invalidImage
        }
        let orientation =
            (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsAxes = (5...8).contains(orientation)
        let orientedWidth = swapsAxes ? rawHeight : rawWidth
        let orientedHeight = swapsAxes ? rawWidth : rawHeight
        let targetWidth = Double(target.width)
        let targetHeight = Double(target.height)
        let scale: Double
        switch contentMode {
        case .aspectFit:
            scale = min(targetWidth / orientedWidth, targetHeight / orientedHeight)
        case .aspectFill:
            scale = max(targetWidth / orientedWidth, targetHeight / orientedHeight)
        }
        let boundedScale = min(scale, 1)
        let maximumPixel = max(
            1,
            Int(ceil(max(orientedWidth * boundedScale, orientedHeight * boundedScale)))
        )
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            )
        else {
            throw NativeDecodeError.invalidImage
        }
        switch contentMode {
        case .aspectFit:
            return try renderAspectFitIfNeeded(thumbnail, target: target)
        case .aspectFill:
            return try renderAspectFill(thumbnail, target: target)
        }
    }

    private static func renderAspectFitIfNeeded(
        _ image: CGImage,
        target: ComparatorPixelTarget
    ) throws -> CGImage {
        guard image.width > target.width || image.height > target.height else {
            return image
        }
        let scale = min(
            CGFloat(target.width) / CGFloat(image.width),
            CGFloat(target.height) / CGFloat(image.height)
        )
        let width = max(1, min(target.width, Int(floor(CGFloat(image.width) * scale))))
        let height = max(1, min(target.height, Int(floor(CGFloat(image.height) * scale))))
        return try render(image, width: width, height: height) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private static func render(
        _ image: CGImage,
        width: Int,
        height: Int,
        draw: (CGContext) -> Void
    ) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw NativeDecodeError.renderFailed
        }
        context.interpolationQuality = .high
        draw(context)
        guard let rendered = context.makeImage() else {
            throw NativeDecodeError.renderFailed
        }
        return rendered
    }

    private static func renderAspectFill(
        _ image: CGImage,
        target: ComparatorPixelTarget
    ) throws -> CGImage {
        let scale = max(
            CGFloat(target.width) / CGFloat(image.width),
            CGFloat(target.height) / CGFloat(image.height)
        )
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        let rect = CGRect(
            x: (CGFloat(target.width) - width) / 2,
            y: (CGFloat(target.height) - height) / 2,
            width: width,
            height: height
        )
        return try render(image, width: target.width, height: target.height) { context in
            context.draw(image, in: rect)
        }
    }

    private static func imageCost(_ image: CGImage) -> Int {
        let (pixels, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        guard !overflow else { return Int.max }
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return byteOverflow ? Int.max : bytes
    }

    private static func failureOutput(
        outcome: ComparatorOutcome,
        started: UInt64,
        category: String?
    ) -> ComparatorLoadOutput {
        let measurement = try! ComparatorLoadResult(
            outcome: outcome,
            cacheSource: .unknown,
            latencyNanoseconds: DispatchTime.now().uptimeNanoseconds &- started,
            failureCategory: category
        )
        return ComparatorLoadOutput(measurement: measurement, image: nil)
    }
}

private enum NativeDecodeError: Error {
    case invalidImage
    case renderFailed
}
