import ComparativeLabCore
import Foundation
@_spi(FoveaBenchmarking) import FoveaCore
import FoveaHTTP
import FoveaSystem
import ImageCraftCore

private enum FoveaComparatorAdapterError: Error {
    case runtimeUnavailable
    case incompleteProgressiveStream
}

private final class FoveaProgressiveTaskBox: @unchecked Sendable {
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

public actor FoveaComparatorAdapter: ComparatorProgressiveAdapter {
    public nonisolated let identity: ComparatorIdentity

    private let cacheDirectory: URL
    private let configuration: PipelineConfiguration
    private let sessionConfiguration: URLSessionConfiguration
    private let transportReusePolicy: TransportReusePolicy
    private var system: FoveaSystemPipeline?
    private var preparationOrdinals: [String: Int] = [:]

    public init(
        cacheDirectory: URL,
        identity: ComparatorIdentity,
        configuration: PipelineConfiguration = PipelineConfiguration(),
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        transportReusePolicy: TransportReusePolicy = .taskLocal
    ) async throws {
        guard identity.name == "Fovea" else {
            throw FoveaComparatorAdapterError.runtimeUnavailable
        }
        self.identity = identity
        self.cacheDirectory = cacheDirectory
        self.configuration = configuration
        self.sessionConfiguration = sessionConfiguration
        self.transportReusePolicy = transportReusePolicy
        self.system = try await Self.openSystem(
            cacheDirectory: cacheDirectory,
            configuration: configuration,
            sessionConfiguration: sessionConfiguration,
            transportReusePolicy: transportReusePolicy
        )
    }

    public func makeLoad(_ request: ComparatorRequest) async throws -> ComparatorLoad {
        guard let system else { throw FoveaComparatorAdapterError.runtimeUnavailable }
        let credentialNames = request.headers.keys.filter {
            $0 == "authorization" || $0 == "cookie"
        }.reduce(into: Set<String>()) { $0.insert($1) }
        let isAuthenticated = !credentialNames.isEmpty
        let imageRequest = try ImageRequest(
            url: request.url,
            target: TargetPixels(width: request.target.width, height: request.target.height),
            contentMode: request.contentMode == .aspectFit ? .fit : .fill,
            namespace: SecurityNamespaceID(request.securityNamespace),
            authorizationContext: isAuthenticated
                ? AuthorizationContextID("benchmark-auth-\(request.securityNamespace)") : .public,
            credentialGeneration: isAuthenticated ? CredentialGeneration(1) : nil,
            priority: priority(request.priority),
            headers: request.headers,
            credentialHeaderNames: credentialNames
        )
        let preparationKey = request.scopedCacheKey
        let preparationOrdinal = preparationOrdinals[preparationKey, default: 0] + 1
        preparationOrdinals[preparationKey] = preparationOrdinal
        let started = DispatchTime.now().uptimeNanoseconds
        // `events(for:)` 同步捕获顶层 admission。必须在 makeLoad 返回前创建 stream；
        // 若延迟到消费 Task 内，逻辑上同一并发 burst 的后续 load 可能在首个 fetch
        // 完成后才获得 admission，从而把 adapter 调度延迟误报为库的 single-flight 缺口。
        let events = system.pipeline.events(for: imageRequest)
        let task = Task<ComparatorLoadOutput, Never> {
            do {
                var firstFullQualityImage: DecodedImage?
                var firstFullQualityLatency: UInt64?
                for try await event in events {
                    switch event {
                    case .preview(let image, let quality):
                        guard quality == UInt16.max, firstFullQualityImage == nil else { continue }
                        firstFullQualityImage = image
                        firstFullQualityLatency =
                            DispatchTime.now().uptimeNanoseconds &- started
                    case .final(let finalImage):
                        let image = firstFullQualityImage ?? finalImage
                        let latency =
                            firstFullQualityLatency
                            ?? (DispatchTime.now().uptimeNanoseconds &- started)
                        let measurement = Self.makeResult(
                            outcome: .completed,
                            cacheSource: .unknown,
                            latencyNanoseconds: latency,
                            pixelWidth: image.pixelWidth,
                            pixelHeight: image.pixelHeight
                        )
                        return ComparatorLoadOutput(
                            measurement: measurement,
                            image: ComparatorRenderImage(cgImage: image.cgImage)
                        )
                    }
                }
                // AsyncThrowingStream may terminate without rethrowing after the consumer
                // cancels its iteration. Cancellation must win over the structural
                // "missing final" sentinel, otherwise W7 records every cancelled subscriber
                // as an unexpected load failure.
                try Task.checkCancellation()
                throw FoveaComparatorAdapterError.incompleteProgressiveStream
            } catch let failure as PipelineFailure {
                return ComparatorLoadOutput(
                    measurement: Self.makeResult(
                        outcome: failure.disposition == .cancelled ? .cancelled : .failed,
                        cacheSource: .unknown,
                        latencyNanoseconds: DispatchTime.now().uptimeNanoseconds &- started,
                        failureCategory: failure.disposition == .cancelled
                            ? nil : failure.category.rawValue
                    ),
                    image: nil
                )
            } catch is CancellationError {
                return ComparatorLoadOutput(
                    measurement: Self.makeResult(
                        outcome: .cancelled,
                        cacheSource: .unknown,
                        latencyNanoseconds: DispatchTime.now().uptimeNanoseconds &- started
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
        let pipeline = system.pipeline
        return ComparatorLoad(
            cancel: { task.cancel() },
            waitUntilPrepared: {
                let startedWaiting = DispatchTime.now().uptimeNanoseconds
                let (deadline, overflow) = startedWaiting.addingReportingOverflow(5_000_000_000)
                let boundedDeadline = overflow ? UInt64.max : deadline
                while await pipeline.fetchSubscriberCountForBenchmarking(imageRequest)
                    < preparationOrdinal
                {
                    try Task.checkCancellation()
                    guard DispatchTime.now().uptimeNanoseconds < boundedDeadline else {
                        throw FoveaComparatorAdapterError.runtimeUnavailable
                    }
                    await Task.yield()
                }
            },
            result: { await task.value }
        )
    }

    public func makeProgressiveLoad(
        _ request: ComparatorRequest
    ) async throws -> ComparatorProgressiveLoad {
        guard let system else { throw FoveaComparatorAdapterError.runtimeUnavailable }
        let credentialNames = request.headers.keys.filter {
            $0 == "authorization" || $0 == "cookie"
        }.reduce(into: Set<String>()) { $0.insert($1) }
        let isAuthenticated = !credentialNames.isEmpty
        let imageRequest = try ImageRequest(
            url: request.url,
            target: TargetPixels(width: request.target.width, height: request.target.height),
            contentMode: request.contentMode == .aspectFit ? .fit : .fill,
            namespace: SecurityNamespaceID(request.securityNamespace),
            authorizationContext: isAuthenticated
                ? AuthorizationContextID("benchmark-auth-\(request.securityNamespace)") : .public,
            credentialGeneration: isAuthenticated ? CredentialGeneration(1) : nil,
            priority: priority(request.priority),
            headers: request.headers,
            credentialHeaderNames: credentialNames
        )
        let started = DispatchTime.now().uptimeNanoseconds
        let source = system.pipeline.events(for: imageRequest)
        let taskBox = FoveaProgressiveTaskBox()
        let stream = AsyncThrowingStream<ComparatorProgressiveFrame, any Error> { continuation in
            let worker = Task {
                do {
                    var sequence = 0
                    for try await event in source {
                        let kind: ComparatorProgressiveFrameKind
                        let image: DecodedImage
                        switch event {
                        case .preview(let value, let quality):
                            guard quality < UInt16.max else { continue }
                            kind = .preview
                            image = value
                        case .final(let value):
                            kind = .final
                            image = value
                        }
                        let measurement = try ComparatorProgressiveFrameMeasurement(
                            sequence: sequence,
                            kind: kind,
                            elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds &- started,
                            pixelWidth: image.pixelWidth,
                            pixelHeight: image.pixelHeight
                        )
                        sequence += 1
                        continuation.yield(
                            ComparatorProgressiveFrame(
                                measurement: measurement,
                                image: ComparatorRenderImage(cgImage: image.cgImage)
                            )
                        )
                        if kind == .final {
                            continuation.finish()
                            return
                        }
                    }
                    try Task.checkCancellation()
                    throw FoveaComparatorAdapterError.incompleteProgressiveStream
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            taskBox.install(worker)
            continuation.onTermination = { @Sendable _ in taskBox.cancel() }
        }
        return ComparatorProgressiveLoad(cancel: { taskBox.cancel() }, frames: stream)
    }

    public func purgeMemory() async {
        guard let system else { return }
        _ = await system.pipeline.purgeMemoryCache()
    }

    public func purgeDisk() async throws {
        let previous = system
        system = nil
        preparationOrdinals.removeAll(keepingCapacity: true)
        await previous?.invalidateAndCancel()
        try await Self.removeDirectory(cacheDirectory)
        system = try await Self.openSystem(
            cacheDirectory: cacheDirectory,
            configuration: configuration,
            sessionConfiguration: sessionConfiguration,
            transportReusePolicy: transportReusePolicy
        )
    }

    public func revoke(namespace: String) async throws {
        guard let system else { throw FoveaComparatorAdapterError.runtimeUnavailable }
        try await system.pipeline.revoke(namespace: SecurityNamespaceID(namespace))
    }

    public func cancelAll() async {
        guard let previous = system else { return }
        system = nil
        preparationOrdinals.removeAll(keepingCapacity: true)
        await previous.invalidateAndCancel()
    }

    private func priority(_ value: ComparatorPriority) -> ImageRequestPriority {
        switch value {
        case .background: .background
        case .utility: .low
        case .visible: .high
        case .immediate: .userInitiated
        }
    }

    private static func openSystem(
        cacheDirectory: URL,
        configuration: PipelineConfiguration,
        sessionConfiguration: URLSessionConfiguration,
        transportReusePolicy: TransportReusePolicy
    ) async throws -> FoveaSystemPipeline {
        try await FoveaSystemPipeline.open(
            cacheRoot: cacheDirectory,
            configuration: configuration,
            profileAccessPolicy: .unrestricted,
            automaticallyPurgesMemoryOnPressure: false,
            sessionConfiguration: sessionConfiguration,
            transportReusePolicy: transportReusePolicy
        )
    }

    private static func removeDirectory(_ directory: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    if FileManager.default.fileExists(atPath: directory.path) {
                        try FileManager.default.removeItem(at: directory)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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
}
