import ComparativeLabCore
import Foundation

@MainActor
enum W1FootprintOwnerIntervention: String, Codable, Sendable {
    case control = "WI-00"
    case cachePurge = "WI-10"
    case uiBackingRelease = "WI-01"
    case cachePurgeAndUIBackingRelease = "WI-11"

    var purgesMemoryCache: Bool {
        self == .cachePurge || self == .cachePurgeAndUIBackingRelease
    }

    var releasesUIBackings: Bool {
        self == .uiBackingRelease || self == .cachePurgeAndUIBackingRelease
    }

    static func requestedFromEnvironment() throws -> Self? {
        guard let raw = ProcessInfo.processInfo.environment["FOVEA_W1_OWNER_INTERVENTION"] else {
            return nil
        }
        guard let value = Self(rawValue: raw) else {
            throw BenchmarkAppError.runFailed("invalid-w1-owner-intervention")
        }
        return value
    }
}

struct W1FootprintBackingMetadata {
    let imageIdentity: ObjectIdentifier
    let providerIdentity: ObjectIdentifier?
    let pixelWidth: Int
    let pixelHeight: Int
    let bytesPerRow: Int
    let estimatedByteCount: Int
}

struct W1FootprintOwnerPhaseSample: Codable, Sendable {
    let label: String
    let uptimeNanoseconds: UInt64
    let physicalFootprintBytes: UInt64
}

struct W1FootprintOwnerSettleSample: Codable, Sendable {
    let label: String
    let actualElapsedNanoseconds: UInt64
    let physicalFootprintBytes: UInt64
}

struct W1FootprintBackingIdentityRecord: Codable, Sendable {
    let backingOrdinal: Int
    let identityKind: String
    let imageIdentityOrdinals: [Int]
    let visibleOwnerCount: Int
    let estimatedCPUBackingBytes: Int
}

struct W1FootprintVisibleBackingSnapshot: Codable, Sendable {
    let visibleCellCount: Int
    let visibleBackingOwnerCount: Int
    let uniqueImageIdentityCount: Int
    let uniqueBackingIdentityCount: Int
    let estimatedUniqueCPUBackingBytes: Int
    let backings: [W1FootprintBackingIdentityRecord]
}

private struct W1FootprintBackingKey: Hashable {
    enum Kind: String {
        case provider
        case image
    }

    let kind: Kind
    let identity: ObjectIdentifier
}

private struct W1FootprintBackingAccumulator {
    var imageIdentities: Set<ObjectIdentifier> = []
    var visibleOwnerCount = 0
    var estimatedCPUBackingBytes = 0
}

struct W1FootprintOwnerRawCell {
    let intervention: W1FootprintOwnerIntervention
    let preInterventionPhysicalFootprintBytes: UInt64
    let settleSamples: [W1FootprintOwnerSettleSample]
    let phaseSamples: [W1FootprintOwnerPhaseSample]
    let visibleBackingSnapshot: W1FootprintVisibleBackingSnapshot
    let releasedUIBackingOwnerCount: Int
    let interventionDurationNanoseconds: UInt64
}

struct W1FootprintOwnerCellArtifact: Codable, Sendable {
    let schema: Int
    let contract: String
    let interventionID: String
    let preInterventionPhysicalFootprintBytes: UInt64
    let settleSamples: [W1FootprintOwnerSettleSample]
    let hitchCount: Int
    let hitchExcessNanoseconds: UInt64
    let phaseSamples: [W1FootprintOwnerPhaseSample]
    let visibleBackingSnapshot: W1FootprintVisibleBackingSnapshot
    let releasedUIBackingOwnerCount: Int
    let interventionDurationNanoseconds: UInt64

    init(
        rawCell: W1FootprintOwnerRawCell,
        hitchCount: Int,
        hitchExcessNanoseconds: UInt64
    ) {
        schema = 1
        contract = "w1-footprint-owner-attribution-v1"
        interventionID = rawCell.intervention.rawValue
        preInterventionPhysicalFootprintBytes = rawCell.preInterventionPhysicalFootprintBytes
        settleSamples = rawCell.settleSamples
        self.hitchCount = hitchCount
        self.hitchExcessNanoseconds = hitchExcessNanoseconds
        phaseSamples = rawCell.phaseSamples
        visibleBackingSnapshot = rawCell.visibleBackingSnapshot
        releasedUIBackingOwnerCount = rawCell.releasedUIBackingOwnerCount
        interventionDurationNanoseconds = rawCell.interventionDurationNanoseconds
    }
}

@MainActor
enum W1FootprintOwnerAttributionStore {
    private static var pending: W1FootprintOwnerRawCell?

    static func publish(_ cell: W1FootprintOwnerRawCell) throws {
        guard pending == nil else {
            throw BenchmarkAppError.runFailed("duplicate-w1-owner-cell")
        }
        pending = cell
    }

    static func take() -> W1FootprintOwnerRawCell? {
        defer { pending = nil }
        return pending
    }
}

@MainActor
final class W1FootprintOwnerAttributionRecorder {
    private static let settleSchedule: [(label: String, nanoseconds: UInt64)] = [
        ("immediate", 0),
        ("50ms", 50_000_000),
        ("250ms", 250_000_000),
        ("1000ms", 1_000_000_000),
    ]

    let intervention: W1FootprintOwnerIntervention
    private var phaseSamples: [W1FootprintOwnerPhaseSample] = []

    init(intervention: W1FootprintOwnerIntervention) {
        self.intervention = intervention
    }

    func recordPhase(_ label: String) throws {
        phaseSamples.append(try Self.forcePhaseSample(label: label))
    }

    func runIntervention(
        adapter: any ComparatorAdapter,
        visibleCellCount: Int,
        visibleBackings: [W1FootprintBackingMetadata],
        releaseUIBackings: () -> Int
    ) async throws {
        let preSample = try Self.forcePhaseSample(label: "pre-intervention-visible-state")
        phaseSamples.append(preSample)
        let visibleSnapshot = Self.visibleBackingSnapshot(
            visibleCellCount: visibleCellCount,
            metadata: visibleBackings
        )

        let interventionStartedAt = DispatchTime.now().uptimeNanoseconds
        if intervention.purgesMemoryCache {
            await adapter.purgeMemory()
        }
        let releasedUIBackingOwnerCount =
            intervention.releasesUIBackings ? releaseUIBackings() : 0
        let settleStartedAt = DispatchTime.now().uptimeNanoseconds
        let interventionDuration = settleStartedAt &- interventionStartedAt
        phaseSamples.append(try Self.forcePhaseSample(label: "post-intervention"))

        var settleSamples: [W1FootprintOwnerSettleSample] = []
        settleSamples.reserveCapacity(Self.settleSchedule.count)
        for point in Self.settleSchedule {
            try await Self.sleepUntil(
                startNanoseconds: settleStartedAt,
                targetElapsedNanoseconds: point.nanoseconds
            )
            let sampledAt = DispatchTime.now().uptimeNanoseconds
            guard let footprint = PhysicalFootprintSampler.current() else {
                throw BenchmarkAppError.runFailed("w1-owner-phys-footprint-unavailable")
            }
            settleSamples.append(
                W1FootprintOwnerSettleSample(
                    label: point.label,
                    actualElapsedNanoseconds: sampledAt &- settleStartedAt,
                    physicalFootprintBytes: footprint
                )
            )
        }

        try W1FootprintOwnerAttributionStore.publish(
            W1FootprintOwnerRawCell(
                intervention: intervention,
                preInterventionPhysicalFootprintBytes: preSample.physicalFootprintBytes,
                settleSamples: settleSamples,
                phaseSamples: phaseSamples,
                visibleBackingSnapshot: visibleSnapshot,
                releasedUIBackingOwnerCount: releasedUIBackingOwnerCount,
                interventionDurationNanoseconds: interventionDuration
            )
        )
    }

    private static func forcePhaseSample(label: String) throws -> W1FootprintOwnerPhaseSample {
        let sampledAt = DispatchTime.now().uptimeNanoseconds
        guard let footprint = PhysicalFootprintSampler.current() else {
            throw BenchmarkAppError.runFailed("w1-owner-phys-footprint-unavailable")
        }
        return W1FootprintOwnerPhaseSample(
            label: label,
            uptimeNanoseconds: sampledAt,
            physicalFootprintBytes: footprint
        )
    }

    private static func sleepUntil(
        startNanoseconds: UInt64,
        targetElapsedNanoseconds: UInt64
    ) async throws {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now &- startNanoseconds
        guard targetElapsedNanoseconds > elapsed else { return }
        try await Task.sleep(nanoseconds: targetElapsedNanoseconds - elapsed)
    }

    private static func visibleBackingSnapshot(
        visibleCellCount: Int,
        metadata: [W1FootprintBackingMetadata]
    ) -> W1FootprintVisibleBackingSnapshot {
        var imageOrdinals: [ObjectIdentifier: Int] = [:]
        var backingAccumulators: [W1FootprintBackingKey: W1FootprintBackingAccumulator] = [:]

        for item in metadata {
            if imageOrdinals[item.imageIdentity] == nil {
                imageOrdinals[item.imageIdentity] = imageOrdinals.count + 1
            }
            let key: W1FootprintBackingKey
            if let providerIdentity = item.providerIdentity {
                key = W1FootprintBackingKey(kind: .provider, identity: providerIdentity)
            } else {
                key = W1FootprintBackingKey(kind: .image, identity: item.imageIdentity)
            }
            var accumulator = backingAccumulators[key] ?? W1FootprintBackingAccumulator()
            accumulator.imageIdentities.insert(item.imageIdentity)
            accumulator.visibleOwnerCount += 1
            accumulator.estimatedCPUBackingBytes = max(
                accumulator.estimatedCPUBackingBytes,
                item.estimatedByteCount
            )
            backingAccumulators[key] = accumulator
        }

        let sortedKeys = backingAccumulators.keys.sorted { lhs, rhs in
            if lhs.kind.rawValue != rhs.kind.rawValue {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            let lhsImages =
                backingAccumulators[lhs]?.imageIdentities.compactMap {
                    imageOrdinals[$0]
                }.sorted() ?? []
            let rhsImages =
                backingAccumulators[rhs]?.imageIdentities.compactMap {
                    imageOrdinals[$0]
                }.sorted() ?? []
            return lhsImages.lexicographicallyPrecedes(rhsImages)
        }

        var totalEstimatedBytes = 0
        let records = sortedKeys.enumerated().map { offset, key in
            let accumulator = backingAccumulators[key] ?? W1FootprintBackingAccumulator()
            totalEstimatedBytes = saturatingAdd(
                totalEstimatedBytes,
                accumulator.estimatedCPUBackingBytes
            )
            return W1FootprintBackingIdentityRecord(
                backingOrdinal: offset + 1,
                identityKind: key.kind.rawValue,
                imageIdentityOrdinals: accumulator.imageIdentities.compactMap { imageOrdinals[$0] }
                    .sorted(),
                visibleOwnerCount: accumulator.visibleOwnerCount,
                estimatedCPUBackingBytes: accumulator.estimatedCPUBackingBytes
            )
        }

        return W1FootprintVisibleBackingSnapshot(
            visibleCellCount: max(0, visibleCellCount),
            visibleBackingOwnerCount: metadata.count,
            uniqueImageIdentityCount: imageOrdinals.count,
            uniqueBackingIdentityCount: records.count,
            estimatedUniqueCPUBackingBytes: totalEstimatedBytes,
            backings: records
        )
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : value
    }
}
