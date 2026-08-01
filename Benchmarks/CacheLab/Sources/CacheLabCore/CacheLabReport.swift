import Foundation

public struct CacheLabRunRecord: Codable, Sendable {
    public let repetition: Int
    public let memoryHotScan: [MemoryHotScanResult]
    public let memoryConcurrent: [MemoryConcurrentResult]
    public let diskMixed: [DiskMixedResult]

    public init(
        repetition: Int,
        memoryHotScan: [MemoryHotScanResult],
        memoryConcurrent: [MemoryConcurrentResult],
        diskMixed: [DiskMixedResult]
    ) {
        self.repetition = repetition
        self.memoryHotScan = memoryHotScan
        self.memoryConcurrent = memoryConcurrent
        self.diskMixed = diskMixed
    }
}

public struct CacheLabReport: Codable, Sendable {
    public let schemaVersion: Int
    public let planID: String
    public let executionMode: String
    public let provisional: Bool
    public let sourceIdentity: [String: String]
    public let experimentPlanDigest: String
    public let claimFamilyDigest: String
    public let diskCorrectness: [DiskCorrectnessResult]
    public let runs: [CacheLabRunRecord]

    public init(
        executionMode: String,
        provisional: Bool,
        sourceIdentity: [String: String],
        experimentPlanDigest: String,
        claimFamilyDigest: String,
        diskCorrectness: [DiskCorrectnessResult],
        runs: [CacheLabRunRecord]
    ) {
        self.schemaVersion = 3
        self.planID = "FOVEA-CACHE-LAB-V2"
        self.executionMode = executionMode
        self.provisional = provisional
        self.sourceIdentity = sourceIdentity
        self.experimentPlanDigest = experimentPlanDigest
        self.claimFamilyDigest = claimFamilyDigest
        self.diskCorrectness = diskCorrectness
        self.runs = runs
    }
}
