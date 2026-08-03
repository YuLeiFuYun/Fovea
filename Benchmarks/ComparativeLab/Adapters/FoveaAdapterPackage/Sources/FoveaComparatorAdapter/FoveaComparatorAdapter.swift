import ComparativeLabCore
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaSystem
import ImageCraftCore

private enum FoveaComparatorAdapterError: Error {
    case runtimeUnavailable
    case incompleteProgressiveStream
}

public actor FoveaComparatorAdapter: ComparatorAdapter {
    public nonisolated let identity: ComparatorIdentity

    private let cacheDirectory: URL
    private let configuration: PipelineConfiguration
    private let sessionConfiguration: URLSessionConfiguration
    private let transportReusePolicy: TransportReusePolicy
    private var system: FoveaSystemPipeline?

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
            logicalSource: LogicalSourceID(request.resourceID),
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
        let task = Task<ComparatorLoadOutput, Never> {
            do {
                var firstFullQualityImage: DecodedImage?
                var firstFullQualityLatency: UInt64?
                for try await event in system.pipeline.events(for: imageRequest) {
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
        return ComparatorLoad(
            cancel: { task.cancel() },
            result: { await task.value }
        )
    }

    public func purgeMemory() async {
        guard let system else { return }
        _ = await system.pipeline.purgeMemoryCache()
    }

    public func purgeDisk() async throws {
        let previous = system
        system = nil
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
