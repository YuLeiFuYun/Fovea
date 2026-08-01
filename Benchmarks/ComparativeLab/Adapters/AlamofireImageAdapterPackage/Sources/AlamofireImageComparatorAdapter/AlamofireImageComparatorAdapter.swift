import AlamofireImage
import ComparativeLabCore
import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

private final class ReceiptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var receipt: RequestReceipt?
    private var cancellationRequested = false

    func install(_ receipt: RequestReceipt?, downloader: ImageDownloader) {
        lock.lock()
        self.receipt = receipt
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel, let receipt { downloader.cancelRequest(with: receipt) }
    }

    func cancel(using downloader: ImageDownloader) {
        lock.lock()
        cancellationRequested = true
        let receipt = receipt
        lock.unlock()
        if let receipt { downloader.cancelRequest(with: receipt) }
    }
}

public final class AlamofireImageComparatorAdapter: ComparatorAdapter, @unchecked Sendable {
    public let identity: ComparatorIdentity

    private let downloader: ImageDownloader
    private let cache: AutoPurgingImageCache
    private let urlCache: URLCache
    private let activeLock = NSLock()
    private var active: [UUID: ReceiptBox] = [:]

    public init(
        cacheDirectory: URL,
        memoryCostLimit: Int = 128 * 1_024 * 1_024,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        maximumConcurrentDownloads: Int = 6
    ) throws {
        identity = try ComparatorIdentity(
            name: "AlamofireImage",
            version: "4.4.0",
            exactCommit: "4cf73d601c482b7d77bae47de3ef1b8bcf328ec1"
        )
        cache = AutoPurgingImageCache(
            memoryCapacity: UInt64(max(1, memoryCostLimit)),
            preferredMemoryUsageAfterPurge: UInt64(max(1, memoryCostLimit * 3 / 4))
        )
        let session = sessionConfiguration.copy() as! URLSessionConfiguration
        session.httpCookieStorage = nil
        session.urlCredentialStorage = nil
        session.httpShouldSetCookies = false
        urlCache = URLCache(
            memoryCapacity: 0,
            diskCapacity: 256 * 1_024 * 1_024,
            directory: cacheDirectory.appendingPathComponent("URLCache", isDirectory: true)
        )
        session.urlCache = urlCache
        downloader = ImageDownloader(
            configuration: session,
            downloadPrioritization: .fifo,
            maximumActiveDownloads: max(1, maximumConcurrentDownloads),
            imageCache: cache
        )
    }

    public func makeLoad(_ request: ComparatorRequest) async throws -> ComparatorLoad {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.cachePolicy = .useProtocolCachePolicy
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let target = CGSize(width: request.target.width, height: request.target.height)
        let filter = Self.makeFilter(target: target, contentMode: request.contentMode)
        let cacheKey = "\(request.scopedCacheKey)|\(filter.identifier)"
        let cachedBeforeStart = cache.image(withIdentifier: cacheKey) != nil
        let started = DispatchTime.now().uptimeNanoseconds
        let box = ReceiptBox()
        let token = UUID()
        activeLock.withLock { active[token] = box }

        let task = Task<ComparatorLoadOutput, Never> { [downloader, weak self] in
            await withCheckedContinuation { continuation in
                let receipt = downloader.download(
                    urlRequest,
                    cacheKey: cacheKey,
                    receiptID: token.uuidString,
                    filter: filter,
                    progressQueue: DispatchQueue.global(qos: .utility)
                ) { [weak self] response in
                    defer { self?.removeActive(token) }
                    let latency = DispatchTime.now().uptimeNanoseconds &- started
                    switch response.result {
                    case .success(let image):
                        let dimensions = Self.pixelDimensions(image)
                        let source: ComparatorCacheSource = cachedBeforeStart ? .memory : .network
                        continuation.resume(
                            returning: ComparatorLoadOutput(
                                measurement: try! ComparatorLoadResult(
                                    outcome: .completed,
                                    cacheSource: source,
                                    latencyNanoseconds: latency,
                                    pixelWidth: dimensions.width,
                                    pixelHeight: dimensions.height
                                ),
                                image: Self.renderImage(image)
                            )
                        )
                    case .failure(let error):
                        let cancelled = error.isRequestCancelledError
                        continuation.resume(
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
                box.install(receipt, downloader: downloader)
            }
        }

        return ComparatorLoad(
            cancel: { box.cancel(using: self.downloader) },
            result: { await task.value }
        )
    }

    public func purgeMemory() async {
        _ = cache.removeAllImages()
    }

    public func purgeDisk() async throws {
        urlCache.removeAllCachedResponses()
        _ = cache.removeAllImages()
    }

    public func revoke(namespace: String) async throws {
        // AlamofireImage exposes neither namespace generations nor selective invalidation.
        // The safest adapter behavior is a full cache purge.
        urlCache.removeAllCachedResponses()
        _ = cache.removeAllImages()
    }

    public func cancelAll() async {
        let boxes = activeLock.withLock { Array(active.values) }
        for box in boxes { box.cancel(using: downloader) }
    }

    private func removeActive(_ token: UUID) {
        _ = activeLock.withLock { active.removeValue(forKey: token) }
    }

    private static func makeFilter(
        target: CGSize,
        contentMode: ComparatorContentMode
    ) -> any ImageFilter {
        #if canImport(UIKit)
            switch contentMode {
            case .aspectFit:
                let identifier =
                    "fovea-benchmark-fit-\(Int(target.width))x\(Int(target.height))"
                return DynamicImageFilter(identifier) {
                    $0.af.imageAspectScaled(toFit: target, scale: 1)
                }
            case .aspectFill:
                let identifier =
                    "fovea-benchmark-fill-\(Int(target.width))x\(Int(target.height))"
                return DynamicImageFilter(identifier) {
                    $0.af.imageAspectScaled(toFill: target, scale: 1)
                }
            }
        #elseif canImport(AppKit)
            let identifier =
                "fovea-benchmark-macos-\(Int(target.width))x\(Int(target.height))"
            return DynamicImageFilter(identifier) { image in
                let output = NSImage(size: target)
                output.lockFocus()
                image.draw(
                    in: CGRect(origin: .zero, size: target),
                    from: .zero,
                    operation: .copy,
                    fraction: 1
                )
                output.unlockFocus()
                return output
            }
        #endif
    }

    private static func renderImage(_ image: Image) -> ComparatorRenderImage? {
        #if canImport(UIKit)
            guard let cgImage = image.cgImage else { return nil }
            return ComparatorRenderImage(cgImage: cgImage)
        #elseif canImport(AppKit)
            var rect = CGRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil).map(
                ComparatorRenderImage.init(cgImage:))
        #endif
    }

    private static func pixelDimensions(_ image: Image) -> (width: Int, height: Int) {
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
