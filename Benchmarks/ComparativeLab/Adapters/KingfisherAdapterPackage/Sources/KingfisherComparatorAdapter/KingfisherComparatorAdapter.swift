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

public final class KingfisherComparatorAdapter: ComparatorAdapter, @unchecked Sendable {
    public let identity: ComparatorIdentity

    private let cache: ImageCache
    private let downloader: ImageDownloader
    private let manager: KingfisherManager

    public init(
        cacheDirectory: URL,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
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
        downloader = ImageDownloader(name: "fovea-comparative-kingfisher")
        let session = sessionConfiguration.copy() as! URLSessionConfiguration
        session.urlCache = nil
        session.httpCookieStorage = nil
        session.urlCredentialStorage = nil
        session.httpShouldSetCookies = false
        downloader.sessionConfiguration = session
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
