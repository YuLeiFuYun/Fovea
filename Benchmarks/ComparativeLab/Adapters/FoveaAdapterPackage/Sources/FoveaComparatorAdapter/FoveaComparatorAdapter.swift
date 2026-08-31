import ComparativeLabCore
import CryptoKit
import Foundation
@_spi(FoveaBenchmarking) import FoveaCore
@_spi(FoveaBenchmarking) import FoveaHTTP
@_spi(FoveaBenchmarking) import FoveaSystem
import ImageCraftCore

private enum FoveaComparatorAdapterError: Error {
    case runtimeUnavailable
    case incompleteProgressiveStream
}

private protocol FoveaBenchmarkDiagnosticsAccess: DiagnosticsSink, Sendable {
    func snapshot() async -> [RecordedDiagnosticEvent]
    func setEnabled(_ enabled: Bool)
}

final class FoveaBenchmarkDiagnosticsSink:
    FoveaBenchmarkDiagnosticsAccess, @unchecked Sendable
{
    private let lock = NSLock()
    private let storage: BoundedDiagnosticsSink
    private var enabled = true

    init(capacity: Int) {
        storage = BoundedDiagnosticsSink(capacity: capacity)
    }

    func record(_ event: DiagnosticEvent) async {
        guard lock.withLock({ enabled }) else { return }
        await storage.record(event)
    }

    func snapshot() async -> [RecordedDiagnosticEvent] {
        await storage.snapshot()
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock { self.enabled = enabled }
    }
}

/// Lifecycle diagnostics need emit-site timestamps. The normal external-sink relay stamps events
/// only when its downstream consumer runs, so this benchmark-only SPI recorder uses a tiny locked
/// ring and records the monotonic clock at `record` entry. It is never selected for clean runs.
private final class FoveaLifecycleDiagnosticsSink:
    FoveaBenchmarkDiagnosticsAccess, InlineBenchmarkDiagnosticsSink, @unchecked Sendable
{
    private static let maximumCapacity = 65_536

    private let lock = NSLock()
    private let capacity: Int
    private let startedAtNanoseconds: UInt64
    private var storage: [RecordedDiagnosticEvent?]
    private var head = 0
    private var count = 0
    private var nextSequence: UInt64 = 0
    private var enabled = true

    init(capacity: Int) {
        let bounded = min(Self.maximumCapacity, max(1, capacity))
        self.capacity = bounded
        self.startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        self.storage = Array(repeating: nil, count: bounded)
    }

    func record(_ event: DiagnosticEvent) async {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.withLock {
            guard enabled else { return }
            let sequence = nextSequenceLocked()
            let recorded = RecordedDiagnosticEvent(
                sequence: sequence,
                elapsedNanoseconds: now &- startedAtNanoseconds,
                event: event
            )
            if count < capacity {
                storage[(head + count) % capacity] = recorded
                count += 1
            } else {
                storage[head] = recorded
                head = (head + 1) % capacity
            }
        }
    }

    func snapshot() async -> [RecordedDiagnosticEvent] {
        lock.withLock { snapshotLocked() }
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock { self.enabled = enabled }
    }

    private func nextSequenceLocked() -> UInt64 {
        if nextSequence == UInt64.max {
            let visible = snapshotLocked()
            storage = Array(repeating: nil, count: capacity)
            head = 0
            count = 0
            for (offset, item) in visible.enumerated() {
                storage[offset] = RecordedDiagnosticEvent(
                    sequence: UInt64(offset + 1),
                    elapsedNanoseconds: item.elapsedNanoseconds,
                    event: item.event
                )
                count += 1
            }
            nextSequence = UInt64(count)
        }
        nextSequence += 1
        return nextSequence
    }

    private func snapshotLocked() -> [RecordedDiagnosticEvent] {
        (0..<count).compactMap { storage[(head + $0) % capacity] }
    }
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

public actor FoveaComparatorAdapter: ComparatorProgressiveAdapter, ComparatorDiagnosticAdapter {
    public nonisolated let identity: ComparatorIdentity
    public nonisolated let runtimeConfiguration: ComparatorRuntimeConfiguration?

    private let cacheDirectory: URL
    private let configuration: PipelineConfiguration
    private let sessionConfiguration: URLSessionConfiguration
    private let transportReusePolicy: TransportReusePolicy
    private let derivedRasterConfiguration: FoveaDerivedRasterBenchmarkConfiguration?
    private let benchmarkDiagnostics: (any FoveaBenchmarkDiagnosticsAccess)?
    private let measurementDiagnosticsEnabled: Bool
    private var measurementDiagnosticBaselineSequence: UInt64 = 0
    private var system: FoveaSystemPipeline?
    private var derivedPreparationBaseline: FoveaDerivedRasterCreationActivitySnapshot?
    private var derivedPreparationStartActivity: FoveaDerivedRasterCreationActivitySnapshot?
    private var cachePreparationDiagnosticBaselineSequence: UInt64 = 0
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
        let measurementDiagnosticsEnabled =
            ProcessInfo.processInfo.environment["FOVEA_BENCHMARK_DIAGNOSTICS"] == "1"
        let benchmarkDiagnostics: (any FoveaBenchmarkDiagnosticsAccess)? =
            measurementDiagnosticsEnabled ? FoveaLifecycleDiagnosticsSink(capacity: 4_096) : nil
        let diagnostics: any DiagnosticsSink
        if let benchmarkDiagnostics {
            diagnostics = benchmarkDiagnostics
        } else {
            diagnostics = NullDiagnosticsSink()
        }
        self.identity = identity
        self.cacheDirectory = cacheDirectory
        self.configuration = configuration
        self.sessionConfiguration = sessionConfiguration
        self.transportReusePolicy = transportReusePolicy
        self.derivedRasterConfiguration = nil
        self.benchmarkDiagnostics = benchmarkDiagnostics
        self.measurementDiagnosticsEnabled = measurementDiagnosticsEnabled
        self.runtimeConfiguration = try Self.makeRuntimeConfiguration(
            configuration: configuration,
            sessionConfiguration: sessionConfiguration,
            transportReusePolicy: transportReusePolicy,
            derivedRasterConfiguration: nil,
            measurementDiagnosticsEnabled: measurementDiagnosticsEnabled
        )
        self.system = try await Self.openSystem(
            cacheDirectory: cacheDirectory,
            configuration: configuration,
            sessionConfiguration: sessionConfiguration,
            transportReusePolicy: transportReusePolicy,
            derivedRasterConfiguration: nil,
            diagnostics: diagnostics
        )
    }

    @_spi(FoveaBenchmarking)
    public init(
        cacheDirectory: URL,
        identity: ComparatorIdentity,
        configuration: PipelineConfiguration = PipelineConfiguration(),
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        transportReusePolicy: TransportReusePolicy = .taskLocal,
        derivedRasterConfiguration: FoveaDerivedRasterBenchmarkConfiguration
    ) async throws {
        guard identity.name == "Fovea" else {
            throw FoveaComparatorAdapterError.runtimeUnavailable
        }
        let measurementDiagnosticsEnabled =
            ProcessInfo.processInfo.environment["FOVEA_BENCHMARK_DIAGNOSTICS"] == "1"
        let benchmarkDiagnostics: any FoveaBenchmarkDiagnosticsAccess =
            measurementDiagnosticsEnabled
            ? FoveaLifecycleDiagnosticsSink(capacity: 4_096)
            : FoveaBenchmarkDiagnosticsSink(capacity: 4_096)
        self.identity = try Self.reportedIdentity(
            identity,
            derivedRasterConfiguration: derivedRasterConfiguration
        )
        self.cacheDirectory = cacheDirectory
        self.configuration = configuration
        self.sessionConfiguration = sessionConfiguration
        self.transportReusePolicy = transportReusePolicy
        self.derivedRasterConfiguration = derivedRasterConfiguration
        self.benchmarkDiagnostics = benchmarkDiagnostics
        self.measurementDiagnosticsEnabled = measurementDiagnosticsEnabled
        self.runtimeConfiguration = try Self.makeRuntimeConfiguration(
            configuration: configuration,
            sessionConfiguration: sessionConfiguration,
            transportReusePolicy: transportReusePolicy,
            derivedRasterConfiguration: derivedRasterConfiguration,
            measurementDiagnosticsEnabled: measurementDiagnosticsEnabled
        )
        self.system = try await Self.openSystem(
            cacheDirectory: cacheDirectory,
            configuration: configuration,
            sessionConfiguration: sessionConfiguration,
            transportReusePolicy: transportReusePolicy,
            derivedRasterConfiguration: derivedRasterConfiguration,
            diagnostics: benchmarkDiagnostics
        )
        if let system = self.system {
            let activity = await system.pipeline.derivedRasterCreationActivityForBenchmarking()
            self.derivedPreparationBaseline = activity
            self.derivedPreparationStartActivity = activity
        }
    }

    public func makeLoad(_ request: ComparatorRequest) async throws -> ComparatorLoad {
        guard let system else { throw FoveaComparatorAdapterError.runtimeUnavailable }
        let imageRequest = try makeImageRequest(request)
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
        let imageRequest = try makeImageRequest(request)
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
        await system.pipeline.purgeMemoryStateForBenchmarking()
    }

    public func purgeDisk() async throws {
        let previous = system
        system = nil
        preparationOrdinals.removeAll(keepingCapacity: true)
        await previous?.invalidateAndCancel()
        try await Self.removeDirectory(cacheDirectory)
        let diagnostics: any DiagnosticsSink
        if let benchmarkDiagnostics {
            benchmarkDiagnostics.setEnabled(true)
            diagnostics = benchmarkDiagnostics
            cachePreparationDiagnosticBaselineSequence =
                await benchmarkDiagnostics.snapshot().last?.sequence ?? 0
        } else {
            diagnostics = NullDiagnosticsSink()
            cachePreparationDiagnosticBaselineSequence = 0
        }
        system = try await Self.openSystem(
            cacheDirectory: cacheDirectory,
            configuration: configuration,
            sessionConfiguration: sessionConfiguration,
            transportReusePolicy: transportReusePolicy,
            derivedRasterConfiguration: derivedRasterConfiguration,
            diagnostics: diagnostics
        )
        if let system, derivedRasterConfiguration != nil {
            let activity = await system.pipeline.derivedRasterCreationActivityForBenchmarking()
            derivedPreparationBaseline = activity
            derivedPreparationStartActivity = activity
        } else {
            derivedPreparationBaseline = nil
            derivedPreparationStartActivity = nil
        }
    }

    public func finishCachePreparation() async throws {
        guard let system, let baseline = derivedPreparationBaseline else { return }
        derivedPreparationBaseline =
            await system.pipeline.waitForDerivedRasterCreationForBenchmarking(after: baseline)
    }

    public func cachePreparationDiagnostics() async -> [String: Int] {
        guard let benchmarkDiagnostics else { return [:] }
        // Cache-preparation diagnostics are evidence for the preparation phase only. Clean runs
        // freeze the sink before measured work so peer comparators do not pay Fovea-only tracing
        // overhead. Explicit diagnostic runs keep it enabled and establish a sequence baseline so
        // the later sidecar contains only measured-workload events.
        if !measurementDiagnosticsEnabled {
            benchmarkDiagnostics.setEnabled(false)
        }
        let events = await benchmarkDiagnostics.snapshot()
        measurementDiagnosticBaselineSequence = events.last?.sequence ?? 0
        var counts: [String: Int] = [:]
        for recorded in events {
            if recorded.sequence <= cachePreparationDiagnosticBaselineSequence { continue }
            switch recorded.event.kind {
            case .originalEncodedHit:
                counts["fovea-original-encoded-hit", default: 0] += 1
            case .renderedMemoryHit:
                counts["fovea-rendered-memory-hit", default: 0] += 1
            case .encodedHandoffHit:
                counts["fovea-memory-handoff-hit", default: 0] += 1
            default:
                break
            }
            if let reason = recorded.event.reason, reason.hasPrefix("derived-raster-") {
                counts[reason, default: 0] += 1
            }
        }
        counts["fovea-diagnostic-event-count"] =
            events.filter {
                $0.sequence > cachePreparationDiagnosticBaselineSequence
            }.count
        if let system, let start = derivedPreparationStartActivity {
            let current = await system.pipeline.derivedRasterCreationActivityForBenchmarking()
            counts["derived-raster-scheduled-count"] = Int(
                current.scheduledCount &- start.scheduledCount
            )
            counts["derived-raster-terminal-count"] = Int(
                current.terminalCount &- start.terminalCount
            )
            counts["derived-raster-active-count"] = current.activeCount
        }
        return counts
    }

    public func diagnosticEvents() async -> [ComparatorDiagnosticEvent] {
        guard measurementDiagnosticsEnabled, let benchmarkDiagnostics else { return [] }
        // Lifecycle diagnostics use the SPI inline recorder, so the snapshot is already complete
        // when workload timing stops. Re-correlate validated stable digests only now, outside the
        // measured path; no URL/header/pixel data can enter DiagnosticEvent in the first place.
        let correlationSalt = Data(UUID().uuidString.utf8)
        return await benchmarkDiagnostics.snapshot().compactMap { recorded in
            guard recorded.sequence > measurementDiagnosticBaselineSequence else { return nil }
            let event = recorded.event
            return ComparatorDiagnosticEvent(
                sequence: recorded.sequence,
                elapsedNanoseconds: recorded.elapsedNanoseconds,
                kind: event.kind.rawValue,
                keyDigest: event.keyDigest.map {
                    Self.benchmarkCorrelationDigest($0, salt: correlationSalt)
                },
                byteCount: event.byteCount,
                itemCount: event.itemCount,
                durationNanoseconds: event.durationNanoseconds,
                reason: event.reason,
                requestedPriority: event.requestedPriority?.rawValue,
                effectivePriority: event.effectivePriority?.rawValue
            )
        }
    }

    private nonisolated static func benchmarkCorrelationDigest(
        _ stableDigest: String,
        salt: Data
    ) -> String {
        var material = Data("fovea-benchmark-correlation-v1\u{0}".utf8)
        material.append(salt)
        material.append(0)
        material.append(contentsOf: stableDigest.utf8)
        let digest = SHA256.hash(data: material)
        let hex = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(hex[Int(byte >> 4)])
            bytes.append(hex[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
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

    /// `X-Benchmark-Request-ID` is harness telemetry, not image representation semantics.
    /// Keep it on the actual transport request so origin-side byte/cancellation accounting
    /// remains exact, while excluding it from Fovea's cache and single-flight identities.
    private func makeImageRequest(_ request: ComparatorRequest) throws -> ImageRequest {
        let benchmarkRequestIDHeader = "x-benchmark-request-id"
        var semanticHeaders = request.headers
        let benchmarkRequestID = semanticHeaders.removeValue(forKey: benchmarkRequestIDHeader)
        let credentialNames = semanticHeaders.keys.filter {
            $0 == "authorization" || $0 == "cookie"
        }.reduce(into: Set<String>()) { $0.insert($1) }
        let isAuthenticated = !credentialNames.isEmpty
        var imageRequest = try ImageRequest(
            url: request.url,
            target: TargetPixels(width: request.target.width, height: request.target.height),
            contentMode: request.contentMode == .aspectFit ? .fit : .fill,
            namespace: SecurityNamespaceID(request.securityNamespace),
            authorizationContext: isAuthenticated
                ? AuthorizationContextID("benchmark-auth-\(request.securityNamespace)") : .public,
            credentialGeneration: isAuthenticated ? CredentialGeneration(1) : nil,
            priority: priority(request.priority),
            headers: semanticHeaders,
            credentialHeaderNames: credentialNames
        )
        if let benchmarkRequestID {
            imageRequest = try imageRequest.withBenchmarkTransportHeaders([
                benchmarkRequestIDHeader: benchmarkRequestID
            ])
        }
        return imageRequest
    }

    private static func makeRuntimeConfiguration(
        configuration: PipelineConfiguration,
        sessionConfiguration: URLSessionConfiguration,
        transportReusePolicy: TransportReusePolicy,
        derivedRasterConfiguration: FoveaDerivedRasterBenchmarkConfiguration?,
        measurementDiagnosticsEnabled: Bool
    ) throws -> ComparatorRuntimeConfiguration {
        var parameters = [
            "adapter.profile": "fovea-system-pipeline",
            "diagnostics.measurementEnabled": String(measurementDiagnosticsEnabled),
            "pipeline.fullFingerprint": configuration.fullFingerprint,
            "pipeline.semanticFingerprint": configuration.semanticFingerprint,
            "pipeline.maximumConcurrentDecodes": String(configuration.maximumConcurrentDecodes),
            "pipeline.maximumConcurrentFetches": String(configuration.maximumConcurrentFetches),
            "pipeline.memoryCostLimitBytes": String(configuration.memoryCostLimit),
            "session.base": "ephemeral",
            "session.cookies": "disabled",
            "session.credentials": "disabled",
            "session.httpMaximumConnectionsPerHost": String(
                sessionConfiguration.httpMaximumConnectionsPerHost
            ),
            "session.urlCache": sessionConfiguration.urlCache == nil ? "nil" : "non-nil",
            "transport.allowsCrossRequestReuse": String(
                transportReusePolicy.allowsCrossRequestReuse
            ),
            "transport.executionFingerprint": transportReusePolicy.benchmarkingExecutionFingerprint,
        ]
        if let derivedRasterConfiguration {
            parameters["derivedRaster.profile"] = derivedRasterConfiguration.profileID
            parameters["derivedRaster.softTotalBytes"] = String(
                derivedRasterConfiguration.softTotalBytes
            )
            parameters["derivedRaster.maximumBlobBytes"] = String(
                derivedRasterConfiguration.maximumBlobBytes
            )
            parameters["derivedRaster.maximumWriteBytesPerWindow"] = String(
                derivedRasterConfiguration.maximumWriteBytesPerWindow
            )
            parameters["derivedRaster.writeBudgetWindowNanoseconds"] = String(
                derivedRasterConfiguration.writeBudgetWindowNanoseconds
            )
            parameters["derivedRaster.maximumContainerToOriginalPermille"] = String(
                derivedRasterConfiguration.maximumContainerToOriginalPermille
            )
            parameters["derivedRaster.maximumCreationNanoseconds"] = String(
                derivedRasterConfiguration.maximumCreationNanoseconds
            )
            parameters["derivedRaster.estimatedPersistentReadOverheadNanoseconds"] = String(
                derivedRasterConfiguration.estimatedPersistentReadOverheadNanoseconds
            )
            parameters["derivedRaster.safetyMarginHits"] = String(
                derivedRasterConfiguration.safetyMarginHits
            )
            parameters["derivedRaster.maximumConcurrentCreations"] = String(
                derivedRasterConfiguration.maximumConcurrentCreations
            )
            parameters["derivedRaster.maximumQueuedCreations"] = String(
                derivedRasterConfiguration.maximumQueuedCreations
            )
        } else {
            parameters["derivedRaster.profile"] = "off"
        }
        return try ComparatorRuntimeConfiguration(parameters: parameters)
    }

    private static func openSystem(
        cacheDirectory: URL,
        configuration: PipelineConfiguration,
        sessionConfiguration: URLSessionConfiguration,
        transportReusePolicy: TransportReusePolicy,
        derivedRasterConfiguration: FoveaDerivedRasterBenchmarkConfiguration?,
        diagnostics: any DiagnosticsSink
    ) async throws -> FoveaSystemPipeline {
        if let derivedRasterConfiguration {
            return try await FoveaSystemPipeline.openWithDerivedRasterForBenchmarking(
                cacheRoot: cacheDirectory,
                derivedRaster: derivedRasterConfiguration,
                configuration: configuration,
                diagnostics: diagnostics,
                profileAccessPolicy: .unrestricted,
                automaticallyPurgesMemoryOnPressure: false,
                sessionConfiguration: sessionConfiguration,
                transportReusePolicy: transportReusePolicy
            )
        }
        return try await FoveaSystemPipeline.open(
            cacheRoot: cacheDirectory,
            configuration: configuration,
            diagnostics: diagnostics,
            profileAccessPolicy: .unrestricted,
            automaticallyPurgesMemoryOnPressure: false,
            sessionConfiguration: sessionConfiguration,
            transportReusePolicy: transportReusePolicy
        )
    }

    private static func reportedIdentity(
        _ identity: ComparatorIdentity,
        derivedRasterConfiguration: FoveaDerivedRasterBenchmarkConfiguration?
    ) throws -> ComparatorIdentity {
        guard let derivedRasterConfiguration else { return identity }
        guard let exactCommit = identity.exactCommit else {
            throw FoveaComparatorAdapterError.runtimeUnavailable
        }
        return try ComparatorIdentity(
            name: identity.name,
            version: "\(identity.version)+\(derivedRasterConfiguration.profileID)",
            exactCommit: exactCommit,
            sourceTreeDigest: identity.sourceTreeDigest,
            includesWorkingTreeChanges: identity.includesWorkingTreeChanges
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

#if canImport(UIKit)
    import UIKit
    @_spi(BenchmarkDiagnostics) import FoveaUIKit

    private final class FoveaAnimatedEventState: @unchecked Sendable {
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
    private final class FoveaAnimatedPlayerController {
        private let window: UIWindow
        private let imageView: FoveaImageView
        private let frameDurationsNanoseconds: [UInt64]
        private let continuation: AsyncStream<ComparatorAnimatedPlayerFrameEvent>.Continuation
        private var stopped = false
        private var started = false

        init(
            frameDurationsNanoseconds: [UInt64],
            continuation: AsyncStream<ComparatorAnimatedPlayerFrameEvent>.Continuation,
            state: FoveaAnimatedEventState
        ) {
            let imageView = FoveaImageView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
            imageView.contentMode = .scaleAspectFit
            imageView.animationBenchmarkPresentationHandler = { frameIndex, timestamp in
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
                window.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
            } else {
                window = UIWindow(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
            }
            window.rootViewController = controller
            window.isHidden = true

            self.window = window
            self.imageView = imageView
            self.frameDurationsNanoseconds = frameDurationsNanoseconds
            self.continuation = continuation
        }

        func start() async throws {
            guard !stopped, !started else { return }
            started = true
            imageView.isHidden = false
            window.makeKeyAndVisible()
            try await imageView.startSyntheticAnimationPresentationBenchmark(
                frameDurationsNanoseconds: frameDurationsNanoseconds,
                providerDelayNanoseconds: 0,
                cadenceMode: .maximumRefresh
            )
        }

        func pause() {
            guard !stopped else { return }
            imageView.isHidden = true
        }

        func stop() {
            guard !stopped else { return }
            stopped = true
            imageView.animationBenchmarkPresentationHandler = nil
            imageView.cancelImageRequest(clearImage: true)
            window.isHidden = true
            window.rootViewController = nil
            continuation.finish()
        }

        isolated deinit {
            imageView.animationBenchmarkPresentationHandler = nil
            imageView.cancelImageRequest(clearImage: true)
            window.isHidden = true
            window.rootViewController = nil
            continuation.finish()
        }
    }

    extension FoveaComparatorAdapter: ComparatorAnimatedPlayerAdapter {
        @MainActor
        public func makeAnimatedPlayer(
            _ request: ComparatorAnimatedPlayerRequest
        ) throws -> ComparatorAnimatedPlayerSession {
            guard request.referenceFrameDurationsNanoseconds.count > 1 else {
                throw ComparativeLabError.invalidMeasurement
            }
            let pair = AsyncStream<ComparatorAnimatedPlayerFrameEvent>.makeStream(
                bufferingPolicy: .bufferingNewest(4_096)
            )
            let state = FoveaAnimatedEventState()
            let controller = FoveaAnimatedPlayerController(
                frameDurationsNanoseconds: request.referenceFrameDurationsNanoseconds,
                continuation: pair.continuation,
                state: state
            )
            pair.continuation.onTermination = { @Sendable _ in
                Task { @MainActor in controller.stop() }
            }
            return try ComparatorAnimatedPlayerSession(
                sourceFrameDurationsNanoseconds: request.referenceFrameDurationsNanoseconds,
                sourceLoopCount: request.referenceLoopCount,
                inputPath: .syntheticDecodedFrames,
                events: pair.stream,
                start: { try await controller.start() },
                pause: { controller.pause() },
                stop: { controller.stop() }
            )
        }
    }
#endif
