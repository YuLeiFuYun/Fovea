import ComparativeLabCore
import Foundation
import Nuke

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

private final class NukeProgressiveTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancellationRequested = false

    func install(_ task: Task<Void, Never>) {
        let cancel = lock.withLock {
            self.task = task
            return cancellationRequested
        }
        if cancel { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            cancellationRequested = true
            return self.task
        }
        task?.cancel()
    }
}

public final class NukeComparatorAdapter: ComparatorProgressiveAdapter, @unchecked Sendable {
    public let identity: ComparatorIdentity
    public let runtimeConfiguration: ComparatorRuntimeConfiguration?

    private let pipeline: ImagePipeline
    private let dataCache: DataCache

    public init(
        cacheDirectory: URL,
        memoryCostLimit: Int = 128 * 1_024 * 1_024,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        maximumConcurrentDownloads: Int = 6,
        progressiveDecodingEnabled: Bool = false
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
        let boundedDownloads = max(1, maximumConcurrentDownloads)
        let boundedMemoryCost = max(1, memoryCostLimit)
        var configuration = ImagePipeline.Configuration()
        configuration.dataLoader = DataLoader(configuration: session)
        configuration.dataLoadingQueue.maxConcurrentOperationCount = boundedDownloads
        configuration.dataCache = dataCache
        configuration.dataCachePolicy = .storeOriginalData
        configuration.imageCache = ImageCache(costLimit: boundedMemoryCost)
        configuration.isProgressiveDecodingEnabled = progressiveDecodingEnabled
        configuration.progressiveDecodingInterval = 0
        runtimeConfiguration = try ComparatorRuntimeConfiguration(
            parameters: [
                "adapter.profile": "nuke-data-cache",
                "cache.data": "Nuke.DataCache",
                "cache.dataPolicy": "storeOriginalData",
                "cache.dataSizeLimitBytes": String(dataCache.sizeLimit),
                "cache.dataSweepEnabled": String(dataCache.isSweepEnabled),
                "cache.dataSweepIntervalSeconds": String(dataCache.sweepInterval),
                "cache.imageCostLimitBytes": String(boundedMemoryCost),
                "progressive.enabledAtInitialization": String(progressiveDecodingEnabled),
                "progressive.intervalSeconds": "0",
                "scheduler.maximumConcurrentDownloads": String(boundedDownloads),
                "session.base": "ephemeral",
                "session.cookies": "disabled",
                "session.credentials": "disabled",
                "session.httpMaximumConnectionsPerHost": String(
                    session.httpMaximumConnectionsPerHost
                ),
                "session.urlCache": "nil",
            ]
        )
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

    public func makeProgressiveLoad(
        _ request: ComparatorRequest
    ) async throws -> ComparatorProgressiveLoad {
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
        let imageTask = pipeline.imageTask(with: nukeRequest)
        let started = DispatchTime.now().uptimeNanoseconds
        let taskBox = NukeProgressiveTaskBox()
        let stream = AsyncThrowingStream<ComparatorProgressiveFrame, any Error> { continuation in
            let worker = Task {
                var sequence = 0
                var receivedBytes: Int?
                for await event in imageTask.events {
                    do {
                        switch event {
                        case .started:
                            continue
                        case .progress(let progress):
                            receivedBytes = max(0, Int(progress.completed))
                        case .preview(let response):
                            guard let image = Self.renderImage(response.image) else { continue }
                            let dimensions = Self.pixelDimensions(response.image)
                            continuation.yield(
                                ComparatorProgressiveFrame(
                                    measurement: try ComparatorProgressiveFrameMeasurement(
                                        sequence: sequence,
                                        kind: .preview,
                                        elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds
                                            &- started,
                                        receivedBytes: receivedBytes,
                                        pixelWidth: dimensions.width,
                                        pixelHeight: dimensions.height
                                    ),
                                    image: image
                                )
                            )
                            sequence += 1
                        case .finished(let result):
                            switch result {
                            case .success(let response):
                                guard let image = Self.renderImage(response.image) else {
                                    throw URLError(.cannotDecodeContentData)
                                }
                                let dimensions = Self.pixelDimensions(response.image)
                                continuation.yield(
                                    ComparatorProgressiveFrame(
                                        measurement: try ComparatorProgressiveFrameMeasurement(
                                            sequence: sequence,
                                            kind: .final,
                                            elapsedNanoseconds: DispatchTime.now()
                                                .uptimeNanoseconds &- started,
                                            receivedBytes: receivedBytes,
                                            pixelWidth: dimensions.width,
                                            pixelHeight: dimensions.height
                                        ),
                                        image: image
                                    )
                                )
                                continuation.finish()
                            case .failure(let error):
                                continuation.finish(throwing: error)
                            }
                            return
                        }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish()
            }
            taskBox.install(worker)
            continuation.onTermination = { @Sendable _ in
                taskBox.cancel()
                imageTask.cancel()
            }
        }
        return ComparatorProgressiveLoad(
            cancel: {
                taskBox.cancel()
                imageTask.cancel()
            },
            frames: stream
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
