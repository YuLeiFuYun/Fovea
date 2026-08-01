import ComparativeLabCore
import CryptoKit
import Foundation
import PINRemoteImage

#if canImport(UIKit)
    import UIKit
    private typealias PlatformImage = UIImage
#elseif canImport(AppKit)
    import AppKit
    private typealias PlatformImage = NSImage
#endif

private final class PINHeaderRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String: String]] = [:]

    func register(token: String, headers: [String: String]) {
        lock.lock()
        values[token] = headers
        lock.unlock()
    }

    func headers(for url: URL?) -> [String: String] {
        guard let token = url.flatMap(Self.token(from:)) else { return [:] }
        lock.lock()
        defer { lock.unlock() }
        return values[token] ?? [:]
    }

    private static func token(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "__fovea_scope" })?
            .value
    }
}

private final class PINOperationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var uuid: UUID?
    private var cancelled = false
    private var receivedBytes = 0

    func install(_ uuid: UUID?, manager: PINRemoteImageManager) {
        lock.lock()
        self.uuid = uuid
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel, let uuid { manager.cancelTask(with: uuid) }
    }

    func cancel(manager: PINRemoteImageManager) {
        lock.lock()
        cancelled = true
        let uuid = uuid
        lock.unlock()
        if let uuid { manager.cancelTask(with: uuid) }
    }

    func record(receivedBytes: Int64) {
        lock.lock()
        self.receivedBytes = max(self.receivedBytes, Int(clamping: receivedBytes))
        lock.unlock()
    }

    func snapshot() -> (cancelled: Bool, receivedBytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (cancelled, receivedBytes)
    }
}

private final class PINActiveLoadRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellations: [UUID: @Sendable () -> Void] = [:]

    func register(id: UUID, cancellation: @escaping @Sendable () -> Void) {
        lock.lock()
        precondition(cancellations[id] == nil, "duplicate PINRemoteImage active load ID")
        cancellations[id] = cancellation
        lock.unlock()
    }

    func remove(id: UUID) {
        lock.lock()
        cancellations.removeValue(forKey: id)
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let values = Array(cancellations.values)
        cancellations.removeAll(keepingCapacity: true)
        lock.unlock()
        for cancellation in values { cancellation() }
    }
}

private final class PINResultRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ComparatorLoadOutput, Never>?
    private var resolved: ComparatorLoadOutput?
    private var finished = false

    func install(_ continuation: CheckedContinuation<ComparatorLoadOutput, Never>) {
        lock.lock()
        if finished {
            let output = resolved
            resolved = nil
            lock.unlock()
            if let output { continuation.resume(returning: output) }
            return
        }
        if self.continuation != nil {
            lock.unlock()
            preconditionFailure("PINRemoteImage result relay installed twice")
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ output: ComparatorLoadOutput) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil { resolved = output }
        lock.unlock()
        continuation?.resume(returning: output)
    }
}

public final class PINRemoteImageComparatorAdapter: ComparatorAdapter, @unchecked Sendable {
    public let identity: ComparatorIdentity

    private let manager: PINRemoteImageManager
    private let headerRegistry = PINHeaderRegistry()
    private let activeLoads = PINActiveLoadRegistry()

    public init(
        cacheDirectory: URL,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        maximumConcurrentDownloads: Int = 6
    ) throws {
        identity = try ComparatorIdentity(
            name: "PINRemoteImage",
            version: "releases/p14.31",
            exactCommit: "c0d5cfa1947f2456ddb321a85b347b3d60d83254"
        )
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let session = sessionConfiguration.copy() as! URLSessionConfiguration
        session.urlCache = nil
        session.httpCookieStorage = nil
        session.urlCredentialStorage = nil
        session.httpShouldSetCookies = false
        let configuration = PINRemoteImageManagerConfiguration()
        configuration.maxConcurrentDownloads = UInt(max(1, maximumConcurrentDownloads))
        configuration.maxConcurrentOperations = UInt(max(1, maximumConcurrentDownloads))
        let imageCache = PINRemoteImageManager.defaultImageTtlCache()
        manager = PINRemoteImageManager(
            sessionConfiguration: session,
            alternativeRepresentationProvider: nil,
            imageCache: imageCache,
            managerConfiguration: configuration
        )
        let registry = headerRegistry
        manager.setRequestConfiguration { request in
            var configured = request
            for (name, value) in registry.headers(for: request.url) {
                configured.setValue(value, forHTTPHeaderField: name)
            }
            return configured
        }
    }

    public func makeLoad(_ request: ComparatorRequest) async throws -> ComparatorLoad {
        let started = DispatchTime.now().uptimeNanoseconds
        let token = scopeToken(request)
        headerRegistry.register(token: token, headers: request.headers)
        let url = scopedURL(request.url, token: token)
        let processorKey =
            "\(request.scopedCacheKey)|\(request.target.width)x\(request.target.height)|\(request.contentMode.rawValue)"
        let box = PINOperationBox()
        let relay = PINResultRelay()
        let operationID = UUID()
        let cancelledOutput: @Sendable () -> ComparatorLoadOutput = {
            let snapshot = box.snapshot()
            return ComparatorLoadOutput(
                measurement: try! ComparatorLoadResult(
                    outcome: .cancelled,
                    cacheSource: .unknown,
                    latencyNanoseconds: DispatchTime.now().uptimeNanoseconds &- started,
                    receivedBytes: snapshot.receivedBytes
                ),
                image: nil
            )
        }
        let finish: @Sendable (ComparatorLoadOutput) -> Void = { [activeLoads] output in
            activeLoads.remove(id: operationID)
            relay.resolve(output)
        }
        let cancelOperation: @Sendable () -> Void = { [self] in
            box.cancel(manager: self.manager)
            finish(cancelledOutput())
        }
        activeLoads.register(id: operationID, cancellation: cancelOperation)
        let task = Task<ComparatorLoadOutput, Never> { [self] in
            let privateRequest = request.headers["authorization"] != nil
            let options: PINRemoteImageManagerDownloadOptions = [
                .disallowAlternateRepresentations,
                .downloadOptionsSkipDecode,
                .downloadOptionsSkipRetry,
            ]
            let progress: PINRemoteImageManagerProgressDownload = { completed, _ in
                box.record(receivedBytes: completed)
            }
            let completion: PINRemoteImageManagerImageCompletion = { result in
                let snapshot = box.snapshot()
                let latency = DispatchTime.now().uptimeNanoseconds &- started
                let outputImage: PlatformImage?
                if privateRequest, let image = result.image {
                    outputImage = Self.resize(
                        image,
                        target: request.target,
                        contentMode: request.contentMode
                    )
                } else {
                    outputImage = result.image
                }
                if let outputImage, let cgImage = Self.cgImage(outputImage) {
                    finish(
                        ComparatorLoadOutput(
                            measurement: try! ComparatorLoadResult(
                                outcome: .completed,
                                cacheSource: Self.cacheSource(result.resultType),
                                latencyNanoseconds: latency,
                                pixelWidth: cgImage.width,
                                pixelHeight: cgImage.height,
                                receivedBytes: snapshot.receivedBytes
                            ),
                            image: ComparatorRenderImage(cgImage: cgImage)
                        )
                    )
                } else {
                    let cancelled =
                        snapshot.cancelled
                        || (result.error as? URLError)?.code == .cancelled
                        || (result.error as NSError?)?.code == NSURLErrorCancelled
                    finish(
                        ComparatorLoadOutput(
                            measurement: try! ComparatorLoadResult(
                                outcome: cancelled ? .cancelled : .failed,
                                cacheSource: .unknown,
                                latencyNanoseconds: latency,
                                receivedBytes: snapshot.receivedBytes,
                                failureCategory: cancelled ? nil : "transport-or-decode"
                            ),
                            image: nil
                        )
                    )
                }
            }
            let uuid: UUID?
            if privateRequest {
                uuid = self.manager.downloadImage(
                    with: url,
                    options: options,
                    priority: Self.priority(request.priority),
                    progressImage: nil,
                    progressDownload: progress,
                    completion: completion
                )
            } else {
                uuid = self.manager.downloadImage(
                    with: url,
                    options: options,
                    processorKey: processorKey,
                    processor: { result, cost in
                        guard let image = result.image,
                            let resized = Self.resize(
                                image,
                                target: request.target,
                                contentMode: request.contentMode
                            )
                        else { return nil }
                        cost.pointee = UInt(Self.imageCost(resized))
                        return resized
                    },
                    progressDownload: progress,
                    completion: completion
                )
            }
            box.install(uuid, manager: self.manager)
            if let uuid {
                self.manager.setPriority(Self.priority(request.priority), ofTaskWith: uuid)
            }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    relay.install(continuation)
                }
            } onCancel: {
                cancelOperation()
            }
        }
        return ComparatorLoad(
            cancel: { task.cancel() },
            result: { await task.value }
        )
    }

    public func purgeMemory() async {
        manager.pinCache?.memoryCache.removeAllObjects()
    }

    public func purgeDisk() async throws {
        manager.pinCache?.memoryCache.removeAllObjects()
        manager.pinCache?.diskCache.removeAllObjects()
    }

    public func revoke(namespace: String) async throws {
        activeLoads.cancelAll()
        manager.cancelAllTasks()
        try await purgeDisk()
    }

    public func cancelAll() async {
        activeLoads.cancelAll()
        manager.cancelAllTasks()
    }

    private func scopeToken(_ request: ComparatorRequest) -> String {
        var bytes = Data(request.securityNamespace.utf8)
        bytes.append(0)
        bytes.append(contentsOf: request.resourceID.utf8)
        for (name, value) in request.headers
            .filter({ $0.key != "x-benchmark-request-id" })
            .sorted(by: { $0.key < $1.key })
        {
            bytes.append(0)
            bytes.append(contentsOf: name.utf8)
            bytes.append(0)
            bytes.append(contentsOf: value.utf8)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func scopedURL(_ url: URL, token: String) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items.removeAll(where: { $0.name == "__fovea_scope" })
        items.append(URLQueryItem(name: "__fovea_scope", value: token))
        components.queryItems = items
        return components.url!
    }

    private static func priority(_ value: ComparatorPriority) -> PINRemoteImageManagerPriority {
        switch value {
        case .background: .low
        case .utility: .default
        case .visible, .immediate: .high
        }
    }

    private static func cacheSource(
        _ value: PINRemoteImageResultType
    ) -> ComparatorCacheSource {
        switch value {
        case .memoryCache: .memory
        case .cache: .disk
        case .download: .network
        default: .unknown
        }
    }

    private static func resize(
        _ image: PlatformImage,
        target: ComparatorPixelTarget,
        contentMode: ComparatorContentMode
    ) -> PlatformImage? {
        #if canImport(UIKit)
            let sourceSize = image.size
            let scale: CGFloat =
                contentMode == .aspectFit
                ? min(
                    CGFloat(target.width) / sourceSize.width,
                    CGFloat(target.height) / sourceSize.height)
                : max(
                    CGFloat(target.width) / sourceSize.width,
                    CGFloat(target.height) / sourceSize.height)
            let fitted = CGSize(
                width: max(1, sourceSize.width * scale),
                height: max(1, sourceSize.height * scale)
            )
            let outputSize =
                contentMode == .aspectFit
                ? CGSize(
                    width: max(1, min(CGFloat(target.width), floor(fitted.width))),
                    height: max(1, min(CGFloat(target.height), floor(fitted.height)))
                )
                : CGSize(width: target.width, height: target.height)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            return UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
                let origin = CGPoint(
                    x: (outputSize.width - fitted.width) / 2,
                    y: (outputSize.height - fitted.height) / 2
                )
                image.draw(in: CGRect(origin: origin, size: fitted))
            }
        #elseif canImport(AppKit)
            guard let source = cgImage(image) else { return nil }
            let sourceSize = CGSize(width: source.width, height: source.height)
            let scale: CGFloat =
                contentMode == .aspectFit
                ? min(
                    CGFloat(target.width) / sourceSize.width,
                    CGFloat(target.height) / sourceSize.height)
                : max(
                    CGFloat(target.width) / sourceSize.width,
                    CGFloat(target.height) / sourceSize.height)
            let fitted = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
            let outputSize =
                contentMode == .aspectFit
                ? CGSize(
                    width: max(1, min(CGFloat(target.width), floor(fitted.width))),
                    height: max(1, min(CGFloat(target.height), floor(fitted.height)))
                )
                : CGSize(width: target.width, height: target.height)
            let result = NSImage(size: outputSize)
            result.lockFocus()
            image.draw(
                in: CGRect(
                    x: (outputSize.width - fitted.width) / 2,
                    y: (outputSize.height - fitted.height) / 2,
                    width: fitted.width,
                    height: fitted.height
                ),
                from: .zero,
                operation: .copy,
                fraction: 1
            )
            result.unlockFocus()
            return result
        #endif
    }

    private static func cgImage(_ image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
            image.cgImage
        #elseif canImport(AppKit)
            var rect = CGRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #endif
    }

    private static func imageCost(_ image: PlatformImage) -> Int {
        guard let image = cgImage(image) else { return 0 }
        let (pixels, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        if overflow { return Int.max }
        let (bytes, bytesOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return bytesOverflow ? Int.max : bytes
    }
}
