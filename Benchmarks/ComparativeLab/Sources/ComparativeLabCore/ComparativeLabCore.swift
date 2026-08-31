import CoreGraphics
import Foundation

public enum ComparativeLabError: Error, Equatable, Sendable {
    case invalidCommit
    case invalidIdentifier
    case invalidPixelTarget
    case invalidMeasurement
}

public enum ComparatorSourceKind: String, Codable, Equatable, Sendable {
    case gitCommit = "git-commit"
    case platformBuild = "platform-build"
}

public struct ComparatorPlatformBuildIdentity: Codable, Equatable, Sendable {
    public let xcodeBuild: String
    public let osBuild: String
    public let deviceProfileID: String

    public init(xcodeBuild: String, osBuild: String, deviceProfileID: String) throws {
        let values = [xcodeBuild, osBuild, deviceProfileID].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard values.allSatisfy({ !$0.isEmpty && $0.count <= 128 && !$0.contains("://") })
        else {
            throw ComparativeLabError.invalidIdentifier
        }
        self.xcodeBuild = values[0]
        self.osBuild = values[1]
        self.deviceProfileID = values[2]
    }
}

public struct ComparatorIdentity: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let sourceKind: ComparatorSourceKind
    public let exactCommit: String?
    public let sourceTreeDigest: String?
    public let includesWorkingTreeChanges: Bool
    public let platformBuild: ComparatorPlatformBuildIdentity?

    public init(
        name: String,
        version: String,
        exactCommit: String,
        sourceTreeDigest: String? = nil,
        includesWorkingTreeChanges: Bool = false
    ) throws {
        let fields = try Self.validatedFields(name: name, version: version)
        guard exactCommit.count == 40,
            exactCommit.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else {
            throw ComparativeLabError.invalidCommit
        }
        if let sourceTreeDigest {
            guard sourceTreeDigest.count == 64,
                sourceTreeDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
            else {
                throw ComparativeLabError.invalidCommit
            }
        }
        guard !includesWorkingTreeChanges || sourceTreeDigest != nil else {
            throw ComparativeLabError.invalidCommit
        }
        self.name = fields.name
        self.version = fields.version
        self.sourceKind = .gitCommit
        self.exactCommit = exactCommit
        self.sourceTreeDigest = sourceTreeDigest
        self.includesWorkingTreeChanges = includesWorkingTreeChanges
        self.platformBuild = nil
    }

    public init(
        name: String,
        version: String,
        platformBuild: ComparatorPlatformBuildIdentity
    ) throws {
        let fields = try Self.validatedFields(name: name, version: version)
        self.name = fields.name
        self.version = fields.version
        self.sourceKind = .platformBuild
        self.exactCommit = nil
        self.sourceTreeDigest = nil
        self.includesWorkingTreeChanges = false
        self.platformBuild = platformBuild
    }

    private static func validatedFields(
        name: String,
        version: String
    ) throws -> (name: String, version: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64, !version.isEmpty, version.count <= 64 else {
            throw ComparativeLabError.invalidIdentifier
        }
        return (name, version)
    }
}

public struct ComparatorPixelTarget: Codable, Equatable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        guard (1...32_768).contains(width), (1...32_768).contains(height) else {
            throw ComparativeLabError.invalidPixelTarget
        }
        let (_, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow else { throw ComparativeLabError.invalidPixelTarget }
        self.width = width
        self.height = height
    }
}

public enum ComparatorPriority: String, Codable, Sendable {
    case background
    case utility
    case visible
    case immediate
}

public enum ComparatorContentMode: String, Codable, Sendable {
    case aspectFit
    case aspectFill
}

public struct ComparatorRequest: Sendable {
    public let resourceID: String
    public let url: URL
    public let target: ComparatorPixelTarget
    public let contentMode: ComparatorContentMode
    public let priority: ComparatorPriority
    public let securityNamespace: String
    public let headers: [String: String]

    public init(
        resourceID: String,
        url: URL,
        target: ComparatorPixelTarget,
        contentMode: ComparatorContentMode,
        priority: ComparatorPriority,
        securityNamespace: String = "public",
        headers: [String: String] = [:]
    ) throws {
        let resourceID = resourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resourceID.isEmpty, resourceID.count <= 256 else {
            throw ComparativeLabError.invalidIdentifier
        }
        guard url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost" else {
            throw ComparativeLabError.invalidIdentifier
        }
        let namespace = securityNamespace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !namespace.isEmpty, namespace.count <= 128, !namespace.contains("://") else {
            throw ComparativeLabError.invalidIdentifier
        }
        guard headers.count <= 16 else { throw ComparativeLabError.invalidIdentifier }
        var normalizedHeaders: [String: String] = [:]
        var headerBytes = 0
        for (rawName, value) in headers {
            let name = rawName.lowercased()
            guard !name.isEmpty,
                name.utf8.allSatisfy({ byte in
                    (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122) || byte == 45
                }), !value.contains("\r"), !value.contains("\n")
            else {
                throw ComparativeLabError.invalidIdentifier
            }
            headerBytes += name.utf8.count + value.utf8.count
            guard headerBytes <= 4_096, normalizedHeaders[name] == nil else {
                throw ComparativeLabError.invalidIdentifier
            }
            normalizedHeaders[name] = value
        }
        self.resourceID = resourceID
        self.url = url
        self.target = target
        self.contentMode = contentMode
        self.priority = priority
        self.securityNamespace = namespace
        self.headers = normalizedHeaders
    }

    public var scopedCacheKey: String {
        "\(securityNamespace)|\(resourceID)"
    }
}

public enum ComparatorOutcome: String, Codable, Sendable {
    case completed
    case cancelled
    case failed
}

public enum ComparatorCacheSource: String, Codable, Sendable {
    case network
    case memory
    case disk
    case unknown
}

public struct ComparatorLoadResult: Codable, Equatable, Sendable {
    public let outcome: ComparatorOutcome
    public let cacheSource: ComparatorCacheSource
    public let latencyNanoseconds: UInt64
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let receivedBytes: Int?
    public let failureCategory: String?
    /// Cost of forcing the returned CGImage through a complete normalized pixel draw.
    public let pixelMaterializationNanoseconds: UInt64?
    /// Harness-observed latency from request construction through complete pixel materialization.
    public let displayReadyLatencyNanoseconds: UInt64?

    public init(
        outcome: ComparatorOutcome,
        cacheSource: ComparatorCacheSource,
        latencyNanoseconds: UInt64,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        receivedBytes: Int? = nil,
        failureCategory: String? = nil,
        pixelMaterializationNanoseconds: UInt64? = nil,
        displayReadyLatencyNanoseconds: UInt64? = nil
    ) throws {
        let hasPixelMaterialization = pixelMaterializationNanoseconds != nil
        let hasDisplayReady = displayReadyLatencyNanoseconds != nil
        guard pixelWidth.map({ (0...32_768).contains($0) }) ?? true,
            pixelHeight.map({ (0...32_768).contains($0) }) ?? true,
            receivedBytes.map({ $0 >= 0 }) ?? true,
            failureCategory.map({ !$0.contains("://") && $0.count <= 96 }) ?? true,
            hasPixelMaterialization == hasDisplayReady,
            !hasPixelMaterialization || outcome == .completed,
            displayReadyLatencyNanoseconds.map({ $0 >= latencyNanoseconds }) ?? true,
            displayReadyLatencyNanoseconds.map({ ready in
                pixelMaterializationNanoseconds.map({ ready >= $0 }) ?? false
            }) ?? true
        else {
            throw ComparativeLabError.invalidMeasurement
        }
        self.outcome = outcome
        self.cacheSource = cacheSource
        self.latencyNanoseconds = latencyNanoseconds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.receivedBytes = receivedBytes
        self.failureCategory = failureCategory
        self.pixelMaterializationNanoseconds = pixelMaterializationNanoseconds
        self.displayReadyLatencyNanoseconds = displayReadyLatencyNanoseconds
    }
}

public struct ComparatorRenderImage: @unchecked Sendable {
    public let cgImage: CGImage

    public init(cgImage: CGImage) {
        self.cgImage = cgImage
    }
}

public struct ComparatorLoadOutput: @unchecked Sendable {
    public let measurement: ComparatorLoadResult
    public let image: ComparatorRenderImage?

    public init(measurement: ComparatorLoadResult, image: ComparatorRenderImage?) {
        self.measurement = measurement
        self.image = image
    }
}

public final class ComparatorPreparationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var prepared = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func markPrepared() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !prepared else { return [] }
            prepared = true
            let values = waiters
            waiters.removeAll(keepingCapacity: false)
            return values
        }
        for continuation in continuations { continuation.resume() }
    }

    public func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if prepared { return true }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }
}

public struct ComparatorLoad: Sendable {
    private let cancelOperation: @Sendable () -> Void
    private let preparationOperation: @Sendable () async throws -> Void
    private let resultOperation: @Sendable () async -> ComparatorLoadOutput

    public init(
        cancel: @escaping @Sendable () -> Void,
        waitUntilPrepared: @escaping @Sendable () async throws -> Void = {},
        result: @escaping @Sendable () async -> ComparatorLoadOutput
    ) {
        self.cancelOperation = cancel
        self.preparationOperation = waitUntilPrepared
        self.resultOperation = result
    }

    public func cancel() {
        cancelOperation()
    }

    public func waitUntilPrepared() async throws {
        try await preparationOperation()
    }

    public func result() async -> ComparatorLoadOutput {
        await resultOperation()
    }
}

public enum ComparatorProgressiveFrameKind: String, Codable, Equatable, Sendable {
    case preview
    case final
}

public struct ComparatorProgressiveFrameMeasurement: Codable, Equatable, Sendable {
    public let sequence: Int
    public let kind: ComparatorProgressiveFrameKind
    public let elapsedNanoseconds: UInt64
    public let receivedBytes: Int?
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        sequence: Int,
        kind: ComparatorProgressiveFrameKind,
        elapsedNanoseconds: UInt64,
        receivedBytes: Int? = nil,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws {
        guard sequence >= 0, receivedBytes.map({ $0 >= 0 }) ?? true,
            (1...32_768).contains(pixelWidth), (1...32_768).contains(pixelHeight)
        else {
            throw ComparativeLabError.invalidMeasurement
        }
        self.sequence = sequence
        self.kind = kind
        self.elapsedNanoseconds = elapsedNanoseconds
        self.receivedBytes = receivedBytes
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public struct ComparatorProgressiveFrame: @unchecked Sendable {
    public let measurement: ComparatorProgressiveFrameMeasurement
    public let image: ComparatorRenderImage

    public init(
        measurement: ComparatorProgressiveFrameMeasurement,
        image: ComparatorRenderImage
    ) {
        self.measurement = measurement
        self.image = image
    }
}

public struct ComparatorProgressiveLoad: Sendable {
    private let cancelOperation: @Sendable () -> Void
    public let frames: AsyncThrowingStream<ComparatorProgressiveFrame, any Error>

    public init(
        cancel: @escaping @Sendable () -> Void,
        frames: AsyncThrowingStream<ComparatorProgressiveFrame, any Error>
    ) {
        self.cancelOperation = cancel
        self.frames = frames
    }

    public func cancel() {
        cancelOperation()
    }
}

public protocol ComparatorProgressiveAdapter: ComparatorAdapter {
    func makeProgressiveLoad(_ request: ComparatorRequest) async throws
        -> ComparatorProgressiveLoad
}

/// Optional, non-timed diagnostic timeline exported only by adapters that can provide a bounded
/// source-level trace. Events are comparator-neutral so shared workloads never import a library's
/// private diagnostics types. Clean comparator runs do not require or query this protocol.
public struct ComparatorDiagnosticEvent: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let elapsedNanoseconds: UInt64
    public let kind: String
    public let keyDigest: String?
    public let byteCount: Int?
    public let itemCount: Int?
    public let durationNanoseconds: UInt64?
    public let reason: String?
    public let requestedPriority: Int?
    public let effectivePriority: Int?

    public init(
        sequence: UInt64,
        elapsedNanoseconds: UInt64,
        kind: String,
        keyDigest: String? = nil,
        byteCount: Int? = nil,
        itemCount: Int? = nil,
        durationNanoseconds: UInt64? = nil,
        reason: String? = nil,
        requestedPriority: Int? = nil,
        effectivePriority: Int? = nil
    ) {
        self.sequence = sequence
        self.elapsedNanoseconds = elapsedNanoseconds
        self.kind = kind
        self.keyDigest = keyDigest
        self.byteCount = byteCount
        self.itemCount = itemCount
        self.durationNanoseconds = durationNanoseconds
        self.reason = reason
        self.requestedPriority = requestedPriority
        self.effectivePriority = effectivePriority
    }
}

public protocol ComparatorDiagnosticAdapter: ComparatorAdapter {
    /// Returns only measured-workload events; cache-preparation/setup events stay outside the
    /// returned sequence window. Implementations may return an empty array when diagnostics are
    /// disabled.
    func diagnosticEvents() async -> [ComparatorDiagnosticEvent]
}

/// Stable, comparator-neutral attestation of the effective runtime configuration used by one
/// adapter process. Only values that can affect semantics, scheduling, transport, cache behavior,
/// decoding or resource cost belong here. The map is deliberately flat so evidence consumers can
/// compare it exactly without knowing a comparator's private object graph.
public struct ComparatorRuntimeConfiguration: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let parameters: [String: String]

    public init(parameters: [String: String]) throws {
        guard !parameters.isEmpty, parameters.count <= 96,
            parameters.allSatisfy({ key, value in
                !key.isEmpty && key.count <= 160 && !key.contains("://")
                    && value.count <= 2048 && !value.contains("\r") && !value.contains("\n")
            })
        else {
            throw ComparativeLabError.invalidIdentifier
        }
        self.schemaVersion = 1
        self.parameters = parameters
    }
}

public protocol ComparatorAdapter: Sendable {
    var identity: ComparatorIdentity { get }
    var runtimeConfiguration: ComparatorRuntimeConfiguration? { get }

    func makeLoad(_ request: ComparatorRequest) async throws -> ComparatorLoad
    func purgeMemory() async
    func purgeDisk() async throws
    func finishCachePreparation() async throws
    func cachePreparationDiagnostics() async -> [String: Int]
    func revoke(namespace: String) async throws
    func cancelAll() async
}

extension ComparatorAdapter {
    /// Older/non-headless surfaces remain source-compatible, but formal ComparativeLab evidence
    /// can require a non-nil attestation before importing a result.
    public var runtimeConfiguration: ComparatorRuntimeConfiguration? { nil }

    /// Allows adapters with asynchronous cache synthesis to finish preparation before timed work.
    /// Comparators whose cache writes complete with their load operation require no barrier.
    public func finishCachePreparation() async throws {}

    /// Additive, non-timed cache-preparation diagnostics for exploratory attribution.
    public func cachePreparationDiagnostics() async -> [String: Int] { [:] }
}

public enum ComparativeWorkloadID: String, Codable, CaseIterable, Sendable {
    case w1FeedScroll = "W1-SCROLL-V1"
    case w2DetailHero = "W2-HERO-V1"
    case w3AuthGallery = "W3-AUTH-V1"
    case w4ProgressiveJPEG = "W4-PROGRESSIVE-JPEG-V1"
    case w5AnimatedMedia = "W5-ANIMATED-MEDIA-V1"
    case w7ThousandConcurrent = "W7-THOUSAND-CONCURRENT-V1"
}

public enum DeviceEvidenceRole: String, Codable, Sendable {
    case primaryCurrentMid = "primary-current-mid"
    case secondaryLowerPerformance = "secondary-lower-performance"
}

public enum OSReleaseChannel: String, Codable, Sendable {
    case beta
    case stable
}

public struct ComparatorRunEnvironment: Codable, Equatable, Sendable {
    public let deviceProfileID: String
    public let deviceRole: DeviceEvidenceRole
    public let osFamily: String
    public let osVersion: String
    public let osBuild: String
    public let osChannel: OSReleaseChannel

    public init(
        deviceProfileID: String,
        deviceRole: DeviceEvidenceRole,
        osFamily: String,
        osVersion: String,
        osBuild: String,
        osChannel: OSReleaseChannel
    ) throws {
        let fields = [deviceProfileID, osFamily, osVersion, osBuild]
        guard fields.allSatisfy({ !$0.isEmpty && $0.count <= 128 && !$0.contains("://") }) else {
            throw ComparativeLabError.invalidIdentifier
        }
        self.deviceProfileID = deviceProfileID
        self.deviceRole = deviceRole
        self.osFamily = osFamily
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.osChannel = osChannel
    }

    public var permitsReleaseClaim: Bool {
        osChannel == .stable
    }
}

public struct ComparatorObservation: Codable, Equatable, Sendable {
    public let sequence: Int
    public let resourceID: String
    public let target: ComparatorPixelTarget
    public let result: ComparatorLoadResult

    public init(
        sequence: Int,
        resourceID: String,
        target: ComparatorPixelTarget,
        result: ComparatorLoadResult
    ) throws {
        guard sequence >= 0, !resourceID.isEmpty, resourceID.count <= 256,
            !resourceID.contains("://")
        else {
            throw ComparativeLabError.invalidMeasurement
        }
        self.sequence = sequence
        self.resourceID = resourceID
        self.target = target
        self.result = result
    }
}

public struct ComparatorRunArtifact: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let workloadID: ComparativeWorkloadID
    public let comparator: ComparatorIdentity
    public let environment: ComparatorRunEnvironment
    public let runIndex: Int
    public let datasetDigest: String
    public let observations: [ComparatorObservation]
    public let provisional: Bool

    public init(
        workloadID: ComparativeWorkloadID,
        comparator: ComparatorIdentity,
        environment: ComparatorRunEnvironment,
        runIndex: Int,
        datasetDigest: String,
        observations: [ComparatorObservation]
    ) throws {
        guard runIndex >= 0,
            datasetDigest.count == 64,
            datasetDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
            !observations.isEmpty,
            observations.map(\.sequence) == Array(observations.indices)
        else {
            throw ComparativeLabError.invalidMeasurement
        }
        self.schemaVersion = 1
        self.workloadID = workloadID
        self.comparator = comparator
        self.environment = environment
        self.runIndex = runIndex
        self.datasetDigest = datasetDigest
        self.observations = observations
        self.provisional = !environment.permitsReleaseClaim
    }
}
