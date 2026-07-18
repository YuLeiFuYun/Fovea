import Foundation
import FoveaCore

public struct BenchmarkTargetDescriptor: Codable, Hashable, Sendable {
  public let width: Int
  public let height: Int

  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }
}

public struct BenchmarkSourceDescriptor: Codable, Hashable, Sendable {
  public let resourceID: String
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let byteCount: Int
  public let sha256: String

  public init(
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

public struct BenchmarkTraceEvent: Codable, Hashable, Sendable {
  public let sequence: Int
  public let elapsedNanoseconds: UInt64
  public let simulatedTimeMilliseconds: Int?
  public let category: String
  public let logicalIndex: Int?
  public let resourceID: String?
  public let target: BenchmarkTargetDescriptor?
  public let outcome: String?
  public let latencyNanoseconds: UInt64?
  public let decodedPixelCount: Int?
  public let physicalFootprintBytes: UInt64?

  public init(
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

public struct BenchmarkSummary: Codable, Hashable, Sendable {
  public let attemptedLoads: Int
  public let completedLoads: Int
  public let cancelledLoads: Int
  public let failedLoads: Int
  public let decodedMegapixels: Double
  public let sourceMegapixelsObserved: Double
  public let baselinePhysicalFootprintBytes: UInt64?
  public let peakPhysicalFootprintBytes: UInt64?
  public let physicalFootprintDeltaBytes: Int64?
  public let networkRequestCount: Int
  public let networkBytes: Int
  public let duplicateRequestCount: Int
  public let singleFlightJoinCount: Int
  public let fetchCancellationCount: Int
  public let originalEncodedHitCount: Int
  public let renderedMemoryHitCount: Int
  public let droppedDiagnosticEventCount: Int

  public init(
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

public struct BenchmarkSmokeArtifact: Codable, Hashable, Sendable {
  public let schemaVersion: Int
  public let workloadID: String
  public let profileID: String
  public let generatedAt: String
  public let platform: String
  public let architecture: String
  public let operatingSystem: String
  public let verifiedCommit: String
  public let datasetLogicalItemCount: Int
  public let uniqueResourceCount: Int
  public let cacheState: String
  public let sources: [BenchmarkSourceDescriptor]
  public let targets: [BenchmarkTargetDescriptor]
  public let trace: [BenchmarkTraceEvent]
  public let diagnostics: [RecordedDiagnosticEvent]
  public let summary: BenchmarkSummary

  public init(
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

public enum BenchmarkArtifactWriter {
  @discardableResult
  public static func write(
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
