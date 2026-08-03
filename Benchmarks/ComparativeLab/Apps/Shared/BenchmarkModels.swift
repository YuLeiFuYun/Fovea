import ComparativeLabCore
import CryptoKit
import Foundation

struct CapturedDatasetManifest: Decodable, Sendable {
    let schemaVersion: Int
    let datasetDigest: String
    let assetCount: Int
    let totalByteCount: Int
    let assets: [CapturedAsset]
}

struct CapturedAsset: Decodable, Sendable {
    let assetID: String
    let resourcePath: String
    let sha256: String
    let byteCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let mimeType: String
}

struct CorrectnessProbeManifest: Decodable, Sendable {
    let schemaVersion: Int
    let probes: [CorrectnessProbe]
}

struct CorrectnessProbe: Decodable, Sendable {
    struct Sample: Decodable, Sendable {
        let x: Double
        let y: Double
        let rgb: [Int]
    }

    let identifier: String
    let resourceName: String
    let mimeType: String
    let sha256: String
    let rawPixelWidth: Int
    let rawPixelHeight: Int
    let expectedPixelWidth: Int
    let expectedPixelHeight: Int
    let maxChannelError: Int
    let samples: [Sample]
}

struct SanitizedDeviceProfile: Decodable, Sendable {
    struct OperatingSystem: Decodable, Sendable {
        let family: String
        let version: String
        let build: String
        let channel: String
    }

    let profileID: String
    let role: String
    let operatingSystem: OperatingSystem
}

enum BenchmarkCacheState: String, Codable, Sendable {
    case cold
    case warmDisk = "warm-disk"
    case warmMemory = "warm-memory"
}

enum BenchmarkNetworkProfile: String, Codable, Sendable {
    case local = "NET-LOCAL-V1"
    case constrained = "NET-CONSTRAINED-V1"

    var initialDelayNanoseconds: UInt64 {
        switch self {
        case .local: 25_000_000
        case .constrained: 100_000_000
        }
    }

    var bytesPerSecond: Int {
        switch self {
        case .local: 6_250_000
        case .constrained: 1_000_000
        }
    }
}

struct BenchmarkArguments: Sendable {
    let workload: ComparativeWorkloadID
    let cacheState: BenchmarkCacheState
    let networkProfile: BenchmarkNetworkProfile
    let runIndex: Int
    let timeScale: Double
    let outputName: String

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), index + 1 < arguments.count else {
                throw BenchmarkAppError.invalidArguments
            }
            values[String(key.dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        guard let workloadRaw = values["workload"],
            let workload = ComparativeWorkloadID(rawValue: workloadRaw),
            let cacheRaw = values["cache-state"],
            let cacheState = BenchmarkCacheState(rawValue: cacheRaw),
            let networkRaw = values["network-profile"],
            let networkProfile = BenchmarkNetworkProfile(rawValue: networkRaw),
            let runRaw = values["run-index"],
            let runIndex = Int(runRaw),
            runIndex >= 0
        else {
            throw BenchmarkAppError.invalidArguments
        }
        let timeScale = Double(values["time-scale"] ?? "1") ?? 1
        guard timeScale > 0, timeScale <= 1 else { throw BenchmarkAppError.invalidArguments }
        let outputName = values["output"] ?? "result.json"
        guard !outputName.contains("/"), outputName.hasSuffix(".json") else {
            throw BenchmarkAppError.invalidArguments
        }
        self.workload = workload
        self.cacheState = cacheState
        self.networkProfile = networkProfile
        self.runIndex = runIndex
        self.timeScale = timeScale
        self.outputName = outputName
    }
}

enum BenchmarkAppError: Error, Sendable {
    case invalidArguments
    case missingResource(String)
    case invalidResource(String)
    case adapterDidNotRender
    case targetInvariantFailed
    case runFailed(String)
}

struct BenchmarkCheck: Codable, Sendable {
    let identifier: String
    let passed: Bool
    let value: Int
}

struct BenchmarkOriginMetrics: Codable, Sendable {
    let requestCount: Int
    let deliveredBytes: Int
    let postCancellationBytes: Int
    let completedRequestCount: Int
    let stoppedRequestCount: Int
    let redirectAuthorizationLeakCount: Int
    let peakConcurrentRequestCount: Int
    let w7SharedPreparationWaitCount: Int
    let w7ServiceStartOrder: [String]
    let routeRequestCounts: [String: Int]
}

struct BenchmarkProcessMetrics: Codable, Sendable {
    let baselinePhysicalFootprintBytes: UInt64?
    let peakPhysicalFootprintBytes: UInt64?
    let physicalFootprintDeltaBytes: Int64?
    let hitchCount: Int
    let hitchExcessNanoseconds: UInt64
    let maximumFrameIntervalNanoseconds: UInt64
    let durationNanoseconds: UInt64
    let decodedMegapixels: Double
    let completedLoads: Int
    let cancelledLoads: Int
    let failedLoads: Int
}

struct BenchmarkThermalSnapshot: Codable, Sendable {
    let stateAtStart: String
    let stateAtEnd: String
    let remainedNominal: Bool
}

struct BenchmarkHarnessIdentity: Codable, Equatable, Sendable {
    let commit: String
    let sourceTreeDigest: String
    let includesWorkingTreeChanges: Bool

    init(commit: String, sourceTreeDigest: String, includesWorkingTreeChanges: Bool) throws {
        guard commit.count == 40,
            commit.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
            sourceTreeDigest.count == 64,
            sourceTreeDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else {
            throw BenchmarkAppError.invalidArguments
        }
        self.commit = commit
        self.sourceTreeDigest = sourceTreeDigest
        self.includesWorkingTreeChanges = includesWorkingTreeChanges
    }
}

struct BenchmarkRunEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let planID: String
    let comparator: ComparatorIdentity
    let harnessIdentity: BenchmarkHarnessIdentity
    let experimentPlanDigest: String
    let claimFamilyDigest: String
    let environment: ComparatorRunEnvironment
    let workloadID: ComparativeWorkloadID
    let cacheState: BenchmarkCacheState
    let networkProfile: BenchmarkNetworkProfile
    let runIndex: Int
    let timeScale: Double
    let datasetDigest: String
    let executionEnvironment: String
    let provisional: Bool
    let artifact: ComparatorRunArtifact
    let processMetrics: BenchmarkProcessMetrics
    let thermal: BenchmarkThermalSnapshot
    let originMetrics: BenchmarkOriginMetrics
    let checks: [BenchmarkCheck]

    init(
        planID: String,
        comparator: ComparatorIdentity,
        harnessIdentity: BenchmarkHarnessIdentity,
        experimentPlanDigest: String,
        claimFamilyDigest: String,
        environment: ComparatorRunEnvironment,
        workloadID: ComparativeWorkloadID,
        cacheState: BenchmarkCacheState,
        networkProfile: BenchmarkNetworkProfile,
        runIndex: Int,
        timeScale: Double,
        datasetDigest: String,
        artifact: ComparatorRunArtifact,
        processMetrics: BenchmarkProcessMetrics,
        thermal: BenchmarkThermalSnapshot,
        originMetrics: BenchmarkOriginMetrics,
        checks: [BenchmarkCheck]
    ) {
        self.schemaVersion = 3
        self.planID = planID
        self.comparator = comparator
        self.harnessIdentity = harnessIdentity
        self.experimentPlanDigest = experimentPlanDigest
        self.claimFamilyDigest = claimFamilyDigest
        self.environment = environment
        self.workloadID = workloadID
        self.cacheState = cacheState
        self.networkProfile = networkProfile
        self.runIndex = runIndex
        self.timeScale = timeScale
        self.datasetDigest = datasetDigest
        #if targetEnvironment(simulator)
            self.executionEnvironment = "simulator"
        #else
            self.executionEnvironment = "physical-device"
        #endif
        self.provisional =
            !environment.permitsReleaseClaim || timeScale != 1
            || executionEnvironment != "physical-device"
        self.artifact = artifact
        self.processMetrics = processMetrics
        self.thermal = thermal
        self.originMetrics = originMetrics
        self.checks = checks
    }
}

struct WorkloadResult: Sendable {
    let observations: [ComparatorObservation]
    let checks: [BenchmarkCheck]
    let durationNanoseconds: UInt64
    let decodedMegapixels: Double
    let completedLoads: Int
    let cancelledLoads: Int
    let failedLoads: Int
}

struct ResourceCatalog: Sendable {
    let dataset: CapturedDatasetManifest
    let environment: ComparatorRunEnvironment
    let correctnessProbes: CorrectnessProbeManifest
    let bundle: Bundle

    static func load(bundle: Bundle = .main) throws -> ResourceCatalog {
        guard let datasetURL = bundle.url(forResource: "captured-dataset", withExtension: "json"),
            let deviceURL = bundle.url(forResource: "device-profile", withExtension: "json"),
            let probesURL = bundle.url(forResource: "correctness-probes", withExtension: "json")
        else {
            throw BenchmarkAppError.missingResource("manifest")
        }
        let decoder = JSONDecoder()
        let dataset = try decoder.decode(
            CapturedDatasetManifest.self, from: Data(contentsOf: datasetURL))
        let device = try decoder.decode(
            SanitizedDeviceProfile.self, from: Data(contentsOf: deviceURL))
        let correctnessProbes = try decoder.decode(
            CorrectnessProbeManifest.self, from: Data(contentsOf: probesURL))
        guard dataset.schemaVersion == 1, dataset.assetCount == 128,
            dataset.assets.count == 128, dataset.datasetDigest.count == 64
        else {
            throw BenchmarkAppError.invalidResource("dataset")
        }
        guard correctnessProbes.schemaVersion == 1,
            correctnessProbes.probes.count == 2,
            Set(correctnessProbes.probes.map(\.identifier)).count == correctnessProbes.probes.count,
            correctnessProbes.probes.allSatisfy({ probe in
                probe.sha256.count == 64 && probe.expectedPixelWidth > 0
                    && probe.expectedPixelHeight > 0 && probe.samples.count == 4
                    && probe.samples.allSatisfy({ sample in
                        (0...1).contains(sample.x) && (0...1).contains(sample.y)
                            && sample.rgb.count == 3
                            && sample.rgb.allSatisfy({ (0...255).contains($0) })
                    })
            })
        else {
            throw BenchmarkAppError.invalidResource("correctness-probes")
        }
        let environment: ComparatorRunEnvironment
        #if targetEnvironment(simulator)
            let injected = ProcessInfo.processInfo.environment
            guard
                let profileID = injected["FOVEA_SIMULATOR_PROFILE_ID"],
                let declaredVersion = injected["FOVEA_SIMULATOR_OS_VERSION"],
                let build = injected["FOVEA_SIMULATOR_OS_BUILD"],
                let channelName = injected["FOVEA_SIMULATOR_OS_CHANNEL"],
                let channel = OSReleaseChannel(rawValue: channelName),
                Self.versionMatchesCurrentSimulator(declaredVersion)
            else {
                throw BenchmarkAppError.invalidResource("simulator-environment-identity")
            }
            environment = try ComparatorRunEnvironment(
                deviceProfileID: profileID,
                deviceRole: .primaryCurrentMid,
                osFamily: "iOS Simulator",
                osVersion: declaredVersion,
                osBuild: build,
                osChannel: channel
            )
        #else
            guard let role = DeviceEvidenceRole(rawValue: device.role),
                let channel = OSReleaseChannel(rawValue: device.operatingSystem.channel)
            else {
                throw BenchmarkAppError.invalidResource("device-profile")
            }
            environment = try ComparatorRunEnvironment(
                deviceProfileID: device.profileID,
                deviceRole: role,
                osFamily: device.operatingSystem.family,
                osVersion: device.operatingSystem.version,
                osBuild: device.operatingSystem.build,
                osChannel: channel
            )
        #endif
        return ResourceCatalog(
            dataset: dataset,
            environment: environment,
            correctnessProbes: correctnessProbes,
            bundle: bundle
        )
    }

    private static func versionMatchesCurrentSimulator(_ declared: String) -> Bool {
        let parts = declared.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
            parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
            let major = Int(parts[0]),
            let minor = Int(parts[1]),
            let patch = parts.count == 3 ? Int(parts[2]) : 0
        else { return false }
        let current = ProcessInfo.processInfo.operatingSystemVersion
        return current.majorVersion == major && current.minorVersion == minor
            && current.patchVersion == patch
    }

    func fileURL(for asset: CapturedAsset) throws -> URL {
        let path = asset.resourcePath as NSString
        let fileName = path.lastPathComponent as NSString
        if let url = bundle.url(
            forResource: fileName.deletingPathExtension,
            withExtension: fileName.pathExtension,
            subdirectory: path.deletingLastPathComponent
        ) {
            return url
        }
        if let resourceURL = bundle.resourceURL {
            let flatURL = resourceURL.appendingPathComponent(path.lastPathComponent)
            if FileManager.default.isReadableFile(atPath: flatURL.path) { return flatURL }
        }
        throw BenchmarkAppError.missingResource(asset.resourcePath)
    }

    func correctnessProbe(identifier: String) throws -> CorrectnessProbe {
        guard let probe = correctnessProbes.probes.first(where: { $0.identifier == identifier })
        else {
            throw BenchmarkAppError.missingResource(identifier)
        }
        return probe
    }

    func probeURL(for probe: CorrectnessProbe) throws -> URL {
        let value = probe.resourceName as NSString
        let candidates: [URL?] = [
            bundle.url(
                forResource: value.deletingPathExtension,
                withExtension: value.pathExtension,
                subdirectory: "probes"
            ),
            bundle.resourceURL?.appendingPathComponent(probe.resourceName),
        ]
        guard
            let url = candidates.compactMap({ $0 }).first(where: {
                FileManager.default.isReadableFile(atPath: $0.path)
            })
        else {
            throw BenchmarkAppError.missingResource(probe.resourceName)
        }
        let payload = try Data(contentsOf: url, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        guard digest == probe.sha256 else {
            throw BenchmarkAppError.invalidResource(probe.identifier)
        }
        return url
    }

    func heroURL(named name: String) throws -> URL {
        let value = name as NSString
        if let url = bundle.url(
            forResource: value.deletingPathExtension,
            withExtension: value.pathExtension,
            subdirectory: "heroes"
        ) {
            return url
        }
        if let resourceURL = bundle.resourceURL {
            let flatURL = resourceURL.appendingPathComponent(name)
            if FileManager.default.isReadableFile(atPath: flatURL.path) { return flatURL }
        }
        throw BenchmarkAppError.missingResource(name)
    }

}
