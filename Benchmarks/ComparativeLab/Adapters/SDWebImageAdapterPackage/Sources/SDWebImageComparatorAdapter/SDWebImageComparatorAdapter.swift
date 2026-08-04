import ComparativeLabCore
import Foundation
import SDWebImage

#if canImport(UIKit)
    import UIKit
    private typealias PlatformImage = UIImage
#elseif canImport(AppKit)
    import AppKit
    private typealias PlatformImage = NSImage
#endif

private final class SDOperationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: SDWebImageCombinedOperation?
    private var cancellationRequested = false

    func install(_ operation: SDWebImageCombinedOperation?) {
        lock.lock()
        self.operation = operation
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel { operation?.cancel() }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let operation = operation
        lock.unlock()
        operation?.cancel()
    }
}

private final class SDProgressiveState: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence = 0
    private var receivedBytes: Int?

    func update(receivedBytes: Int) {
        lock.withLock { self.receivedBytes = max(0, receivedBytes) }
    }

    func next() -> (sequence: Int, receivedBytes: Int?) {
        lock.withLock {
            defer { sequence += 1 }
            return (sequence, receivedBytes)
        }
    }
}

private final class SDResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var output: ComparatorLoadOutput?
    private var waiters: [CheckedContinuation<ComparatorLoadOutput, Never>] = []

    func complete(_ output: ComparatorLoadOutput) {
        lock.lock()
        guard self.output == nil else {
            lock.unlock()
            return
        }
        self.output = output
        let waiters = self.waiters
        self.waiters.removeAll(keepingCapacity: false)
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: output) }
    }

    func value() async -> ComparatorLoadOutput {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let output {
                lock.unlock()
                continuation.resume(returning: output)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

public final class SDWebImageComparatorAdapter: ComparatorProgressiveAdapter, @unchecked Sendable {
    public let identity: ComparatorIdentity

    private let cache: SDImageCache
    private let manager: SDWebImageManager

    public init(
        cacheDirectory: URL,
        memoryCostLimit: Int = 128 * 1_024 * 1_024,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        maximumConcurrentDownloads: Int = 6
    ) throws {
        identity = try ComparatorIdentity(
            name: "SDWebImage",
            version: "5.21.7",
            exactCommit: "2de3a496eaf6df9a1312862adcfd54acd73c39c0"
        )
        let cacheConfig = SDImageCacheConfig()
        cacheConfig.maxMemoryCost = UInt(max(1, memoryCostLimit))
        cacheConfig.maxDiskSize = 256 * 1_024 * 1_024
        cache = SDImageCache(
            namespace: "FoveaComparativeLab",
            diskCacheDirectory: cacheDirectory.path,
            config: cacheConfig
        )
        let downloaderConfig = SDWebImageDownloaderConfig()
        let session = sessionConfiguration.copy() as! URLSessionConfiguration
        session.urlCache = nil
        session.httpCookieStorage = nil
        session.urlCredentialStorage = nil
        session.httpShouldSetCookies = false
        downloaderConfig.sessionConfiguration = session
        downloaderConfig.maxConcurrentDownloads = max(1, maximumConcurrentDownloads)
        let downloader = SDWebImageDownloader(config: downloaderConfig)
        manager = SDWebImageManager(cache: cache, loader: downloader)
    }

    public func makeLoad(_ request: ComparatorRequest) async throws -> ComparatorLoad {
        let target = CGSize(width: request.target.width, height: request.target.height)
        let scaleMode: SDImageScaleMode =
            request.contentMode == .aspectFit ? .aspectFit : .aspectFill
        let transformer = SDImageResizingTransformer(size: target, scaleMode: scaleMode)
        let key = request.scopedCacheKey
        let keyFilter = SDWebImageCacheKeyFilter { _ in key }
        let modifier = SDWebImageDownloaderRequestModifier(headers: request.headers)
        #if canImport(UIKit)
            let targetValue = NSValue(cgSize: target)
        #else
            let targetValue = NSValue(size: target)
        #endif
        let context: [SDWebImageContextOption: Any] = [
            .imageTransformer: transformer,
            .imageThumbnailPixelSize: targetValue,
            .cacheKeyFilter: keyFilter,
            .downloadRequestModifier: modifier,
        ]
        let started = DispatchTime.now().uptimeNanoseconds
        let box = SDOperationBox()
        let resultBox = SDResultBox()
        // Install the native SDWebImage operation before makeLoad returns. W7 prepares
        // every subscriber before cancellation; deferring operation creation to an
        // unstructured Task would make a nominally prepared subscriber arrive late and
        // could restart a just-cancelled shared download.
        let operation = manager.loadImage(
            with: request.url,
            options: [.scaleDownLargeImages],
            context: context,
            progress: nil
        ) { image, _, error, cacheType, finished, _ in
            guard finished else { return }
            let latency = DispatchTime.now().uptimeNanoseconds &- started
            if let image {
                let dimensions = Self.pixelDimensions(image)
                resultBox.complete(
                    ComparatorLoadOutput(
                        measurement: try! ComparatorLoadResult(
                            outcome: .completed,
                            cacheSource: Self.cacheSource(cacheType),
                            latencyNanoseconds: latency,
                            pixelWidth: dimensions.width,
                            pixelHeight: dimensions.height
                        ),
                        image: Self.renderImage(image)
                    )
                )
            } else {
                let nsError = error as NSError?
                let cancelled = nsError.map(Self.isCancellation) ?? false
                resultBox.complete(
                    ComparatorLoadOutput(
                        measurement: try! ComparatorLoadResult(
                            outcome: cancelled ? .cancelled : .failed,
                            cacheSource: .unknown,
                            latencyNanoseconds: latency,
                            failureCategory: cancelled ? nil : "transport-or-decode"
                        ),
                        image: nil
                    )
                )
            }
        }
        box.install(operation)
        return ComparatorLoad(
            cancel: { box.cancel() },
            result: { await resultBox.value() }
        )
    }

    public func makeProgressiveLoad(
        _ request: ComparatorRequest
    ) async throws -> ComparatorProgressiveLoad {
        let target = CGSize(width: request.target.width, height: request.target.height)
        let scaleMode: SDImageScaleMode =
            request.contentMode == .aspectFit ? .aspectFit : .aspectFill
        let transformer = SDImageResizingTransformer(size: target, scaleMode: scaleMode)
        let keyFilter = SDWebImageCacheKeyFilter { _ in request.scopedCacheKey }
        let modifier = SDWebImageDownloaderRequestModifier(headers: request.headers)
        #if canImport(UIKit)
            let targetValue = NSValue(cgSize: target)
        #else
            let targetValue = NSValue(size: target)
        #endif
        let context: [SDWebImageContextOption: Any] = [
            .imageTransformer: transformer,
            .imageThumbnailPixelSize: targetValue,
            .cacheKeyFilter: keyFilter,
            .downloadRequestModifier: modifier,
        ]
        let started = DispatchTime.now().uptimeNanoseconds
        let box = SDOperationBox()
        let state = SDProgressiveState()
        let stream = AsyncThrowingStream<ComparatorProgressiveFrame, any Error> { continuation in
            let operation = manager.loadImage(
                with: request.url,
                options: [.scaleDownLargeImages, .progressiveLoad],
                context: context,
                progress: { received, _, _ in state.update(receivedBytes: received) }
            ) { image, _, error, _, finished, _ in
                guard let image, let rendered = Self.renderImage(image) else {
                    if finished {
                        continuation.finish(
                            throwing: error ?? URLError(.cannotDecodeContentData)
                        )
                    }
                    return
                }
                let snapshot = state.next()
                let dimensions = Self.pixelDimensions(image)
                do {
                    continuation.yield(
                        ComparatorProgressiveFrame(
                            measurement: try ComparatorProgressiveFrameMeasurement(
                                sequence: snapshot.sequence,
                                kind: finished ? .final : .preview,
                                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds
                                    &- started,
                                receivedBytes: snapshot.receivedBytes,
                                pixelWidth: dimensions.width,
                                pixelHeight: dimensions.height
                            ),
                            image: rendered
                        )
                    )
                    if finished { continuation.finish() }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            box.install(operation)
            continuation.onTermination = { @Sendable _ in box.cancel() }
        }
        return ComparatorProgressiveLoad(cancel: { box.cancel() }, frames: stream)
    }

    public func purgeMemory() async {
        cache.clearMemory()
    }

    public func purgeDisk() async throws {
        cache.clearMemory()
        await withCheckedContinuation { continuation in
            cache.clearDisk { continuation.resume() }
        }
    }

    public func revoke(namespace: String) async throws {
        // SDWebImage has no generation fence for an in-flight selective namespace revoke.
        // A full purge is the safest adapter behavior and W3 still tests commit-after-revoke.
        try await purgeDisk()
    }

    public func cancelAll() async {
        manager.cancelAll()
    }

    private static func isCancellation(_ error: NSError) -> Bool {
        (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == SDWebImageErrorDomain
                && error.code == SDWebImageError.cancelled.rawValue)
    }

    private static func cacheSource(_ value: SDImageCacheType) -> ComparatorCacheSource {
        switch value {
        case .memory: .memory
        case .disk: .disk
        case .none: .network
        default: .unknown
        }
    }

    private static func renderImage(_ image: PlatformImage) -> ComparatorRenderImage? {
        #if canImport(UIKit)
            return image.cgImage.map(ComparatorRenderImage.init(cgImage:))
        #elseif canImport(AppKit)
            var rect = CGRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil).map(
                ComparatorRenderImage.init(cgImage:))
        #endif
    }

    private static func pixelDimensions(_ image: PlatformImage) -> (width: Int, height: Int) {
        #if canImport(UIKit)
            if let cgImage = image.cgImage { return (cgImage.width, cgImage.height) }
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
                max(0, Int(image.size.width.rounded())),
                max(0, Int(image.size.height.rounded()))
            )
        #endif
    }
}
