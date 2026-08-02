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

private final class SDCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func resume(
        _ continuation: CheckedContinuation<ComparatorLoadOutput, Never>,
        returning output: ComparatorLoadOutput
    ) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        continuation.resume(returning: output)
    }
}

public final class SDWebImageComparatorAdapter: ComparatorAdapter, @unchecked Sendable {
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
        let completionGate = SDCompletionGate()
        let task = Task<ComparatorLoadOutput, Never> { [manager] in
            await withCheckedContinuation { continuation in
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
                        completionGate.resume(
                            continuation,
                            returning: ComparatorLoadOutput(
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
                        let cancelled = (error as NSError?)?.code == NSURLErrorCancelled
                        completionGate.resume(
                            continuation,
                            returning: ComparatorLoadOutput(
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
            }
        }
        return ComparatorLoad(
            cancel: { box.cancel() },
            result: { await task.value }
        )
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
