import ComparativeLabCore
import CryptoKit
import Foundation
import PINCache
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

private final class PINProgressiveSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            defer { value += 1 }
            return value
        }
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

private let pinResumeCacheKeyPrefix = "R-"

private func makeIsolatedPINRemoteImageCache(root: URL) -> PINCache {
    let serializer: PINDiskCacheSerializerBlock = { object, key in
        if key.hasPrefix(pinResumeCacheKeyPrefix) {
            return
                (try? NSKeyedArchiver.archivedData(
                    withRootObject: object,
                    requiringSecureCoding: false
                )) ?? Data()
        }
        return (object as? NSData).map { $0 as Data } ?? Data()
    }
    let deserializer: PINDiskCacheDeserializerBlock = { data, key in
        if key.hasPrefix(pinResumeCacheKeyPrefix),
            let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data as Data)
        {
            unarchiver.requiresSecureCoding = false
            defer { unarchiver.finishDecoding() }
            if let object = try? unarchiver.decodeTopLevelObject(
                forKey: NSKeyedArchiveRootObjectKey
            ) as? NSCoding {
                return object
            }
        }
        return data as NSData
    }
    return PINCache(
        name: "PINRemoteImageManagerCache",
        rootPath: root.path,
        serializer: serializer,
        deserializer: deserializer,
        keyEncoder: nil,
        keyDecoder: nil,
        ttlCache: true
    )
}

public final class PINRemoteImageComparatorAdapter: ComparatorProgressiveAdapter,
    @unchecked Sendable
{
    public let identity: ComparatorIdentity
    public let runtimeConfiguration: ComparatorRuntimeConfiguration?

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
        let boundedDownloads = max(1, maximumConcurrentDownloads)
        let configuration = PINRemoteImageManagerConfiguration()
        configuration.maxConcurrentDownloads = UInt(boundedDownloads)
        configuration.maxConcurrentOperations = UInt(boundedDownloads)
        configuration.estimatedRemainingTimeThreshold = 0
        configuration.shouldBlurProgressive = false
        configuration.maxProgressiveRenderSize = CGSize(width: 8192, height: 8192)
        let imageCache = makeIsolatedPINRemoteImageCache(root: cacheDirectory)
        let rootPath = cacheDirectory.standardizedFileURL.path
        let diskPath = imageCache.diskCache.cacheURL.standardizedFileURL.path
        guard diskPath == rootPath || diskPath.hasPrefix(rootPath + "/") else {
            throw ComparativeLabError.invalidIdentifier
        }
        runtimeConfiguration = try ComparatorRuntimeConfiguration(
            parameters: [
                "adapter.profile": "pinremoteimage-isolated-ttl-cache",
                "cache.kind": "PINCache-TTL",
                "cache.rootPolicy": "evaluator-owned",
                "cache.memoryCostLimit": String(imageCache.memoryCache.costLimit),
                "cache.memoryAgeLimitSeconds": String(imageCache.memoryCache.ageLimit),
                "cache.memoryTTL": String(imageCache.memoryCache.isTTLCache),
                "cache.diskByteLimit": String(imageCache.diskCache.byteLimit),
                "cache.diskAgeLimitSeconds": String(imageCache.diskCache.ageLimit),
                "cache.diskTTL": String(imageCache.diskCache.isTTLCache),
                "cache.evictionStrategy": "least-recently-used",
                "cache.serialization": "PINRemoteImage-resume-aware-v1",
                "dependency.PINCache": "3.0.4@2fb85948463292c2e824148cf17dc62a4c217a94",
                "dependency.PINOperation": "1.2.3@a74f978733bdaf982758bfa23d70a189f4b4c1b6",
                "progressive.estimatedRemainingTimeThresholdSeconds": "0",
                "progressive.maxRenderHeightPixels": "8192",
                "progressive.maxRenderWidthPixels": "8192",
                "progressive.shouldBlur": "false",
                "scheduler.maximumConcurrentDownloads": String(boundedDownloads),
                "scheduler.maximumConcurrentOperations": String(boundedDownloads),
                "session.base": "ephemeral",
                "session.cookies": "disabled",
                "session.credentials": "disabled",
                "session.httpMaximumConnectionsPerHost": String(
                    session.httpMaximumConnectionsPerHost
                ),
                "session.urlCache": "nil",
            ]
        )
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
        let preparation = ComparatorPreparationSignal()
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
            preparation.markPrepared()
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
            waitUntilPrepared: { await preparation.wait() },
            result: { await task.value }
        )
    }

    public func makeProgressiveLoad(
        _ request: ComparatorRequest
    ) async throws -> ComparatorProgressiveLoad {
        let started = DispatchTime.now().uptimeNanoseconds
        let token = scopeToken(request)
        headerRegistry.register(token: token, headers: request.headers)
        let url = scopedURL(request.url, token: token)
        let box = PINOperationBox()
        let sequence = PINProgressiveSequence()
        let operationID = UUID()
        let stream = AsyncThrowingStream<ComparatorProgressiveFrame, any Error> { continuation in
            let cancelOperation: @Sendable () -> Void = { [self] in
                box.cancel(manager: manager)
                activeLoads.remove(id: operationID)
            }
            activeLoads.register(id: operationID, cancellation: cancelOperation)
            let progressDownload: PINRemoteImageManagerProgressDownload = { completed, _ in
                box.record(receivedBytes: completed)
            }
            let progressImage: PINRemoteImageManagerImageCompletion = { result in
                guard let image = result.image,
                    let resized = Self.resize(
                        image, target: request.target, contentMode: request.contentMode
                    ),
                    let cgImage = Self.cgImage(resized)
                else { return }
                let snapshot = box.snapshot()
                do {
                    continuation.yield(
                        ComparatorProgressiveFrame(
                            measurement: try ComparatorProgressiveFrameMeasurement(
                                sequence: sequence.next(),
                                kind: .preview,
                                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds
                                    &- started,
                                receivedBytes: snapshot.receivedBytes,
                                pixelWidth: cgImage.width,
                                pixelHeight: cgImage.height
                            ),
                            image: ComparatorRenderImage(cgImage: cgImage)
                        )
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let completion: PINRemoteImageManagerImageCompletion = { [activeLoads] result in
                activeLoads.remove(id: operationID)
                guard let image = result.image,
                    let resized = Self.resize(
                        image, target: request.target, contentMode: request.contentMode
                    ),
                    let cgImage = Self.cgImage(resized)
                else {
                    continuation.finish(
                        throwing: result.error ?? URLError(.cannotDecodeContentData)
                    )
                    return
                }
                let snapshot = box.snapshot()
                do {
                    continuation.yield(
                        ComparatorProgressiveFrame(
                            measurement: try ComparatorProgressiveFrameMeasurement(
                                sequence: sequence.next(),
                                kind: .final,
                                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds
                                    &- started,
                                receivedBytes: snapshot.receivedBytes,
                                pixelWidth: cgImage.width,
                                pixelHeight: cgImage.height
                            ),
                            image: ComparatorRenderImage(cgImage: cgImage)
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let options: PINRemoteImageManagerDownloadOptions = [
                .disallowAlternateRepresentations,
                .downloadOptionsSkipRetry,
            ]
            let uuid = manager.downloadImage(
                with: url,
                options: options,
                priority: Self.priority(request.priority),
                progressImage: progressImage,
                progressDownload: progressDownload,
                completion: completion
            )
            box.install(uuid, manager: manager)
            continuation.onTermination = { @Sendable _ in cancelOperation() }
        }
        return ComparatorProgressiveLoad(
            cancel: {
                box.cancel(manager: self.manager)
                self.activeLoads.remove(id: operationID)
            },
            frames: stream
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

#if canImport(UIKit)
    private enum PINAnimatedAdapterError: Error {
        case unsupportedFormat
        case decodeFailed
        case invalidFrameCount(Int)
        case invalidFrameDuration(index: Int, seconds: Double)
        case invalidFrameIdentity
    }

    private final class PINAnimatedEventState: @unchecked Sendable {
        private let lock = NSLock()
        private var sequence = 0

        func next(frameIndex: Int, timestamp: UInt64) -> ComparatorAnimatedPlayerFrameEvent? {
            lock.withLock {
                defer { sequence += 1 }
                return try? ComparatorAnimatedPlayerFrameEvent(
                    sequence: sequence,
                    monotonicNanoseconds: timestamp,
                    sourceFrameIndex: frameIndex
                )
            }
        }
    }

    @MainActor
    private final class PINAnimatedBenchmarkView: PINAnimatedImageView {
        var eventSink: ((Int, UInt64) -> Void)?
        private var isRecordingFrames = false
        private var lastRecordedFrameIndex: Int?
        private let frameCountForIdentity: Int

        init(animatedImage: PINCachedAnimatedImage, frameCount: Int) {
            frameCountForIdentity = frameCount
            super.init(animatedImage: animatedImage)
        }

        required init?(coder: NSCoder) {
            fatalError("PIN animated comparator does not support NSCoder")
        }

        override func display(_ layer: CALayer) {
            super.display(layer)
            guard isRecordingFrames else { return }
            let timestamp = DispatchTime.now().uptimeNanoseconds
            guard let image = image,
                let frameIndex = Self.sourceFrameIndex(
                    image: image,
                    frameCount: frameCountForIdentity
                ),
                frameIndex != lastRecordedFrameIndex
            else { return }
            lastRecordedFrameIndex = frameIndex
            eventSink?(frameIndex, timestamp)
        }

        func beginRecordingFrames() {
            isRecordingFrames = true
            lastRecordedFrameIndex = nil
            setNeedsDisplay()
            layer.setNeedsDisplay()
        }

        func endRecordingFrames() {
            isRecordingFrames = false
            lastRecordedFrameIndex = nil
        }

        private static func sourceFrameIndex(image: UIImage, frameCount: Int) -> Int? {
            guard let cgImage = image.cgImage else { return nil }
            var pixel = [UInt8](repeating: 0, count: 4)
            guard
                let context = CGContext(
                    data: &pixel,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                )
            else { return nil }
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let red = Int(pixel[0])
            let green = Int(pixel[1])
            let blue = Int(pixel[2])
            let index = ((red - 17 + 256) * 173) % 256
            guard index < frameCount,
                green == (index * 73 + 29) % 256,
                blue == (index * 109 + 43) % 256
            else { return nil }
            return index
        }
    }

    @MainActor
    private final class PINAnimatedPlayerController {
        private let window: UIWindow
        private let imageView: PINAnimatedBenchmarkView
        private let continuation: AsyncStream<ComparatorAnimatedPlayerFrameEvent>.Continuation
        private var stopped = false

        init(
            animatedImage: PINCachedAnimatedImage,
            frameCount: Int,
            continuation: AsyncStream<ComparatorAnimatedPlayerFrameEvent>.Continuation,
            state: PINAnimatedEventState
        ) {
            let imageView = PINAnimatedBenchmarkView(
                animatedImage: animatedImage,
                frameCount: frameCount
            )
            imageView.frame = CGRect(
                x: 0,
                y: 0,
                width: max(1, animatedImage.size.width),
                height: max(1, animatedImage.size.height)
            )
            imageView.animatedImageRunLoopMode = RunLoop.Mode.common.rawValue
            imageView.isPlaybackPaused = true
            imageView.eventSink = { frameIndex, timestamp in
                guard let event = state.next(frameIndex: frameIndex, timestamp: timestamp) else {
                    return
                }
                continuation.yield(event)
            }

            let controller = UIViewController()
            controller.view.backgroundColor = .clear
            controller.view.addSubview(imageView)
            let window: UIWindow
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first
            {
                window = UIWindow(windowScene: scene)
                window.frame = imageView.frame
            } else {
                window = UIWindow(frame: imageView.frame)
            }
            window.rootViewController = controller
            window.isHidden = true

            self.window = window
            self.imageView = imageView
            self.continuation = continuation
        }

        func start() {
            guard !stopped else { return }
            imageView.beginRecordingFrames()
            window.makeKeyAndVisible()
            imageView.isPlaybackPaused = false
        }

        func pause() {
            guard !stopped else { return }
            imageView.isPlaybackPaused = true
        }

        func stop() {
            guard !stopped else { return }
            stopped = true
            imageView.isPlaybackPaused = true
            imageView.endRecordingFrames()
            imageView.eventSink = nil
            imageView.animatedImage = nil
            window.isHidden = true
            window.rootViewController = nil
            continuation.finish()
        }

        isolated deinit {
            imageView.isPlaybackPaused = true
            imageView.endRecordingFrames()
            imageView.eventSink = nil
            imageView.animatedImage = nil
            window.isHidden = true
            window.rootViewController = nil
            continuation.finish()
        }
    }

    extension PINRemoteImageComparatorAdapter: ComparatorAnimatedPlayerAdapter {
        @MainActor
        public func makeAnimatedPlayer(
            _ request: ComparatorAnimatedPlayerRequest
        ) throws -> ComparatorAnimatedPlayerSession {
            guard
                let animatedImage = PINCachedAnimatedImage(
                    animatedImageData: request.encodedData
                )
            else {
                throw PINAnimatedAdapterError.decodeFailed
            }
            let frameCount = Int(animatedImage.frameCount)
            guard frameCount > 1 else {
                throw PINAnimatedAdapterError.invalidFrameCount(frameCount)
            }
            var durations: [UInt64] = []
            durations.reserveCapacity(frameCount)
            for index in 0..<frameCount {
                let duration = animatedImage.duration(at: UInt(index))
                guard duration.isFinite, duration > 0 else {
                    throw PINAnimatedAdapterError.invalidFrameDuration(
                        index: index,
                        seconds: duration
                    )
                }
                do {
                    let normalized: UInt64
                    switch request.format {
                    case .gif:
                        normalized =
                            try ComparatorAnimatedDurationNormalization
                            .gifCentisecondNanoseconds(seconds: duration)
                    case .apng:
                        normalized =
                            try ComparatorAnimatedDurationNormalization
                            .nearestMicrosecondNanoseconds(seconds: duration)
                    }
                    durations.append(normalized)
                } catch {
                    throw PINAnimatedAdapterError.invalidFrameDuration(
                        index: index,
                        seconds: duration
                    )
                }
            }

            let pair = AsyncStream<ComparatorAnimatedPlayerFrameEvent>.makeStream(
                bufferingPolicy: .bufferingNewest(4_096)
            )
            let state = PINAnimatedEventState()
            let controller = PINAnimatedPlayerController(
                animatedImage: animatedImage,
                frameCount: frameCount,
                continuation: pair.continuation,
                state: state
            )
            pair.continuation.onTermination = { @Sendable _ in
                Task { @MainActor in controller.stop() }
            }
            return try ComparatorAnimatedPlayerSession(
                sourceFrameDurationsNanoseconds: durations,
                sourceLoopCount: UInt(animatedImage.loopCount),
                inputPath: .encodedNative,
                events: pair.stream,
                start: { controller.start() },
                pause: { controller.pause() },
                stop: { controller.stop() }
            )
        }
    }
#endif
