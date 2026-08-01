import Foundation

struct WorkbenchPerformanceSnapshot: Codable, Equatable, Identifiable {
    let id: UUID
    let workloadID: String
    let host: String
    let layout: String
    let itemCount: Int
    let uniqueAssetCount: Int
    let startedAt: Date
    let finishedAt: Date
    let frameSampleCount: Int
    let hitchCount: Int
    let maximumFrameIntervalMilliseconds: Double
    let initialPhysicalFootprintBytes: UInt64?
    let peakPhysicalFootprintBytes: UInt64?
    let finalPhysicalFootprintBytes: UInt64?

    var durationMilliseconds: Int {
        max(0, Int(finishedAt.timeIntervalSince(startedAt) * 1_000))
    }

    var peakFootprintDeltaBytes: UInt64? {
        guard let initialPhysicalFootprintBytes, let peakPhysicalFootprintBytes else { return nil }
        return peakPhysicalFootprintBytes >= initialPhysicalFootprintBytes
            ? peakPhysicalFootprintBytes - initialPhysicalFootprintBytes : 0
    }
}
