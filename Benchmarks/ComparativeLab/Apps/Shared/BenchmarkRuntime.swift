import ComparativeLabCore
import Foundation
import UIKit

actor ObservationAccumulator {
    private var values: [ComparatorObservation] = []
    private var completed = 0
    private var cancelled = 0
    private var failed = 0
    private var decodedPixels = 0
    private var targetPixelViolationCount = 0

    func append(resourceID: String, target: ComparatorPixelTarget, output: ComparatorLoadOutput) {
        let sequence = values.count
        if let observation = try? ComparatorObservation(
            sequence: sequence,
            resourceID: resourceID,
            target: target,
            result: output.measurement
        ) {
            values.append(observation)
        }
        switch output.measurement.outcome {
        case .completed:
            completed += 1
            if let width = output.measurement.pixelWidth,
                let height = output.measurement.pixelHeight
            {
                decodedPixels += width * height
                if width > target.width || height > target.height {
                    targetPixelViolationCount += 1
                }
            }
        case .cancelled:
            cancelled += 1
        case .failed:
            failed += 1
        }
    }

    func snapshot() -> (
        observations: [ComparatorObservation], completed: Int, cancelled: Int, failed: Int,
        decodedMegapixels: Double, targetPixelViolationCount: Int
    ) {
        (
            values, completed, cancelled, failed, Double(decodedPixels) / 1_000_000,
            targetPixelViolationCount
        )
    }
}

@MainActor
final class BenchmarkStatusViewController: UIViewController {
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        label.text = "Preparing comparative benchmark…"
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    func update(_ text: String) { label.text = text }
}

final class BenchmarkThermalMonitor: @unchecked Sendable {
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
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
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
        if state != .nominal {
            remainedNominal = false
        }
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

@MainActor
enum BenchmarkCoordinator {
    static func run(arguments: BenchmarkArguments, window: UIWindow) async throws {
        NSLog("FOVEA_STAGE=catalog-start")
        let catalog = try ResourceCatalog.load()
        NSLog("FOVEA_STAGE=catalog-ready")
        NSLog("FOVEA_STAGE=origin-configure-start")
        let loopbackOrigin: LoopbackBenchmarkOriginServer?
        if arguments.workload == .w2DetailHero {
            let origin = try LoopbackBenchmarkOriginServer(
                catalog: catalog,
                profile: arguments.networkProfile
            )
            originBaseURL = try await origin.start()
            loopbackOrigin = origin
        } else {
            try DeterministicBenchmarkURLProtocol.configure(
                catalog: catalog,
                profile: arguments.networkProfile
            )
            originBaseURL = nil
            loopbackOrigin = nil
        }
        defer {
            loopbackOrigin?.stop()
            originBaseURL = nil
        }
        NSLog("FOVEA_STAGE=origin-configure-ready")
        let session = URLSessionConfiguration.ephemeral
        if loopbackOrigin == nil {
            session.protocolClasses = [DeterministicBenchmarkURLProtocol.self]
        }
        if arguments.workload == .w7ThousandConcurrent {
            session.httpMaximumConnectionsPerHost = 8
        }
        session.urlCache = nil
        session.httpCookieStorage = nil
        session.urlCredentialStorage = nil
        session.httpShouldSetCookies = false

        let harnessIdentity = try injectedHarnessIdentity()
        let experimentPlanID = try injectedPlanID()
        let experimentPlanDigest = try injectedDigest("FOVEA_EXPERIMENT_PLAN_DIGEST")
        let claimFamilyDigest = try injectedDigest("FOVEA_CLAIM_FAMILY_DIGEST")
        let identity = try injectedIdentity(
            harnessIdentity,
            environment: catalog.environment
        )
        let cacheRoot = try cacheDirectory()
        NSLog("FOVEA_STAGE=adapter-open-start")
        let adapter = try await BenchmarkAdapterFactory.make(
            cacheDirectory: cacheRoot,
            sessionConfiguration: session,
            identity: identity,
            workload: arguments.workload
        )
        NSLog("FOVEA_STAGE=adapter-open-ready")

        var correctnessChecks: [BenchmarkCheck] = []
        var heroController: HeroBenchmarkViewController?
        if arguments.workload == .w2DetailHero {
            let controller = HeroBenchmarkViewController()
            window.rootViewController = controller
            window.makeKeyAndVisible()
            await Task.yield()
            resetOriginMetrics(loopbackOrigin)
            NSLog("FOVEA_STAGE=w2-correctness-start")
            correctnessChecks = try await WorkloadRunner.runW2Correctness(
                adapter: adapter,
                catalog: catalog,
                runIndex: arguments.runIndex
            )
            NSLog("FOVEA_STAGE=w2-correctness-ready")
            heroController = controller
        }

        NSLog("FOVEA_STAGE=cache-prepare-start")
        try await prepareCache(
            arguments.cacheState,
            workload: arguments.workload,
            adapter: adapter,
            catalog: catalog
        )
        NSLog("FOVEA_STAGE=cache-prepare-ready")
        resetOriginMetrics(loopbackOrigin)
        let footprint = PhysicalFootprintSampler()
        let frames = FrameHitchSampler()
        let thermalMonitor = BenchmarkThermalMonitor()
        footprint.start()
        frames.start()
        let result: WorkloadResult
        NSLog("FOVEA_STAGE=workload-start")
        switch arguments.workload {
        case .w1FeedScroll:
            let controller = FeedBenchmarkViewController(
                adapter: adapter,
                catalog: catalog,
                timeScale: arguments.timeScale,
                runIndex: arguments.runIndex
            )
            window.rootViewController = controller
            window.makeKeyAndVisible()
            await Task.yield()
            result = try await controller.execute()
        case .w2DetailHero:
            guard let heroController else {
                throw BenchmarkAppError.runFailed("w2-controller-unavailable")
            }
            result = try await WorkloadRunner.runW2Performance(
                adapter: adapter,
                catalog: catalog,
                controller: heroController,
                runIndex: arguments.runIndex
            )
        case .w3AuthGallery:
            let controller = BenchmarkStatusViewController()
            controller.loadViewIfNeeded()
            controller.update("Running W3 authentication contracts")
            window.rootViewController = controller
            window.makeKeyAndVisible()
            await Task.yield()
            result = try await WorkloadRunner.runW3(
                adapter: adapter,
                runIndex: arguments.runIndex
            )
        case .w4ProgressiveJPEG:
            let controller = HeroBenchmarkViewController()
            window.rootViewController = controller
            window.makeKeyAndVisible()
            await Task.yield()
            result = try await WorkloadRunner.runW4(
                adapter: adapter,
                controller: controller,
                runIndex: arguments.runIndex
            )
        case .w7ThousandConcurrent:
            let controller = BenchmarkStatusViewController()
            controller.loadViewIfNeeded()
            controller.update("Running W7 1,000-request concurrency trace")
            window.rootViewController = controller
            window.makeKeyAndVisible()
            await Task.yield()
            result = try await WorkloadRunner.runW7(
                adapter: adapter,
                runIndex: arguments.runIndex
            )
        }
        NSLog("FOVEA_STAGE=workload-ready")
        frames.stop()
        let memory = footprint.stop()
        let thermal = thermalMonitor.snapshotAndStop()
        let processMetrics = BenchmarkProcessMetrics(
            baselinePhysicalFootprintBytes: memory.baseline,
            peakPhysicalFootprintBytes: memory.peak,
            physicalFootprintDeltaBytes: memory.delta,
            hitchCount: frames.hitchCount,
            hitchExcessNanoseconds: frames.hitchExcessNanoseconds,
            maximumFrameIntervalNanoseconds: frames.maximumFrameIntervalNanoseconds,
            durationNanoseconds: result.durationNanoseconds,
            decodedMegapixels: result.decodedMegapixels,
            completedLoads: result.completedLoads,
            cancelledLoads: result.cancelledLoads,
            failedLoads: result.failedLoads
        )
        let artifact = try ComparatorRunArtifact(
            workloadID: arguments.workload,
            comparator: adapter.identity,
            environment: catalog.environment,
            runIndex: arguments.runIndex,
            datasetDigest: catalog.dataset.datasetDigest,
            observations: result.observations
        )
        #if targetEnvironment(simulator)
            let allChecks = correctnessChecks + result.checks
        #else
            let allChecks =
                correctnessChecks + result.checks + [
                    BenchmarkCheck(
                        identifier: "thermal-nominal-throughout",
                        passed: thermal.remainedNominal,
                        value: thermal.remainedNominal ? 0 : 1
                    )
                ]
        #endif
        let envelope = BenchmarkRunEnvelope(
            planID: experimentPlanID,
            comparator: adapter.identity,
            harnessIdentity: harnessIdentity,
            experimentPlanDigest: experimentPlanDigest,
            claimFamilyDigest: claimFamilyDigest,
            environment: catalog.environment,
            workloadID: arguments.workload,
            cacheState: arguments.cacheState,
            networkProfile: arguments.networkProfile,
            runIndex: arguments.runIndex,
            timeScale: arguments.timeScale,
            datasetDigest: catalog.dataset.datasetDigest,
            artifact: artifact,
            processMetrics: processMetrics,
            thermal: thermal,
            originMetrics: originMetrics(loopbackOrigin),
            checks: allChecks
        )
        try write(envelope, named: arguments.outputName)
        await adapter.cancelAll()
    }

    private static var originBaseURL: URL?

    private static func resetOriginMetrics(_ loopbackOrigin: LoopbackBenchmarkOriginServer?) {
        if let loopbackOrigin {
            loopbackOrigin.resetMetrics()
        } else {
            DeterministicBenchmarkURLProtocol.resetMetrics()
        }
    }

    private static func originMetrics(
        _ loopbackOrigin: LoopbackBenchmarkOriginServer?
    ) -> BenchmarkOriginMetrics {
        if let loopbackOrigin {
            return loopbackOrigin.snapshot()
        }
        return DeterministicBenchmarkURLProtocol.metrics()
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

    private static func injectedPlanID() throws -> String {
        guard let value = ProcessInfo.processInfo.environment["FOVEA_EXPERIMENT_PLAN_ID"],
            !value.isEmpty,
            value.count <= 96,
            !value.contains("://")
        else {
            throw BenchmarkAppError.invalidArguments
        }
        return value
    }

    private static func injectedDigest(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name],
            value.count == 64,
            value.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else {
            throw BenchmarkAppError.invalidArguments
        }
        return value
    }

    private static func injectedIdentity(
        _ harnessIdentity: BenchmarkHarnessIdentity,
        environment: ComparatorRunEnvironment
    ) throws -> ComparatorIdentity {
        if BenchmarkAdapterFactory.comparatorName == "Fovea" {
            return try ComparatorIdentity(
                name: "Fovea",
                version: "0b-worktree",
                exactCommit: harnessIdentity.commit,
                sourceTreeDigest: harnessIdentity.sourceTreeDigest,
                includesWorkingTreeChanges: harnessIdentity.includesWorkingTreeChanges
            )
        }
        if BenchmarkAdapterFactory.comparatorName == "Apple URLSession + URLCache + ImageIO"
            || BenchmarkAdapterFactory.comparatorName == "Apple AsyncImage"
        {
            guard
                let xcodeBuild = Bundle.main.object(
                    forInfoDictionaryKey: "DTXcodeBuild"
                ) as? String
            else {
                throw BenchmarkAppError.invalidArguments
            }
            let platform = try ComparatorPlatformBuildIdentity(
                xcodeBuild: xcodeBuild,
                osBuild: environment.osBuild,
                deviceProfileID: environment.deviceProfileID
            )
            return try ComparatorIdentity(
                name: BenchmarkAdapterFactory.comparatorName,
                version: "iOS-\(environment.osVersion)",
                platformBuild: platform
            )
        }
        return try ComparatorIdentity(
            name: BenchmarkAdapterFactory.comparatorName,
            version: "factory-input-unused",
            exactCommit: String(repeating: "0", count: 40)
        )
    }

    private static func cacheDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("ComparativeLab", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func prepareCache(
        _ state: BenchmarkCacheState,
        workload: ComparativeWorkloadID,
        adapter: any ComparatorAdapter,
        catalog: ResourceCatalog
    ) async throws {
        try await adapter.purgeDisk()
        await adapter.purgeMemory()
        guard state != .cold else { return }
        switch workload {
        case .w1FeedScroll:
            let target = try ComparatorPixelTarget(width: 320, height: 240)
            for asset in catalog.dataset.assets {
                let request = try ComparatorRequest(
                    resourceID: asset.assetID,
                    url: benchmarkURL(path: "/asset/\(asset.assetID)"),
                    target: target,
                    contentMode: .aspectFill,
                    priority: .utility
                )
                _ = try await adapter.makeLoad(request).result()
            }
        case .w2DetailHero:
            let targets = [
                try ComparatorPixelTarget(width: 390, height: 260),
                try ComparatorPixelTarget(width: 780, height: 520),
                try ComparatorPixelTarget(width: 1_170, height: 780),
            ]
            for name in [
                "hero-12mp-4000x3000.jpg",
                "hero-24mp-6000x4000.jpg",
                "hero-48mp-8000x6000.jpg",
            ] {
                for target in targets {
                    let request = try ComparatorRequest(
                        resourceID: "hero|\(name)|\(target.width)x\(target.height)",
                        url: benchmarkURL(path: "/hero/\(name)"),
                        target: target,
                        contentMode: .aspectFit,
                        priority: .utility
                    )
                    _ = try await adapter.makeLoad(request).result()
                }
            }
        case .w3AuthGallery, .w4ProgressiveJPEG, .w7ThousandConcurrent:
            break
        }
        if state == .warmDisk { await adapter.purgeMemory() }
    }

    static func benchmarkURL(path: String) -> URL {
        var components: URLComponents
        if let originBaseURL {
            components = URLComponents(url: originBaseURL, resolvingAgainstBaseURL: false)!
        } else {
            components = URLComponents()
            components.scheme = "https"
            components.host = "benchmark.invalid"
        }
        components.path = path
        return components.url!
    }

    private static func write(_ envelope: BenchmarkRunEnvelope, named name: String) throws {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let destination = documents.appendingPathComponent(name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(envelope).write(to: destination, options: [.atomic])
        print("FOVEA_COMPARATIVE_RESULT=\(name)")
    }
}
