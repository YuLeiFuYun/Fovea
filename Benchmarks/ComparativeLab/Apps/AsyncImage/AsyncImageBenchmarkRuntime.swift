import ComparativeLabCore
import Foundation
import SwiftUI
import UIKit

#if FOVEA_SWIFTUI_SURFACE
    @_spi(BenchmarkDiagnostics) import FoveaCore
    import FoveaHTTP
    import FoveaSystem
    import ImageCraftCore
#endif

enum SwiftUISurfaceDescriptor {
    #if FOVEA_SWIFTUI_SURFACE
        static let comparatorName = "Fovea"
        static let bundleRole = "fovea-swiftui"
    #else
        static let comparatorName = "Apple AsyncImage"
        static let bundleRole = "apple-asyncimage"
    #endif
}

struct AsyncImageBenchmarkArguments: Sendable {
    let workloadID: String
    let networkProfile: BenchmarkNetworkProfile
    let runIndex: Int
    let orderPosition: Int
    let runNonce: String
    let timeScale: Double
    let outputName: String

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), index + 1 < arguments.count else {
                throw BenchmarkAppError.invalidArguments
            }
            values[String(arguments[index].dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        let allowed = [
            "W1-SCROLL-V1", "W2-HERO-V1", "W10-SWIFTUI-IDENTITY-CHURN-V1",
        ]
        guard let workloadID = values["workload"], allowed.contains(workloadID),
            let profileRaw = values["network-profile"],
            let networkProfile = BenchmarkNetworkProfile(rawValue: profileRaw),
            let runRaw = values["run-index"], let runIndex = Int(runRaw), runIndex >= 0,
            let orderRaw = values["order-position"], let orderPosition = Int(orderRaw),
            0...1 ~= orderPosition,
            let runNonce = values["run-nonce"], runNonce.count == 32,
            runNonce.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else {
            throw BenchmarkAppError.invalidArguments
        }
        let timeScale = Double(values["time-scale"] ?? "1") ?? 1
        guard timeScale > 0, timeScale <= 1 else { throw BenchmarkAppError.invalidArguments }
        let outputName = values["output"] ?? "asyncimage-result.json"
        guard outputName.hasSuffix(".json"), !outputName.contains("/") else {
            throw BenchmarkAppError.invalidArguments
        }
        self.workloadID = workloadID
        self.networkProfile = networkProfile
        self.runIndex = runIndex
        self.orderPosition = orderPosition
        self.runNonce = runNonce
        self.timeScale = timeScale
        self.outputName = outputName
    }
}

actor AsyncImagePhaseRecorder {
    struct Snapshot: Sendable {
        let requestedCount: Int
        let successCount: Int
        let terminalCount: Int
        let terminalWithoutVisibleCount: Int
        let failureCount: Int
        let disappearanceCount: Int
        let staleSuccessCount: Int
        let successLatenciesNanoseconds: [UInt64]
        let terminalLatenciesNanoseconds: [UInt64]
    }

    private let tracksGenerationStaleness: Bool
    private var starts: [String: UInt64] = [:]
    private var activeTokens: Set<String> = []
    private var visibleTokens: Set<String> = []
    private var finalTokens: Set<String> = []
    private var failureTokens: Set<String> = []
    private var requestedCount = 0
    private var successCount = 0
    private var terminalCount = 0
    private var terminalWithoutVisibleCount = 0
    private var failureCount = 0
    private var disappearanceCount = 0
    private var staleSuccessCount = 0
    private var currentGeneration = 0
    private var successLatenciesNanoseconds: [UInt64] = []
    private var terminalLatenciesNanoseconds: [UInt64] = []

    init(tracksGenerationStaleness: Bool) {
        self.tracksGenerationStaleness = tracksGenerationStaleness
    }

    func setCurrentGeneration(_ generation: Int) {
        currentGeneration = generation
    }

    func appeared(token: String) {
        activeTokens.insert(token)
        if starts[token] == nil {
            starts[token] = DispatchTime.now().uptimeNanoseconds
            requestedCount += 1
        }
    }

    func disappeared(token: String) {
        activeTokens.remove(token)
        if starts[token] != nil,
            !finalTokens.contains(token),
            !failureTokens.contains(token)
        {
            disappearanceCount += 1
        }
    }

    func succeeded(token: String, generation: Int) {
        guard activeTokens.contains(token), visibleTokens.insert(token).inserted else { return }
        successCount += 1
        if tracksGenerationStaleness, generation < currentGeneration {
            staleSuccessCount += 1
        }
        if let started = starts[token] {
            successLatenciesNanoseconds.append(
                DispatchTime.now().uptimeNanoseconds &- started
            )
        }
    }

    func finalized(token: String, generation: Int) {
        guard activeTokens.contains(token) else { return }
        succeeded(token: token, generation: generation)
        guard visibleTokens.contains(token) else {
            terminalWithoutVisibleCount += 1
            return
        }
        guard finalTokens.insert(token).inserted else { return }
        terminalCount += 1
        if let started = starts[token] {
            terminalLatenciesNanoseconds.append(
                DispatchTime.now().uptimeNanoseconds &- started
            )
        }
    }

    func failed(token: String) {
        guard activeTokens.contains(token), failureTokens.insert(token).inserted else { return }
        failureCount += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(
            requestedCount: requestedCount,
            successCount: successCount,
            terminalCount: terminalCount,
            terminalWithoutVisibleCount: terminalWithoutVisibleCount,
            failureCount: failureCount,
            disappearanceCount: disappearanceCount,
            staleSuccessCount: staleSuccessCount,
            successLatenciesNanoseconds: successLatenciesNanoseconds,
            terminalLatenciesNanoseconds: terminalLatenciesNanoseconds
        )
    }
}

@MainActor
final class AsyncImageBenchmarkModel: ObservableObject {
    @Published var feedTarget = 0
    @Published var feedGeneration = 0
    @Published var heroName = "hero-12mp-4000x3000.jpg"
    @Published var heroGeneration = 0
    @Published var identityAssetIndex = 0
    @Published var identityGeneration = 0
    @Published var isArmed = false

    let catalog: ResourceCatalog
    let recorder: AsyncImagePhaseRecorder
    let originBaseURL: URL
    let runNonce: String
    #if FOVEA_SWIFTUI_SURFACE
        let foveaLoader: any ImageLoading
        let foveaRequestPrototypes: [URL: ImageRequest]
    #endif

    #if FOVEA_SWIFTUI_SURFACE
        init(
            catalog: ResourceCatalog,
            recorder: AsyncImagePhaseRecorder,
            originBaseURL: URL,
            runNonce: String,
            foveaLoader: any ImageLoading,
            foveaRequestPrototypes: [URL: ImageRequest]
        ) {
            self.catalog = catalog
            self.recorder = recorder
            self.originBaseURL = originBaseURL
            self.runNonce = runNonce
            self.foveaLoader = foveaLoader
            self.foveaRequestPrototypes = foveaRequestPrototypes
        }
    #else
        init(
            catalog: ResourceCatalog,
            recorder: AsyncImagePhaseRecorder,
            originBaseURL: URL,
            runNonce: String
        ) {
            self.catalog = catalog
            self.recorder = recorder
            self.originBaseURL = originBaseURL
            self.runNonce = runNonce
        }
    #endif

    func assetURL(logicalIndex: Int) -> URL {
        let asset = catalog.dataset.assets[logicalIndex % catalog.dataset.assets.count]
        return benchmarkURL(path: "/asset/\(asset.assetID)")
    }

    #if FOVEA_SWIFTUI_SURFACE
        func foveaRequest(
            url: URL,
            target: ResolvedImageTarget
        ) throws -> ImageRequest {
            guard let prototype = foveaRequestPrototypes[url] else {
                throw BenchmarkAppError.runFailed("missing-fovea-request-prototype")
            }
            return try prototype.retargeted(to: target)
        }
    #endif

    func heroURL() -> URL {
        benchmarkURL(path: "/hero/\(heroName)")
    }

    func identityURL() -> URL {
        assetURL(logicalIndex: identityAssetIndex)
    }

    private func benchmarkURL(path: String) -> URL {
        let base = originBaseURL.appendingPathComponent(String(path.dropFirst()))
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        components.queryItems = [URLQueryItem(name: "run", value: runNonce)]
        return components.url ?? base
    }
}

struct AsyncImageMeasurements: Codable, Sendable {
    let requestedCount: Int
    let successCount: Int
    let terminalCount: Int
    let terminalWithoutVisibleCount: Int
    let failureCount: Int
    let disappearanceCount: Int
    let staleSuccessCount: Int
    let medianSuccessLatencyNanoseconds: UInt64?
    let p95SuccessLatencyNanoseconds: UInt64?
    let medianTerminalLatencyNanoseconds: UInt64?
    let p95TerminalLatencyNanoseconds: UInt64?
}

struct AsyncImageRunEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let planID: String
    let comparator: ComparatorIdentity
    let harnessIdentity: BenchmarkHarnessIdentity
    let experimentPlanDigest: String
    let applicabilityDigest: String
    let claimFamilyDigest: String
    let environment: ComparatorRunEnvironment
    let workloadID: String
    let networkProfile: BenchmarkNetworkProfile
    let runIndex: Int
    let orderPosition: Int
    let runNonce: String
    let timeScale: Double
    let datasetDigest: String
    let executionEnvironment: String
    let provisional: Bool
    let measurements: AsyncImageMeasurements
    let processMetrics: BenchmarkProcessMetrics
    let thermal: BenchmarkThermalSnapshot
    let originMetrics: BenchmarkOriginMetrics
    let checks: [BenchmarkCheck]
    let limitations: [String]
}

final class AsyncImageThermalMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let initialState: ProcessInfo.ThermalState
    private var currentState: ProcessInfo.ThermalState
    private var remainedNominal: Bool
    private var observer: NSObjectProtocol?

    init(processInfo: ProcessInfo = .processInfo) {
        let state = processInfo.thermalState
        initialState = state
        currentState = state
        remainedNominal = state == .nominal
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: processInfo,
            queue: nil
        ) { [weak self, weak processInfo] _ in
            guard let self, let processInfo else { return }
            self.record(processInfo.thermalState)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func snapshotAndStop(processInfo: ProcessInfo = .processInfo) -> BenchmarkThermalSnapshot {
        record(processInfo.thermalState)
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        lock.lock()
        defer { lock.unlock() }
        return BenchmarkThermalSnapshot(
            stateAtStart: Self.name(initialState),
            stateAtEnd: Self.name(currentState),
            remainedNominal: remainedNominal && currentState == .nominal
        )
    }

    private func record(_ state: ProcessInfo.ThermalState) {
        lock.lock()
        currentState = state
        if state != .nominal { remainedNominal = false }
        lock.unlock()
    }

    private static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

#if FOVEA_SWIFTUI_SURFACE
    private final class AsyncImageDiagnosticPhaseTracker: @unchecked Sendable {
        struct Snapshot: Sendable {
            let phase: String
            let generation: Int
        }

        private let lock = NSLock()
        private var phase = "pre-arm"
        private var generation = -1

        func update(phase: String, generation: Int? = nil) {
            lock.lock()
            self.phase = phase
            if let generation { self.generation = generation }
            lock.unlock()
        }

        func snapshot() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return Snapshot(phase: phase, generation: generation)
        }
    }

    private struct AsyncImageDiagnosticTimelineSample: Codable, Sendable {
        let elapsedNanoseconds: UInt64
        let physicalFootprintBytes: UInt64?
        let phase: String
        let generation: Int
        let requestedCount: Int
        let successCount: Int
        let terminalCount: Int
        let disappearanceCount: Int
        let transientHandoffCount: Int
        let transientHandoffBytes: Int
        let adaptiveWarmupCount: Int
        let inFlightHandoffPreparationCount: Int
        let inFlightHandoffPreparationBytes: Int
    }

    private struct AsyncImageDiagnosticTimelineEnvelope: Codable, Sendable {
        let schemaVersion: Int
        let samplingIntervalNanoseconds: UInt64
        let samples: [AsyncImageDiagnosticTimelineSample]
    }

    private final class AsyncImageDiagnosticTimeline: @unchecked Sendable {
        private static let samplingIntervalNanoseconds: UInt64 = 10_000_000
        private let pipeline: FoveaPipeline
        private let recorder: AsyncImagePhaseRecorder
        private let phaseTracker: AsyncImageDiagnosticPhaseTracker
        private let lock = NSLock()
        private var samples: [AsyncImageDiagnosticTimelineSample] = []
        private var worker: Task<Void, Never>?

        init(
            pipeline: FoveaPipeline,
            recorder: AsyncImagePhaseRecorder,
            phaseTracker: AsyncImageDiagnosticPhaseTracker
        ) {
            self.pipeline = pipeline
            self.recorder = recorder
            self.phaseTracker = phaseTracker
        }

        func start(at startedAtNanoseconds: UInt64) {
            worker = Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    let physical = PhysicalFootprintSampler.current()
                    let pipeline = await self.pipeline.benchmarkDiagnosticsSnapshot()
                    let recorder = await self.recorder.snapshot()
                    let phase = self.phaseTracker.snapshot()
                    let sample = AsyncImageDiagnosticTimelineSample(
                        elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds
                            &- startedAtNanoseconds,
                        physicalFootprintBytes: physical,
                        phase: phase.phase,
                        generation: phase.generation,
                        requestedCount: recorder.requestedCount,
                        successCount: recorder.successCount,
                        terminalCount: recorder.terminalCount,
                        disappearanceCount: recorder.disappearanceCount,
                        transientHandoffCount: pipeline.transientHandoffCount,
                        transientHandoffBytes: pipeline.transientHandoffBytes,
                        adaptiveWarmupCount: pipeline.adaptiveWarmupCount,
                        inFlightHandoffPreparationCount:
                            pipeline.inFlightHandoffPreparationCount,
                        inFlightHandoffPreparationBytes:
                            pipeline.inFlightHandoffPreparationBytes
                    )
                    self.lock.withLock { self.samples.append(sample) }
                    try? await Task.sleep(nanoseconds: Self.samplingIntervalNanoseconds)
                }
            }
        }

        func stop() async -> AsyncImageDiagnosticTimelineEnvelope {
            worker?.cancel()
            if let worker { await worker.value }
            worker = nil
            let snapshot = lock.withLock { samples }
            return AsyncImageDiagnosticTimelineEnvelope(
                schemaVersion: 1,
                samplingIntervalNanoseconds: Self.samplingIntervalNanoseconds,
                samples: snapshot
            )
        }
    }
#endif

@MainActor
enum AsyncImageBenchmarkCoordinator {
    static func run(arguments: AsyncImageBenchmarkArguments, window: UIWindow) async throws {
        let catalog = try ResourceCatalog.load()
        let origin = try LoopbackBenchmarkOriginServer(
            catalog: catalog,
            profile: arguments.networkProfile
        )
        let originBaseURL = try await origin.start()
        defer { origin.stop() }
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)

        let recorder = AsyncImagePhaseRecorder(
            tracksGenerationStaleness: arguments.workloadID != "W1-SCROLL-V1"
        )
        #if FOVEA_SWIFTUI_SURFACE
            let foveaCacheRoot = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("FoveaSwiftUISurface", isDirectory: true)
                .appendingPathComponent(arguments.runNonce, isDirectory: true)
            if FileManager.default.fileExists(atPath: foveaCacheRoot.path) {
                try FileManager.default.removeItem(at: foveaCacheRoot)
            }
            let benchmarkDiagnostics: BoundedDiagnosticsSink? =
                ProcessInfo.processInfo.environment["FOVEA_BENCHMARK_DIAGNOSTICS"] == "1"
                ? BoundedDiagnosticsSink(capacity: 4_096)
                : nil
            let diagnosticsSink: any DiagnosticsSink
            if let benchmarkDiagnostics {
                diagnosticsSink = benchmarkDiagnostics
            } else {
                diagnosticsSink = NullDiagnosticsSink()
            }
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.urlCache = nil
            sessionConfiguration.httpCookieStorage = nil
            sessionConfiguration.urlCredentialStorage = nil
            sessionConfiguration.httpShouldSetCookies = false
            let foveaSystem = try await FoveaSystemPipeline.open(
                cacheRoot: foveaCacheRoot,
                configuration: PipelineConfiguration(
                    maximumConcurrentFetches: 8,
                    maximumConcurrentDecodes: 2
                ),
                diagnostics: diagnosticsSink,
                automaticallyPurgesMemoryOnPressure: false,
                sessionConfiguration: sessionConfiguration,
                transportReusePolicy: .reusable(
                    contextIdentifier: "fovea-swiftui-surface-v5:\(arguments.runNonce)"
                )
            )
            let prototypeTarget = try TargetPixels(width: 1, height: 1)
            let requestURL: (String) -> URL = { path in
                let base = originBaseURL.appendingPathComponent(path)
                guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
                else {
                    return base
                }
                components.queryItems = [URLQueryItem(name: "run", value: arguments.runNonce)]
                return components.url ?? base
            }
            var foveaRequestPrototypes: [URL: ImageRequest] = [:]
            for asset in catalog.dataset.assets {
                let url = requestURL("asset/\(asset.assetID)")
                foveaRequestPrototypes[url] = try ImageRequest.publicImage(
                    url: url,
                    logicalSource: LogicalSourceID("asset:\(asset.assetID)"),
                    target: prototypeTarget,
                    appID: "dev.fovea.comparative.swiftui-surface"
                )
            }
            for name in [
                "hero-12mp-4000x3000.jpg",
                "hero-24mp-6000x4000.jpg",
                "hero-48mp-8000x6000.jpg",
            ] {
                let url = requestURL("hero/\(name)")
                foveaRequestPrototypes[url] = try ImageRequest.publicImage(
                    url: url,
                    logicalSource: LogicalSourceID("hero:\(name)"),
                    target: prototypeTarget,
                    appID: "dev.fovea.comparative.swiftui-surface"
                )
            }
            let foveaLoader: any ImageLoading = foveaSystem.pipeline
            let model = AsyncImageBenchmarkModel(
                catalog: catalog,
                recorder: recorder,
                originBaseURL: originBaseURL,
                runNonce: arguments.runNonce,
                foveaLoader: foveaLoader,
                foveaRequestPrototypes: foveaRequestPrototypes
            )
        #else
            let model = AsyncImageBenchmarkModel(
                catalog: catalog,
                recorder: recorder,
                originBaseURL: originBaseURL,
                runNonce: arguments.runNonce
            )
        #endif
        let root = AsyncImageBenchmarkRootView(
            workloadID: arguments.workloadID,
            model: model
        )
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        await DisplayFrameBarrier(frameCount: 3).wait()

        #if FOVEA_SWIFTUI_SURFACE
            let phaseTracker = AsyncImageDiagnosticPhaseTracker()
            let timeline: AsyncImageDiagnosticTimeline? =
                ProcessInfo.processInfo.environment["FOVEA_BENCHMARK_TIMELINE"] == "1"
                ? AsyncImageDiagnosticTimeline(
                    pipeline: foveaSystem.pipeline,
                    recorder: recorder,
                    phaseTracker: phaseTracker
                )
                : nil
        #endif
        let footprint = PhysicalFootprintSampler()
        let frames = FrameHitchSampler()
        let thermal = AsyncImageThermalMonitor()
        footprint.start()
        frames.start()
        let started = DispatchTime.now().uptimeNanoseconds
        #if FOVEA_SWIFTUI_SURFACE
            phaseTracker.update(phase: "armed")
            timeline?.start(at: started)
        #endif
        model.isArmed = true
        await Task.yield()

        switch arguments.workloadID {
        case "W1-SCROLL-V1":
            try await runFeed(model: model, timeScale: arguments.timeScale)
        case "W2-HERO-V1":
            try await runHeroes(model: model)
        case "W10-SWIFTUI-IDENTITY-CHURN-V1":
            #if FOVEA_SWIFTUI_SURFACE
                try await runIdentityChurn(model: model, phaseTracker: phaseTracker)
            #else
                try await runIdentityChurn(model: model)
            #endif
        default:
            throw BenchmarkAppError.invalidArguments
        }
        #if FOVEA_SWIFTUI_SURFACE
            phaseTracker.update(phase: "settle")
        #endif
        try await Task.sleep(nanoseconds: 750_000_000)
        if let holdText = ProcessInfo.processInfo.environment[
            "FOVEA_BENCHMARK_DIAGNOSTIC_HOLD_MILLISECONDS"
        ], let holdMilliseconds = UInt64(holdText), holdMilliseconds > 0 {
            #if FOVEA_SWIFTUI_SURFACE
                phaseTracker.update(phase: "diagnostic-hold")
            #endif
            try await Task.sleep(nanoseconds: min(60_000, holdMilliseconds) * 1_000_000)
        }

        #if FOVEA_SWIFTUI_SURFACE
            phaseTracker.update(phase: "complete")
            let diagnosticTimeline = await timeline?.stop()
        #endif
        frames.stop()
        let memory = footprint.stop()
        let thermalSnapshot = thermal.snapshotAndStop()
        let snapshot = await recorder.snapshot()
        let duration = DispatchTime.now().uptimeNanoseconds &- started
        let measurements = AsyncImageMeasurements(
            requestedCount: snapshot.requestedCount,
            successCount: snapshot.successCount,
            terminalCount: snapshot.terminalCount,
            terminalWithoutVisibleCount: snapshot.terminalWithoutVisibleCount,
            failureCount: snapshot.failureCount,
            disappearanceCount: snapshot.disappearanceCount,
            staleSuccessCount: snapshot.staleSuccessCount,
            medianSuccessLatencyNanoseconds: percentile(snapshot.successLatenciesNanoseconds, 0.5),
            p95SuccessLatencyNanoseconds: percentile(snapshot.successLatenciesNanoseconds, 0.95),
            medianTerminalLatencyNanoseconds: percentile(
                snapshot.terminalLatenciesNanoseconds, 0.5),
            p95TerminalLatencyNanoseconds: percentile(snapshot.terminalLatenciesNanoseconds, 0.95)
        )
        let originMetrics = origin.snapshot()
        var checks = checks(for: arguments.workloadID, measurements: measurements)
        checks.append(
            BenchmarkCheck(
                identifier: "origin-request-observed",
                passed: originMetrics.requestCount > 0,
                value: originMetrics.requestCount > 0 ? 0 : 1
            )
        )
        checks.append(
            BenchmarkCheck(
                identifier: "visible-success-observed",
                passed: measurements.successCount > 0,
                value: measurements.successCount > 0 ? 0 : 1
            )
        )
        checks.append(
            BenchmarkCheck(
                identifier: "terminal-without-visible-zero",
                passed: measurements.terminalWithoutVisibleCount == 0,
                value: measurements.terminalWithoutVisibleCount
            )
        )
        checks.append(
            BenchmarkCheck(
                identifier: "terminal-phase-observed",
                passed: measurements.terminalCount > 0,
                value: measurements.terminalCount > 0 ? 0 : 1
            )
        )
        let processMetrics = BenchmarkProcessMetrics(
            baselinePhysicalFootprintBytes: memory.baseline,
            peakPhysicalFootprintBytes: memory.peak,
            physicalFootprintDeltaBytes: memory.delta,
            hitchCount: frames.hitchCount,
            hitchExcessNanoseconds: frames.hitchExcessNanoseconds,
            maximumFrameIntervalNanoseconds: frames.maximumFrameIntervalNanoseconds,
            durationNanoseconds: duration,
            decodedMegapixels: 0,
            completedLoads: snapshot.terminalCount,
            cancelledLoads: snapshot.disappearanceCount,
            failedLoads: snapshot.failureCount
        )
        let harness = try injectedHarnessIdentity()
        #if FOVEA_SWIFTUI_SURFACE
            let identity = try ComparatorIdentity(
                name: "Fovea",
                version: "0b-worktree",
                exactCommit: harness.commit,
                sourceTreeDigest: harness.sourceTreeDigest,
                includesWorkingTreeChanges: harness.includesWorkingTreeChanges
            )
        #else
            let platform = try ComparatorPlatformBuildIdentity(
                xcodeBuild: try xcodeBuild(),
                osBuild: catalog.environment.osBuild,
                deviceProfileID: catalog.environment.deviceProfileID
            )
            let identity = try ComparatorIdentity(
                name: "Apple AsyncImage",
                version: "SwiftUI-\(catalog.environment.osVersion)",
                platformBuild: platform
            )
        #endif
        let envelope = AsyncImageRunEnvelope(
            schemaVersion: 5,
            planID: "FOVEA-SWIFTUI-SURFACE-LAB-V5",
            comparator: identity,
            harnessIdentity: harness,
            experimentPlanDigest: try injectedDigest("FOVEA_EXPERIMENT_PLAN_DIGEST"),
            applicabilityDigest: try injectedDigest("FOVEA_APPLICABILITY_DIGEST"),
            claimFamilyDigest: try injectedDigest("FOVEA_CLAIM_FAMILY_DIGEST"),
            environment: catalog.environment,
            workloadID: arguments.workloadID,
            networkProfile: arguments.networkProfile,
            runIndex: arguments.runIndex,
            orderPosition: arguments.orderPosition,
            runNonce: arguments.runNonce,
            timeScale: arguments.timeScale,
            datasetDigest: catalog.dataset.datasetDigest,
            executionEnvironment: executionEnvironment(),
            provisional: true,
            measurements: measurements,
            processMetrics: processMetrics,
            thermal: thermalSnapshot,
            originMetrics: originMetrics,
            checks: checks,
            limitations: limitations(for: arguments.workloadID)
        )
        try write(envelope, named: arguments.outputName)
        #if FOVEA_SWIFTUI_SURFACE
            if let diagnosticTimeline {
                try writeDiagnosticTimeline(
                    diagnosticTimeline,
                    named: arguments.outputName.replacingOccurrences(
                        of: ".json", with: ".timeline.json"
                    )
                )
            }
            if let benchmarkDiagnostics {
                try writeBenchmarkDiagnostics(
                    await benchmarkDiagnostics.snapshot(),
                    named: arguments.outputName.replacingOccurrences(
                        of: ".json", with: ".diagnostics.json"
                    )
                )
            }
            await foveaSystem.invalidateAndCancel()
        #endif
    }

    private static func runFeed(
        model: AsyncImageBenchmarkModel,
        timeScale: Double
    ) async throws {
        let targets = [
            0, 18, 42, 15, 80, 122, 56, 180, 260, 148, 360, 500, 420, 650, 820, 700, 999,
        ]
        for (generation, target) in targets.enumerated() {
            await model.recorder.setCurrentGeneration(generation)
            model.feedGeneration = generation
            model.feedTarget = target
            try await Task.sleep(
                nanoseconds: UInt64(max(16, Int(240 * timeScale))) * 1_000_000
            )
        }
    }

    private static func runHeroes(model: AsyncImageBenchmarkModel) async throws {
        let names = [
            "hero-12mp-4000x3000.jpg",
            "hero-24mp-6000x4000.jpg",
            "hero-48mp-8000x6000.jpg",
        ]
        for (generation, name) in names.enumerated() {
            await model.recorder.setCurrentGeneration(generation)
            model.heroGeneration = generation
            model.heroName = name
            try await waitForSuccessCount(recorder: model.recorder, minimum: generation + 1)
        }
    }

    #if FOVEA_SWIFTUI_SURFACE
        private static func runIdentityChurn(
            model: AsyncImageBenchmarkModel,
            phaseTracker: AsyncImageDiagnosticPhaseTracker
        ) async throws {
            phaseTracker.update(phase: "identity-churn", generation: 0)
            for generation in 0..<256 {
                phaseTracker.update(phase: "identity-churn", generation: generation)
                await model.recorder.setCurrentGeneration(generation)
                model.identityGeneration = generation
                model.identityAssetIndex = generation
                try await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    #else
        private static func runIdentityChurn(model: AsyncImageBenchmarkModel) async throws {
            for generation in 0..<256 {
                await model.recorder.setCurrentGeneration(generation)
                model.identityGeneration = generation
                model.identityAssetIndex = generation
                try await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    #endif

    private static func waitForSuccessCount(
        recorder: AsyncImagePhaseRecorder,
        minimum: Int
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 20_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await recorder.snapshot().successCount >= minimum { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw BenchmarkAppError.runFailed("asyncimage-success-timeout")
    }

    private static func checks(
        for workloadID: String,
        measurements: AsyncImageMeasurements
    ) -> [BenchmarkCheck] {
        var values = [
            BenchmarkCheck(identifier: "no-crash-or-hang", passed: true, value: 0),
            BenchmarkCheck(
                identifier: "stale-success-zero",
                passed: measurements.staleSuccessCount == 0,
                value: measurements.staleSuccessCount
            ),
        ]
        if workloadID == "W2-HERO-V1" {
            values.append(
                BenchmarkCheck(
                    identifier: "all-three-heroes-reach-success-phase",
                    passed: measurements.successCount >= 3,
                    value: max(0, 3 - measurements.successCount)
                )
            )
        }
        return values
    }

    private static func limitations(for workloadID: String) -> [String] {
        #if FOVEA_SWIFTUI_SURFACE
            return [
                "surface-family-ranks-only-common-swiftui-endpoints",
                "fovea-explicit-cancellation-target-decode-and-cache-contracts-are-reported-in-headless-labs",
                "cache-state-is-reset-by-reopening-the-fovea-system-pipeline",
                "first-full-quality-visible-may-precede-fovea-durable-final; terminal-latency-is-reported-separately",
            ]
        #else
            switch workloadID {
            case "W1-SCROLL-V1":
                return [
                    "no-explicit-subscriber-cancel-handle",
                    "no-request-header-control",
                    "no-cache-source-attribution",
                    "no-target-pixel-decode-contract",
                ]
            case "W2-HERO-V1":
                return [
                    "display-frame-is-not-target-decode",
                    "decoded-pixel-count-not-exposed",
                    "cache-state-not-controllable",
                ]
            default:
                return [
                    "underlying-task-cancellation-not-observable",
                    "cache-state-not-controllable",
                ]
            }
        #endif
    }

    private static func percentile(_ values: [UInt64], _ quantile: Double) -> UInt64? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(
            sorted.count - 1, max(0, Int((Double(sorted.count - 1) * quantile).rounded(.up))))
        return sorted[index]
    }

    private static func injectedHarnessIdentity() throws -> BenchmarkHarnessIdentity {
        let environment = ProcessInfo.processInfo.environment
        guard let commit = environment["FOVEA_BENCHMARK_COMMIT"],
            let tree = environment["FOVEA_BENCHMARK_TREE_DIGEST"]
        else {
            throw BenchmarkAppError.invalidArguments
        }
        return try BenchmarkHarnessIdentity(
            commit: commit,
            sourceTreeDigest: tree,
            includesWorkingTreeChanges: environment["FOVEA_BENCHMARK_DIRTY"] == "1"
        )
    }

    private static func injectedDigest(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], value.count == 64,
            value.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else {
            throw BenchmarkAppError.invalidArguments
        }
        return value
    }

    private static func xcodeBuild() throws -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "DTXcodeBuild") as? String,
            !value.isEmpty
        else {
            throw BenchmarkAppError.invalidResource("xcode-build")
        }
        return value
    }

    private static func executionEnvironment() -> String {
        #if targetEnvironment(simulator)
            "simulator"
        #else
            "physical-device"
        #endif
    }

    #if FOVEA_SWIFTUI_SURFACE
        private static func writeBenchmarkDiagnostics(
            _ events: [RecordedDiagnosticEvent],
            named name: String
        ) throws {
            let documents = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(events).write(
                to: documents.appendingPathComponent(name),
                options: [.atomic]
            )
        }

        private static func writeDiagnosticTimeline(
            _ timeline: AsyncImageDiagnosticTimelineEnvelope,
            named name: String
        ) throws {
            let documents = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(timeline).write(
                to: documents.appendingPathComponent(name),
                options: [.atomic]
            )
        }
    #endif

    private static func write(_ envelope: AsyncImageRunEnvelope, named name: String) throws {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(envelope).write(
            to: documents.appendingPathComponent(name),
            options: [.atomic]
        )
    }
}
