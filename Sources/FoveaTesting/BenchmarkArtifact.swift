import Foundation
import FoveaCore

/// 可复现实验工件的目标、来源、事件和汇总数据模型。
/// 工件只保存稳定、脱敏且可跨运行比较的字段，不承载运行时对象身份。
package struct BenchmarkTargetDescriptor: Codable, Hashable, Sendable {
    package let width: Int
    package let height: Int

    package init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

package struct BenchmarkSourceDescriptor: Codable, Hashable, Sendable {
    package let resourceID: String
    package let pixelWidth: Int
    package let pixelHeight: Int
    package let byteCount: Int
    package let sha256: String

    package init(
        resourceID: String,
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int,
        sha256: String
    ) {
        self.resourceID = resourceID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

package struct BenchmarkTraceEvent: Codable, Hashable, Sendable {
    package let sequence: Int
    package let elapsedNanoseconds: UInt64
    package let simulatedTimeMilliseconds: Int?
    package let category: String
    package let logicalIndex: Int?
    package let resourceID: String?
    package let target: BenchmarkTargetDescriptor?
    package let outcome: String?
    package let latencyNanoseconds: UInt64?
    package let decodedPixelCount: Int?
    package let physicalFootprintBytes: UInt64?

    package init(
        sequence: Int,
        elapsedNanoseconds: UInt64,
        simulatedTimeMilliseconds: Int? = nil,
        category: String,
        logicalIndex: Int? = nil,
        resourceID: String? = nil,
        target: BenchmarkTargetDescriptor? = nil,
        outcome: String? = nil,
        latencyNanoseconds: UInt64? = nil,
        decodedPixelCount: Int? = nil,
        physicalFootprintBytes: UInt64? = nil
    ) {
        self.sequence = sequence
        self.elapsedNanoseconds = elapsedNanoseconds
        self.simulatedTimeMilliseconds = simulatedTimeMilliseconds
        self.category = category
        self.logicalIndex = logicalIndex
        self.resourceID = resourceID
        self.target = target
        self.outcome = outcome
        self.latencyNanoseconds = latencyNanoseconds
        self.decodedPixelCount = decodedPixelCount
        self.physicalFootprintBytes = physicalFootprintBytes
    }
}

package struct BenchmarkSummary: Codable, Hashable, Sendable {
    package let attemptedLoads: Int
    package let completedLoads: Int
    package let cancelledLoads: Int
    package let failedLoads: Int
    package let decodedMegapixels: Double
    package let sourceMegapixelsObserved: Double
    package let baselinePhysicalFootprintBytes: UInt64?
    package let peakPhysicalFootprintBytes: UInt64?
    package let physicalFootprintDeltaBytes: Int64?
    package let networkRequestCount: Int
    package let networkBytes: Int
    package let duplicateRequestCount: Int
    package let singleFlightJoinCount: Int
    package let fetchCancellationCount: Int
    package let originalEncodedHitCount: Int
    package let renderedMemoryHitCount: Int
    package let droppedDiagnosticEventCount: Int

    package init(
        attemptedLoads: Int,
        completedLoads: Int,
        cancelledLoads: Int,
        failedLoads: Int,
        decodedMegapixels: Double,
        sourceMegapixelsObserved: Double,
        baselinePhysicalFootprintBytes: UInt64?,
        peakPhysicalFootprintBytes: UInt64?,
        physicalFootprintDeltaBytes: Int64?,
        networkRequestCount: Int,
        networkBytes: Int,
        duplicateRequestCount: Int,
        singleFlightJoinCount: Int,
        fetchCancellationCount: Int,
        originalEncodedHitCount: Int,
        renderedMemoryHitCount: Int,
        droppedDiagnosticEventCount: Int
    ) {
        self.attemptedLoads = attemptedLoads
        self.completedLoads = completedLoads
        self.cancelledLoads = cancelledLoads
        self.failedLoads = failedLoads
        self.decodedMegapixels = decodedMegapixels
        self.sourceMegapixelsObserved = sourceMegapixelsObserved
        self.baselinePhysicalFootprintBytes = baselinePhysicalFootprintBytes
        self.peakPhysicalFootprintBytes = peakPhysicalFootprintBytes
        self.physicalFootprintDeltaBytes = physicalFootprintDeltaBytes
        self.networkRequestCount = networkRequestCount
        self.networkBytes = networkBytes
        self.duplicateRequestCount = duplicateRequestCount
        self.singleFlightJoinCount = singleFlightJoinCount
        self.fetchCancellationCount = fetchCancellationCount
        self.originalEncodedHitCount = originalEncodedHitCount
        self.renderedMemoryHitCount = renderedMemoryHitCount
        self.droppedDiagnosticEventCount = droppedDiagnosticEventCount
    }
}

package struct BenchmarkSmokeArtifact: Codable, Hashable, Sendable {
    package let schemaVersion: Int
    package let workloadID: String
    package let profileID: String
    package let generatedAt: String
    package let platform: String
    package let architecture: String
    package let operatingSystem: String
    package let verifiedCommit: String
    package let datasetLogicalItemCount: Int
    package let uniqueResourceCount: Int
    package let cacheState: String
    package let sources: [BenchmarkSourceDescriptor]
    package let targets: [BenchmarkTargetDescriptor]
    package let trace: [BenchmarkTraceEvent]
    package let diagnostics: [RecordedDiagnosticEvent]
    package let summary: BenchmarkSummary

    package init(
        workloadID: String,
        profileID: String,
        datasetLogicalItemCount: Int,
        uniqueResourceCount: Int,
        cacheState: String,
        sources: [BenchmarkSourceDescriptor],
        targets: [BenchmarkTargetDescriptor],
        trace: [BenchmarkTraceEvent],
        diagnostics: [RecordedDiagnosticEvent],
        summary: BenchmarkSummary
    ) {
        self.schemaVersion = 1
        self.workloadID = workloadID
        self.profileID = profileID
        self.generatedAt = ISO8601DateFormatter().string(from: Date())
        self.platform = BenchmarkEnvironment.platform
        self.architecture = BenchmarkEnvironment.architecture
        self.operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        self.verifiedCommit =
            ProcessInfo.processInfo.environment["FOVEA_VERIFIED_COMMIT"]
            ?? ProcessInfo.processInfo.environment["GITHUB_SHA"]
            ?? "unverified-local"
        self.datasetLogicalItemCount = datasetLogicalItemCount
        self.uniqueResourceCount = uniqueResourceCount
        self.cacheState = cacheState
        self.sources = sources
        self.targets = targets
        self.trace = trace
        self.diagnostics = diagnostics
        self.summary = summary
    }
}

package enum BenchmarkArtifactWriter {
    @discardableResult
    package static func write(
        _ artifact: BenchmarkSmokeArtifact,
        to directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename =
            "\(artifact.workloadID.lowercased())-\(artifact.platform.lowercased()).json"
            .replacingOccurrences(of: " ", with: "-")
        let destination = directory.appendingPathComponent(filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(artifact)
        try data.write(to: destination, options: [.atomic])
        return destination
    }
}

private enum BenchmarkEnvironment {
    static var platform: String {
        #if os(iOS) && targetEnvironment(simulator)
            return "iOS-Simulator"
        #elseif os(iOS)
            return "iOS-Device"
        #elseif os(macOS)
            return "macOS"
        #elseif os(tvOS) && targetEnvironment(simulator)
            return "tvOS-Simulator"
        #elseif os(watchOS) && targetEnvironment(simulator)
            return "watchOS-Simulator"
        #else
            return "Apple-Unknown"
        #endif
    }

    static var architecture: String {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            return "unknown"
        #endif
    }
}
