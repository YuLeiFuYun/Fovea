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

struct AnimatedPlayerFixtureManifest: Decodable, Sendable {
    let schemaVersion: Int
    let fixtures: [AnimatedPlayerFixture]
}

struct AnimatedPlayerFixture: Decodable, Sendable {
    let id: String
    let format: String
    let fileName: String
    let sha256: String
    let byteCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let frameCount: Int
    let loopCount: UInt
    let frameDurationsNanoseconds: [UInt64]
    let frameIdentityRGB: [[Int]]
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
    let cachePreparationRepetitions: Int
    let networkProfile: BenchmarkNetworkProfile
    let runIndex: Int
    let timeScale: Double
    let outputName: String
    let w5FixtureID: String

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
        let cachePreparationRepetitions =
            Int(values["cache-preparation-repetitions"] ?? "1") ?? 1
        guard (1...64).contains(cachePreparationRepetitions),
            cacheState != .cold || cachePreparationRepetitions == 1
        else {
            throw BenchmarkAppError.invalidArguments
        }
        let outputName = values["output"] ?? "result.json"
        guard !outputName.contains("/"), outputName.hasSuffix(".json") else {
            throw BenchmarkAppError.invalidArguments
        }
        self.workload = workload
        self.cacheState = cacheState
        self.cachePreparationRepetitions = cachePreparationRepetitions
        self.networkProfile = networkProfile
        self.runIndex = runIndex
        self.timeScale = timeScale
        let w5FixtureID = values["w5-fixture"] ?? "GIF-VARIABLE-DELAY-60"
        guard !w5FixtureID.isEmpty, w5FixtureID.count <= 96,
            w5FixtureID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else {
            throw BenchmarkAppError.invalidArguments
        }
        self.outputName = outputName
        self.w5FixtureID = w5FixtureID
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
    let postCancellationCompletedBytes: Int
    let postCancellationCompletedRequestCount: Int
    let postCancellationCompletedBytesP50: Int
    let postCancellationCompletedBytesP95: Int
    let postCancellationCompletedBytesMaximum: Int
    let postCancellationAbandonedBytes: Int
    let postCancellationAbandonedRequestCount: Int
    let postCancellationAbandonedBytesP50: Int
    let postCancellationAbandonedBytesP95: Int
    let postCancellationAbandonedBytesMaximum: Int
    let cancellationAcknowledgementCount: Int
    let cancellationAcknowledgementP95Nanoseconds: UInt64
    let cancellationAcknowledgementMaximumNanoseconds: UInt64
    let completedRequestCount: Int
    let latestCompletedAtNanoseconds: UInt64
    let completedRequestDurationP50Nanoseconds: UInt64
    let completedRequestDurationP95Nanoseconds: UInt64
    let completedRequestDurationMaximumNanoseconds: UInt64
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

struct BenchmarkDiagnosticSidecar: Codable, Sendable {
    let schemaVersion: Int
    let comparator: ComparatorIdentity
    let harnessIdentity: BenchmarkHarnessIdentity
    let workloadID: ComparativeWorkloadID
    let runIndex: Int
    let events: [ComparatorDiagnosticEvent]

    init(
        comparator: ComparatorIdentity,
        harnessIdentity: BenchmarkHarnessIdentity,
        workloadID: ComparativeWorkloadID,
        runIndex: Int,
        events: [ComparatorDiagnosticEvent]
    ) {
        self.schemaVersion = 1
        self.comparator = comparator
        self.harnessIdentity = harnessIdentity
        self.workloadID = workloadID
        self.runIndex = runIndex
        self.events = events
    }
}

struct BenchmarkRunEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let planID: String
    let comparator: ComparatorIdentity
    let comparatorRuntimeConfiguration: ComparatorRuntimeConfiguration?
    let harnessIdentity: BenchmarkHarnessIdentity
    let experimentPlanDigest: String
    let claimFamilyDigest: String
    let environment: ComparatorRunEnvironment
    let workloadID: ComparativeWorkloadID
    let cacheState: BenchmarkCacheState
    let cachePreparationRepetitions: Int
    let networkProfile: BenchmarkNetworkProfile
    let runIndex: Int
    let timeScale: Double
    let datasetDigest: String
    let executionEnvironment: String
    let provisional: Bool
    let artifact: ComparatorRunArtifact
    let cachePreparationDiagnostics: [String: Int]
    let processMetrics: BenchmarkProcessMetrics
    let thermal: BenchmarkThermalSnapshot
    let originMetrics: BenchmarkOriginMetrics
    let checks: [BenchmarkCheck]

    init(
        planID: String,
        comparator: ComparatorIdentity,
        comparatorRuntimeConfiguration: ComparatorRuntimeConfiguration?,
        harnessIdentity: BenchmarkHarnessIdentity,
        experimentPlanDigest: String,
        claimFamilyDigest: String,
        environment: ComparatorRunEnvironment,
        workloadID: ComparativeWorkloadID,
        cacheState: BenchmarkCacheState,
        cachePreparationRepetitions: Int,
        networkProfile: BenchmarkNetworkProfile,
        runIndex: Int,
        timeScale: Double,
        datasetDigest: String,
        artifact: ComparatorRunArtifact,
        cachePreparationDiagnostics: [String: Int],
        processMetrics: BenchmarkProcessMetrics,
        thermal: BenchmarkThermalSnapshot,
        originMetrics: BenchmarkOriginMetrics,
        checks: [BenchmarkCheck]
    ) {
        self.schemaVersion = 5
        self.planID = planID
        self.comparator = comparator
        self.comparatorRuntimeConfiguration = comparatorRuntimeConfiguration
        self.harnessIdentity = harnessIdentity
        self.experimentPlanDigest = experimentPlanDigest
        self.claimFamilyDigest = claimFamilyDigest
        self.environment = environment
        self.workloadID = workloadID
        self.cacheState = cacheState
        self.cachePreparationRepetitions = cachePreparationRepetitions
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
            || cachePreparationRepetitions != 1
        self.artifact = artifact
        self.cachePreparationDiagnostics = cachePreparationDiagnostics
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

    func animatedPlayerFixture(
        identifier: String
    ) throws -> (fixture: AnimatedPlayerFixture, data: Data) {
        guard
            let manifestURL = bundle.url(
                forResource: "animated-player-fixtures",
                withExtension: "json"
            )
        else {
            throw BenchmarkAppError.missingResource("animated-player-fixtures.json")
        }
        let manifest = try JSONDecoder().decode(
            AnimatedPlayerFixtureManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.schemaVersion == 1,
            Set(manifest.fixtures.map(\.id)).count == manifest.fixtures.count,
            let fixture = manifest.fixtures.first(where: { $0.id == identifier }),
            fixture.sha256.count == 64,
            fixture.byteCount > 0,
            fixture.frameCount > 1,
            fixture.frameDurationsNanoseconds.count == fixture.frameCount,
            fixture.frameIdentityRGB.count == fixture.frameCount,
            fixture.frameIdentityRGB.allSatisfy({ rgb in
                rgb.count == 3 && rgb.allSatisfy({ (0...255).contains($0) })
            })
        else {
            throw BenchmarkAppError.invalidResource(identifier)
        }
        let candidates: [URL?] = [
            bundle.url(
                forResource: (fixture.fileName as NSString).deletingPathExtension,
                withExtension: (fixture.fileName as NSString).pathExtension,
                subdirectory: "animated"
            ),
            bundle.resourceURL?.appendingPathComponent("animated/\(fixture.fileName)"),
            bundle.resourceURL?.appendingPathComponent(fixture.fileName),
        ]
        guard
            let url = candidates.compactMap({ $0 }).first(where: {
                FileManager.default.isReadableFile(atPath: $0.path)
            })
        else {
            throw BenchmarkAppError.missingResource(fixture.fileName)
        }
        let payload = try Data(contentsOf: url, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        guard payload.count == fixture.byteCount, digest == fixture.sha256 else {
            throw BenchmarkAppError.invalidResource(identifier)
        }
        return (fixture, payload)
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

struct W5AnimatedTimingEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let measurementRole: String
    let planID: String
    let comparator: ComparatorIdentity
    let harnessIdentity: BenchmarkHarnessIdentity
    let experimentPlanDigest: String
    let claimFamilyDigest: String
    let environment: ComparatorRunEnvironment
    let workloadID: ComparativeWorkloadID
    let runIndex: Int
    let fixtureID: String
    let fixtureDigest: String
    let maximumFrameBufferBytes: Int
    let maximumDisplayFramesPerSecond: Int
    let playerInputPath: ComparatorAnimatedPlayerInputPath
    let executionEnvironment: String
    let provisional: Bool
    let nativeSourceFrameDurationsNanoseconds: [UInt64]
    let nativeSourceLoopCount: UInt
    let presentation: ComparatorAnimatedPresentationArtifact
    let thermal: BenchmarkThermalSnapshot
    let checks: [BenchmarkCheck]

    init(
        planID: String,
        comparator: ComparatorIdentity,
        harnessIdentity: BenchmarkHarnessIdentity,
        experimentPlanDigest: String,
        claimFamilyDigest: String,
        environment: ComparatorRunEnvironment,
        runIndex: Int,
        fixtureID: String,
        fixtureDigest: String,
        maximumFrameBufferBytes: Int,
        maximumDisplayFramesPerSecond: Int,
        playerInputPath: ComparatorAnimatedPlayerInputPath,
        nativeSourceFrameDurationsNanoseconds: [UInt64],
        nativeSourceLoopCount: UInt,
        presentation: ComparatorAnimatedPresentationArtifact,
        thermal: BenchmarkThermalSnapshot,
        checks: [BenchmarkCheck]
    ) throws {
        guard presentation.workloadID == .w5AnimatedMedia,
            presentation.comparator == comparator,
            presentation.environment == environment,
            presentation.runIndex == runIndex,
            presentation.datasetDigest == fixtureDigest,
            maximumFrameBufferBytes > 0,
            maximumDisplayFramesPerSecond > 0
        else {
            throw BenchmarkAppError.runFailed("w5-envelope-identity-mismatch")
        }
        self.schemaVersion = 1
        self.measurementRole = "PLAYER-TIMING"
        self.planID = planID
        self.comparator = comparator
        self.harnessIdentity = harnessIdentity
        self.experimentPlanDigest = experimentPlanDigest
        self.claimFamilyDigest = claimFamilyDigest
        self.environment = environment
        self.workloadID = .w5AnimatedMedia
        self.runIndex = runIndex
        self.fixtureID = fixtureID
        self.fixtureDigest = fixtureDigest
        self.maximumFrameBufferBytes = maximumFrameBufferBytes
        self.maximumDisplayFramesPerSecond = maximumDisplayFramesPerSecond
        self.playerInputPath = playerInputPath
        #if targetEnvironment(simulator)
            self.executionEnvironment = "simulator"
        #else
            self.executionEnvironment = "physical-device"
        #endif
        self.provisional =
            !environment.permitsReleaseClaim || executionEnvironment != "physical-device"
        self.nativeSourceFrameDurationsNanoseconds = nativeSourceFrameDurationsNanoseconds
        self.nativeSourceLoopCount = nativeSourceLoopCount
        self.presentation = presentation
        self.thermal = thermal
        self.checks = checks
    }
}
