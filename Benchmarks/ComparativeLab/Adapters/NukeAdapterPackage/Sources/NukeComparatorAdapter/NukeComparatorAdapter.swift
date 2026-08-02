import ComparativeLabCore
import Foundation
import Nuke

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

public final class NukeComparatorAdapter: ComparatorAdapter, @unchecked Sendable {
    public let identity: ComparatorIdentity

    private let pipeline: ImagePipeline
    private let dataCache: DataCache

    public init(
        cacheDirectory: URL,
        memoryCostLimit: Int = 128 * 1_024 * 1_024,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        maximumConcurrentDownloads: Int = 6
    ) throws {
        identity = try ComparatorIdentity(
            name: "Nuke",
            version: "13.0.6",
            exactCommit: "63a8fcbd6621340a2410bc3e9575ac97058615f4"
        )
        let dataCache = try DataCache(path: cacheDirectory)
        self.dataCache = dataCache

        let session = sessionConfiguration.copy() as! URLSessionConfiguration
        session.urlCache = nil
        session.httpCookieStorage = nil
        session.urlCredentialStorage = nil
        session.httpShouldSetCookies = false
        var configuration = ImagePipeline.Configuration()
        configuration.dataLoader = DataLoader(configuration: session)
        configuration.dataLoadingQueue.maxConcurrentOperationCount = max(
            1, maximumConcurrentDownloads
        )
        configuration.dataCache = dataCache
        configuration.dataCachePolicy = .storeOriginalData
        configuration.imageCache = ImageCache(costLimit: max(1, memoryCostLimit))
        configuration.isProgressiveDecodingEnabled = false
        pipeline = ImagePipeline(configuration: configuration)
    }

    public func makeLoad(_ request: ComparatorRequest) async throws -> ComparatorLoad {
        let contentMode: ImageProcessingOptions.ContentMode =
            request.contentMode == .aspectFit ? .aspectFit : .aspectFill
        var urlRequest = URLRequest(url: request.url)
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        var nukeRequest = ImageRequest(
            urlRequest: urlRequest,
            priority: priority(request.priority)
        )
        nukeRequest.imageID = request.scopedCacheKey
        let targetSize = CGSize(width: request.target.width, height: request.target.height)
        nukeRequest.thumbnail = ImageRequest.ThumbnailOptions(
            size: targetSize,
            unit: .pixels,
            contentMode: contentMode
        )
        if request.contentMode == .aspectFill {
            nukeRequest.processors = [
                ImageProcessors.Resize(
                    size: targetSize,
                    unit: .pixels,
                    contentMode: .aspectFill,
                    crop: true
                )
            ]
        }
        let task = pipeline.imageTask(with: nukeRequest)
        let started = DispatchTime.now().uptimeNanoseconds

        return ComparatorLoad(
            cancel: { task.cancel() },
            result: {
                do {
                    let response = try await task.response
                    let dimensions = Self.pixelDimensions(response.image)
                    let measurement = Self.makeResult(
                        outcome: .completed,
                        cacheSource: Self.cacheSource(response.cacheType),
                        latencyNanoseconds: DispatchTime.now().uptimeNanoseconds &- started,
                        pixelWidth: dimensions.width,
                        pixelHeight: dimensions.height
                    )
                    return ComparatorLoadOutput(
                        measurement: measurement,
                        image: Self.renderImage(response.image)
                    )
                } catch let error as ImagePipeline.Error {
                    let cancelled: Bool
                    if case .cancelled = error { cancelled = true } else { cancelled = false }
                    return ComparatorLoadOutput(
                        measurement: Self.makeResult(
                            outcome: cancelled ? .cancelled : .failed,
                            cacheSource: .unknown,
                            latencyNanoseconds: DispatchTime.now().uptimeNanoseconds &- started,
                            failureCategory: cancelled ? nil : Self.failureCategory(error)
                        ),
                        image: nil
                    )
                } catch {
                    return ComparatorLoadOutput(
                        measurement: Self.makeResult(
                            outcome: .failed,
                            cacheSource: .unknown,
                            latencyNanoseconds: DispatchTime.now().uptimeNanoseconds &- started,
                            failureCategory: "unexpected"
                        ),
                        image: nil
                    )
                }
            }
        )
    }

    public func purgeMemory() async {
        pipeline.cache.removeAll(caches: .memory)
    }

    public func purgeDisk() async throws {
        pipeline.cache.removeAll(caches: .disk)
        dataCache.flush()
    }

    public func revoke(namespace: String) async throws {
        // Nuke has no namespace primitive. The adapter composes namespace into imageID and
        // conservatively clears both cache layers at logout to prevent cross-account residue.
        pipeline.cache.removeAll(caches: .all)
        dataCache.flush()
    }

    public func cancelAll() async {
        pipeline.invalidate()
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

    private func priority(_ value: ComparatorPriority) -> ImageRequest.Priority {
        switch value {
        case .background: .veryLow
        case .utility: .low
        case .visible: .high
        case .immediate: .veryHigh
        }
    }

    private static func cacheSource(_ value: ImageResponse.CacheType?) -> ComparatorCacheSource {
        switch value {
        case .memory: .memory
        case .disk: .disk
        case nil: .network
        }
    }

    private static func failureCategory(_ error: ImagePipeline.Error) -> String {
        switch error {
        case .dataMissingInCache: "cache-miss"
        case .dataLoadingFailed, .dataIsEmpty, .dataDownloadExceededMaximumSize: "transport"
        case .decoderNotRegistered, .decodingFailed: "decode"
        case .processingFailed: "processing"
        case .imageRequestMissing: "request"
        case .pipelineInvalidated: "lifecycle"
        case .cancelled: "cancelled"
        }
    }

    private static func renderImage(_ image: PlatformImage) -> ComparatorRenderImage? {
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

    private static func pixelDimensions(_ image: PlatformImage) -> (width: Int, height: Int) {
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
