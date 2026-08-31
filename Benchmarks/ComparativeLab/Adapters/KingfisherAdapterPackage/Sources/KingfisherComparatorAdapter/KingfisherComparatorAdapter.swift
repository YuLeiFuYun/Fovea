import ComparativeLabCore
import Foundation
import Kingfisher

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

private struct ExactPixelBoxProcessor: ImageProcessor {
    let width: Int
    let height: Int

    var identifier: String {
        "dev.fovea.comparative.exact-pixel-box-v1-\(width)x\(height)"
    }

    func process(
        item: ImageProcessItem,
        options: KingfisherParsedOptionsInfo
    ) -> KFCrossPlatformImage? {
        let image: KFCrossPlatformImage
        switch item {
        case .image(let value):
            image = value
        case .data:
            guard let decoded = DefaultImageProcessor.default.process(item: item, options: options)
            else { return nil }
            image = decoded
        }

        #if canImport(UIKit)
            guard let source = image.cgImage else { return image }
            let targetWidth = min(width, source.width)
            let targetHeight = min(height, source.height)
            guard source.width > targetWidth || source.height > targetHeight else { return image }
            let rect = CGRect(
                x: (source.width - targetWidth) / 2,
                y: (source.height - targetHeight) / 2,
                width: targetWidth,
                height: targetHeight
            )
            guard let cropped = source.cropping(to: rect) else { return nil }
            return UIImage(cgImage: cropped, scale: 1, orientation: image.imageOrientation)
        #elseif canImport(AppKit)
            var proposed = CGRect(origin: .zero, size: image.size)
            guard let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
            else { return image }
            let targetWidth = min(width, source.width)
            let targetHeight = min(height, source.height)
            guard source.width > targetWidth || source.height > targetHeight else { return image }
            let rect = CGRect(
                x: (source.width - targetWidth) / 2,
                y: (source.height - targetHeight) / 2,
                width: targetWidth,
                height: targetHeight
            )
            guard let cropped = source.cropping(to: rect) else { return nil }
            return NSImage(
                cgImage: cropped,
                size: CGSize(width: targetWidth, height: targetHeight)
            )
        #else
            return image
        #endif
    }
}

private final class KingfisherProgressiveBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?

    func update(_ value: Int64) {
        lock.withLock { self.value = max(0, Int(value)) }
    }

    func snapshot() -> Int? {
        lock.withLock { value }
    }
}

private final class KingfisherProgressiveObserver: @unchecked Sendable {
    private let operation: @Sendable (KFCrossPlatformImage) -> Void

    init(operation: @escaping @Sendable (KFCrossPlatformImage) -> Void) {
        self.operation = operation
    }

    func record(_ image: KFCrossPlatformImage) {
        operation(image)
    }
}

private final class KingfisherProgressiveSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}

private final class KingfisherProgressiveRetention: @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [AnyObject] = []

    func retain(_ objects: [AnyObject]) {
        lock.withLock { self.objects = objects }
    }

    func clear() {
        lock.withLock { objects.removeAll(keepingCapacity: false) }
    }
}

private final class DownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: DownloadTask?
    private var cancellationRequested = false

    func install(_ task: DownloadTask?) {
        let shouldCancel = lock.withLock {
            self.task = task
            return cancellationRequested
        }
        if shouldCancel { task?.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            cancellationRequested = true
            return self.task
        }
        task?.cancel()
    }
}

private func kingfisherExpirationIdentity(_ expiration: StorageExpiration) -> String {
    switch expiration {
    case .never:
        return "never"
    case .seconds(let seconds):
        return "seconds:\(seconds)"
    case .days(let days):
        return "days:\(days)"
    case .date(let date):
        return "date:\(date.timeIntervalSince1970)"
    case .expired:
        return "expired"
    }
}

public final class KingfisherComparatorAdapter: ComparatorProgressiveAdapter, @unchecked Sendable {
    public let identity: ComparatorIdentity
    public let runtimeConfiguration: ComparatorRuntimeConfiguration?

    private let cache: ImageCache
    private let downloader: ImageDownloader
    private let manager: KingfisherManager

    public init(
        cacheDirectory: URL,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        memoryCostLimit: Int = 128 * 1_024 * 1_024,
        diskSizeLimit: UInt = 256 * 1_024 * 1_024
    ) throws {
        identity = try ComparatorIdentity(
            name: "Kingfisher",
            version: "8.11.0",
            exactCommit: "410984bf301f4fa224fe56277b3f8672cc465c79"
        )
        cache = try ImageCache(
            name: "fovea-comparative-kingfisher",
            cacheDirectoryURL: cacheDirectory
        )
        let boundedMemoryCost = max(1, memoryCostLimit)
        let boundedDiskSize = max(1, diskSizeLimit)
        cache.memoryStorage.config.totalCostLimit = boundedMemoryCost
        cache.memoryStorage.config.countLimit = .max
        cache.memoryStorage.config.expiration = .seconds(300)
        cache.memoryStorage.config.cleanInterval = 120
        cache.memoryStorage.config.keepWhenEnteringBackground = false
        cache.diskStorage.config.sizeLimit = boundedDiskSize
        cache.diskStorage.config.expiration = .days(7)
        cache.diskStorage.config.usesHashedFileName = true
        cache.diskStorage.config.autoExtAfterHashedFileName = false
        downloader = ImageDownloader(name: "fovea-comparative-kingfisher")
        let session = sessionConfiguration.copy() as! URLSessionConfiguration
        session.urlCache = nil
        session.httpCookieStorage = nil
        session.urlCredentialStorage = nil
        session.httpShouldSetCookies = false
        downloader.sessionConfiguration = session
        runtimeConfiguration = try ComparatorRuntimeConfiguration(
            parameters: [
                "adapter.profile": "kingfisher-imagecache-downloader",
                "cache.kind": "isolated-ImageCache",
                "cache.rootPolicy": "evaluator-owned",
                "cache.memoryTotalCostLimitBytes": String(
                    cache.memoryStorage.config.totalCostLimit
                ),
                "cache.memoryCountLimit": String(cache.memoryStorage.config.countLimit),
                "cache.memoryExpiration": kingfisherExpirationIdentity(
                    cache.memoryStorage.config.expiration
                ),
                "cache.memoryCleanIntervalSeconds": String(
                    cache.memoryStorage.config.cleanInterval
                ),
                "cache.memoryKeepWhenEnteringBackground": String(
                    cache.memoryStorage.config.keepWhenEnteringBackground
                ),
                "cache.diskSizeLimitBytes": String(cache.diskStorage.config.sizeLimit),
                "cache.diskExpiration": kingfisherExpirationIdentity(
                    cache.diskStorage.config.expiration
                ),
                "cache.diskUsesHashedFileName": String(
                    cache.diskStorage.config.usesHashedFileName
                ),
                "cache.diskAutoExtAfterHashedFileName": String(
                    cache.diskStorage.config.autoExtAfterHashedFileName
                ),
                "download.kind": "isolated-ImageDownloader",
                "options.backgroundDecode": "true",
                "options.cacheOriginalImage": "true",
                "processor": "downsampling-plus-exact-target-fit-fill",
                "scaleFactor": "1",
                "session.base": "ephemeral",
                "session.cookies": "disabled",
                "session.credentials": "disabled",
                "session.httpMaximumConnectionsPerHost": String(
                    session.httpMaximumConnectionsPerHost
                ),
                "session.urlCache": "nil",
            ]
        )
        manager = KingfisherManager(downloader: downloader, cache: cache)
    }

    public func makeLoad(_ request: ComparatorRequest) async throws -> ComparatorLoad {
        let box = DownloadTaskBox()
        let preparation = ComparatorPreparationSignal()
        let started = DispatchTime.now().uptimeNanoseconds
        let targetSize = CGSize(width: request.target.width, height: request.target.height)
        let downsampling = DownsamplingImageProcessor(size: targetSize)
        let processor: any ImageProcessor
        switch request.contentMode {
        case .aspectFit:
            let fitted =
                downsampling
                |> ResizingImageProcessor(referenceSize: targetSize, mode: .aspectFit)
                |> ExactPixelBoxProcessor(
                    width: request.target.width, height: request.target.height)
            processor = fitted
        case .aspectFill:
            let filled =
                downsampling
                |> ResizingImageProcessor(referenceSize: targetSize, mode: .aspectFill)
                |> CroppingImageProcessor(size: targetSize)
                |> ExactPixelBoxProcessor(
                    width: request.target.width, height: request.target.height)
            processor = filled
        }
        let resource = KF.ImageResource(downloadURL: request.url, cacheKey: request.scopedCacheKey)
        let modifier = AnyModifier { urlRequest in
            var modified = urlRequest
            for (name, value) in request.headers {
                modified.setValue(value, forHTTPHeaderField: name)
            }
            return modified
        }
        let options: KingfisherOptionsInfo = [
            .targetCache(cache),
            .downloader(downloader),
            .processor(processor),
            .scaleFactor(1),
            .cacheOriginalImage,
            .backgroundDecode,
            .callbackQueue(.untouch),
            .downloadPriority(priority(request.priority)),
            .requestModifier(modifier),
        ]
        let resultTask = Task<ComparatorLoadOutput, Never> {
            await withCheckedContinuation { continuation in
                let task = manager.retrieveImage(
                    with: resource,
                    options: options,
                    completionHandler: { result in
                        let latency = DispatchTime.now().uptimeNanoseconds &- started
                        switch result {
                        case .success(let value):
                            let dimensions = Self.pixelDimensions(value.image)
                            let measurement = try! ComparatorLoadResult(
                                outcome: .completed,
                                cacheSource: Self.cacheSource(value.cacheType),
                                latencyNanoseconds: latency,
                                pixelWidth: dimensions.width,
                                pixelHeight: dimensions.height
                            )
                            continuation.resume(
                                returning: ComparatorLoadOutput(
                                    measurement: measurement,
                                    image: Self.renderImage(value.image)
                                )
                            )
                        case .failure(let error):
                            let measurement = try! ComparatorLoadResult(
                                outcome: error.isTaskCancelled ? .cancelled : .failed,
                                cacheSource: .unknown,
                                latencyNanoseconds: latency,
                                failureCategory: error.isTaskCancelled
                                    ? nil : Self.failureCategory(error)
                            )
                            continuation.resume(
                                returning: ComparatorLoadOutput(
                                    measurement: measurement, image: nil)
                            )
                        }
                    }
                )
                box.install(task)
                preparation.markPrepared()
            }
        }
        return ComparatorLoad(
            cancel: { box.cancel() },
            waitUntilPrepared: { await preparation.wait() },
            result: { await resultTask.value }
        )
    }

    public func makeProgressiveLoad(
        _ request: ComparatorRequest
    ) async throws -> ComparatorProgressiveLoad {
        let box = DownloadTaskBox()
        let retention = KingfisherProgressiveRetention()
        let sequence = KingfisherProgressiveSequence()
        let receivedBytes = KingfisherProgressiveBytes()
        let started = DispatchTime.now().uptimeNanoseconds
        let targetSize = CGSize(width: request.target.width, height: request.target.height)
        let downsampling = DownsamplingImageProcessor(size: targetSize)
        let processor: any ImageProcessor
        switch request.contentMode {
        case .aspectFit:
            let fitted =
                downsampling
                |> ResizingImageProcessor(referenceSize: targetSize, mode: .aspectFit)
                |> ExactPixelBoxProcessor(
                    width: request.target.width, height: request.target.height)
            processor = fitted
        case .aspectFill:
            let filled =
                downsampling
                |> ResizingImageProcessor(referenceSize: targetSize, mode: .aspectFill)
                |> CroppingImageProcessor(size: targetSize)
                |> ExactPixelBoxProcessor(
                    width: request.target.width, height: request.target.height)
            processor = filled
        }
        let resource = KF.ImageResource(downloadURL: request.url, cacheKey: request.scopedCacheKey)
        let modifier = AnyModifier { urlRequest in
            var modified = urlRequest
            for (name, value) in request.headers {
                modified.setValue(value, forHTTPHeaderField: name)
            }
            return modified
        }
        let stream = AsyncThrowingStream<ComparatorProgressiveFrame, any Error> { continuation in
            let observer = KingfisherProgressiveObserver { image in
                guard let rendered = Self.renderImage(image) else { return }
                let dimensions = Self.pixelDimensions(image)
                do {
                    continuation.yield(
                        ComparatorProgressiveFrame(
                            measurement: try ComparatorProgressiveFrameMeasurement(
                                sequence: sequence.next(),
                                kind: .preview,
                                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds
                                    &- started,
                                receivedBytes: receivedBytes.snapshot(),
                                pixelWidth: dimensions.width,
                                pixelHeight: dimensions.height
                            ),
                            image: rendered
                        )
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let progressive = ImageProgressive(
                isBlur: false, isFastestScan: true, scanInterval: 0
            )
            progressive.onImageUpdated.delegate(on: observer) { observer, image in
                observer.record(image)
                return .default
            }
            let options: KingfisherOptionsInfo = [
                .targetCache(cache),
                .downloader(downloader),
                .processor(processor),
                .scaleFactor(1),
                .backgroundDecode,
                .downloadPriority(priority(request.priority)),
                .requestModifier(modifier),
                .progressiveJPEG(progressive),
            ]
            continuation.onTermination = { @Sendable _ in
                box.cancel()
                retention.clear()
            }
            Task { @MainActor in
                let imageView = KFCrossPlatformImageView(frame: .zero)
                retention.retain([imageView, observer])
                let task = imageView.kf.setImage(
                    with: .network(resource),
                    options: options,
                    progressBlock: { completed, _ in receivedBytes.update(completed) },
                    completionHandler: { result in
                        defer { retention.clear() }
                        switch result {
                        case .success(let value):
                            guard let rendered = Self.renderImage(value.image) else {
                                continuation.finish(
                                    throwing: URLError(.cannotDecodeContentData)
                                )
                                return
                            }
                            let dimensions = Self.pixelDimensions(value.image)
                            do {
                                continuation.yield(
                                    ComparatorProgressiveFrame(
                                        measurement: try ComparatorProgressiveFrameMeasurement(
                                            sequence: sequence.next(),
                                            kind: .final,
                                            elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds
                                                &- started,
                                            receivedBytes: receivedBytes.snapshot(),
                                            pixelWidth: dimensions.width,
                                            pixelHeight: dimensions.height
                                        ),
                                        image: rendered
                                    )
                                )
                                continuation.finish()
                            } catch {
                                continuation.finish(throwing: error)
                            }
                        case .failure(let error):
                            continuation.finish(throwing: error)
                        }
                    }
                )
                box.install(task)
            }
        }
        return ComparatorProgressiveLoad(
            cancel: {
                box.cancel()
                retention.clear()
            },
            frames: stream
        )
    }

    public func purgeMemory() async {
        cache.clearMemoryCache()
    }

    public func purgeDisk() async throws {
        await cache.clearDiskCache()
    }

    public func revoke(namespace: String) async throws {
        // Kingfisher has no namespace primitive. The adapter composes namespace into cacheKey
        // and conservatively clears both cache layers at logout.
        cache.clearMemoryCache()
        await cache.clearDiskCache()
    }

    public func cancelAll() async {
        downloader.cancelAll()
    }

    private static func makeResult(
        outcome: ComparatorOutcome,
        cacheSource: ComparatorCacheSource,
        latencyNanoseconds: UInt64,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        failureCategory: String? = nil
    ) -> ComparatorLoadResult {
        do {
            return try ComparatorLoadResult(
                outcome: outcome,
                cacheSource: cacheSource,
                latencyNanoseconds: latencyNanoseconds,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                failureCategory: failureCategory
            )
        } catch {
            preconditionFailure("Comparator adapter produced an invalid measurement")
        }
    }

    private func priority(_ value: ComparatorPriority) -> Float {
        switch value {
        case .background: 0.1
        case .utility: 0.35
        case .visible: 0.75
        case .immediate: 1.0
        }
    }

    private static func cacheSource(_ value: CacheType) -> ComparatorCacheSource {
        switch value {
        case .none: .network
        case .memory: .memory
        case .disk: .disk
        }
    }

    private static func failureCategory(_ error: KingfisherError) -> String {
        switch error {
        case .requestError: "request"
        case .responseError: "response"
        case .cacheError: "cache"
        case .processorError: "processing"
        case .imageSettingError: "setting"
        }
    }

    private static func renderImage(_ image: KFCrossPlatformImage) -> ComparatorRenderImage? {
        #if canImport(UIKit)
            return image.cgImage.map(ComparatorRenderImage.init(cgImage:))
        #elseif canImport(AppKit)
            var rect = CGRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil).map(
                ComparatorRenderImage.init(cgImage:))
        #else
            return nil
        #endif
    }

    private static func pixelDimensions(_ image: KFCrossPlatformImage) -> (width: Int, height: Int)
    {
        #if canImport(UIKit)
            if let cgImage = image.cgImage {
                return (cgImage.width, cgImage.height)
            }
            return (
                max(0, Int((image.size.width * image.scale).rounded())),
                max(0, Int((image.size.height * image.scale).rounded()))
            )
        #elseif canImport(AppKit)
            var rect = CGRect(origin: .zero, size: image.size)
            if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                return (cgImage.width, cgImage.height)
            }
            return (
                max(0, Int(image.size.width.rounded())), max(0, Int(image.size.height.rounded()))
            )
        #else
            return (0, 0)
        #endif
    }
}

#if canImport(UIKit)
    private enum KingfisherAnimatedAdapterError: Error {
        case unsupportedFormat
        case decodeFailed
        case missingFrameSource
        case invalidFrameCount(Int)
        case invalidFrameDuration(index: Int, seconds: Double)
        case invalidFrameDurationNanoseconds(index: Int, seconds: Double)
    }

    @MainActor
    private final class KingfisherAnimatedBenchmarkView: AnimatedImageView {
        var eventSink: ((Int, UInt64) -> Void)?
        private var isRecordingFrames = false
        private var lastRecordedFrameIndex: Int?

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

        override func display(_ layer: CALayer) {
            super.display(layer)
            guard isRecordingFrames,
                let frameIndex = animator?.currentFrameIndex,
                lastRecordedFrameIndex != frameIndex
            else { return }
            lastRecordedFrameIndex = frameIndex
            eventSink?(frameIndex, DispatchTime.now().uptimeNanoseconds)
        }
    }

    private final class KingfisherAnimatedEventState: @unchecked Sendable {
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
    private final class KingfisherAnimatedPlayerController {
        private let window: UIWindow
        private let imageView: KingfisherAnimatedBenchmarkView
        private let continuation: AsyncStream<ComparatorAnimatedPlayerFrameEvent>.Continuation
        private var stopped = false

        init(
            image: UIImage,
            frameCount: Int,
            maximumFrameBufferBytes: Int,
            continuation: AsyncStream<ComparatorAnimatedPlayerFrameEvent>.Continuation,
            state: KingfisherAnimatedEventState
        ) {
            let imageView = KingfisherAnimatedBenchmarkView(
                frame: CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
            )
            imageView.autoPlayAnimatedImage = false
            imageView.needsPrescaling = false
            imageView.repeatCount = .infinite
            imageView.runLoopMode = .common
            let pixelWidth = max(1, Int((image.size.width * image.scale).rounded(.up)))
            let pixelHeight = max(1, Int((image.size.height * image.scale).rounded(.up)))
            let frameBytes = max(1, pixelWidth * pixelHeight * 4)
            let budgetedFrameCount = max(1, maximumFrameBufferBytes / frameBytes)
            imageView.framePreloadCount = min(max(1, frameCount - 1), budgetedFrameCount)
            imageView.image = image
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
                window.frame = CGRect(
                    x: 0,
                    y: 0,
                    width: max(1, image.size.width),
                    height: max(1, image.size.height)
                )
            } else {
                window = UIWindow(
                    frame: CGRect(
                        x: 0,
                        y: 0,
                        width: max(1, image.size.width),
                        height: max(1, image.size.height)
                    )
                )
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
            imageView.startAnimating()
        }

        func pause() {
            guard !stopped else { return }
            imageView.stopAnimating()
        }

        func stop() {
            guard !stopped else { return }
            stopped = true
            imageView.stopAnimating()
            imageView.endRecordingFrames()
            imageView.eventSink = nil
            window.isHidden = true
            window.rootViewController = nil
            continuation.finish()
        }

        isolated deinit {
            imageView.stopAnimating()
            imageView.endRecordingFrames()
            imageView.eventSink = nil
            window.isHidden = true
            window.rootViewController = nil
            continuation.finish()
        }
    }

    extension KingfisherComparatorAdapter: ComparatorAnimatedPlayerAdapter {
        @MainActor
        public func makeAnimatedPlayer(
            _ request: ComparatorAnimatedPlayerRequest
        ) throws -> ComparatorAnimatedPlayerSession {
            guard request.format == .gif else {
                throw KingfisherAnimatedAdapterError.unsupportedFormat
            }
            guard
                let image = KingfisherWrapper<KFCrossPlatformImage>.image(
                    data: request.encodedData,
                    options: ImageCreatingOptions(
                        scale: 1,
                        duration: 0,
                        preloadAll: false,
                        onlyFirstFrame: false
                    )
                )
            else {
                throw KingfisherAnimatedAdapterError.decodeFailed
            }
            guard let frameSource = image.kf.frameSource else {
                throw KingfisherAnimatedAdapterError.missingFrameSource
            }
            guard frameSource.frameCount > 1 else {
                throw KingfisherAnimatedAdapterError.invalidFrameCount(frameSource.frameCount)
            }

            var durations: [UInt64] = []
            durations.reserveCapacity(frameSource.frameCount)
            for index in 0..<frameSource.frameCount {
                let duration = frameSource.duration(at: index)
                guard duration.isFinite, duration > 0 else {
                    throw KingfisherAnimatedAdapterError.invalidFrameDuration(
                        index: index,
                        seconds: duration
                    )
                }
                let nanoseconds = duration * 1_000_000_000
                guard nanoseconds.isFinite,
                    nanoseconds > 0,
                    nanoseconds <= Double(UInt64.max)
                else {
                    throw KingfisherAnimatedAdapterError.invalidFrameDurationNanoseconds(
                        index: index,
                        seconds: duration
                    )
                }
                durations.append(UInt64(nanoseconds.rounded(.toNearestOrEven)))
            }

            let pair = AsyncStream<ComparatorAnimatedPlayerFrameEvent>.makeStream(
                bufferingPolicy: .bufferingNewest(4_096)
            )
            let state = KingfisherAnimatedEventState()
            let controller = KingfisherAnimatedPlayerController(
                image: image,
                frameCount: frameSource.frameCount,
                maximumFrameBufferBytes: request.maximumFrameBufferBytes,
                continuation: pair.continuation,
                state: state
            )
            pair.continuation.onTermination = { @Sendable _ in
                Task { @MainActor in controller.stop() }
            }

            return try ComparatorAnimatedPlayerSession(
                sourceFrameDurationsNanoseconds: durations,
                sourceLoopCount: 0,
                inputPath: .encodedNative,
                events: pair.stream,
                start: { controller.start() },
                pause: { controller.pause() },
                stop: { controller.stop() }
            )
        }
    }
#endif
