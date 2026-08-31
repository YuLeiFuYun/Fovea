import Foundation

/// A normalized, infinitely repeating source-frame timeline for cross-player presentation scoring.
///
/// The oracle intentionally starts at source frame zero. Startup latency is measured separately; callers
/// normalize display observations so the first visible source frame is observation zero at elapsed time zero.
public struct AnimatedPresentationTimeline: Codable, Equatable, Sendable {
    public let frameDurationsNanoseconds: [UInt64]
    public let totalDurationNanoseconds: UInt64
    private let frameStartOffsetsNanoseconds: [UInt64]

    private enum CodingKeys: String, CodingKey {
        case frameDurationsNanoseconds
    }

    public init(frameDurationsNanoseconds: [UInt64]) throws {
        guard (2...100_000).contains(frameDurationsNanoseconds.count),
            frameDurationsNanoseconds.allSatisfy({ $0 > 0 })
        else {
            throw ComparativeLabError.invalidMeasurement
        }

        var starts: [UInt64] = []
        starts.reserveCapacity(frameDurationsNanoseconds.count)
        var total: UInt64 = 0
        for duration in frameDurationsNanoseconds {
            starts.append(total)
            let sum = total.addingReportingOverflow(duration)
            guard !sum.overflow else { throw ComparativeLabError.invalidMeasurement }
            total = sum.partialValue
        }
        guard total > 0 else { throw ComparativeLabError.invalidMeasurement }

        self.frameDurationsNanoseconds = frameDurationsNanoseconds
        self.totalDurationNanoseconds = total
        self.frameStartOffsetsNanoseconds = starts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let durations = try container.decode([UInt64].self, forKey: .frameDurationsNanoseconds)
        try self.init(frameDurationsNanoseconds: durations)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frameDurationsNanoseconds, forKey: .frameDurationsNanoseconds)
    }

    public var frameCount: Int { frameDurationsNanoseconds.count }

    fileprivate func absoluteFrameOrdinal(at elapsedNanoseconds: UInt64) throws -> UInt64 {
        let loopIndex = elapsedNanoseconds / totalDurationNanoseconds
        let loopOffset = elapsedNanoseconds % totalDurationNanoseconds
        let frameIndex = frameIndex(atLoopOffsetNanoseconds: loopOffset)
        let product = loopIndex.multipliedReportingOverflow(by: UInt64(frameCount))
        guard !product.overflow else { throw ComparativeLabError.invalidMeasurement }
        let sum = product.partialValue.addingReportingOverflow(UInt64(frameIndex))
        guard !sum.overflow else { throw ComparativeLabError.invalidMeasurement }
        return sum.partialValue
    }

    fileprivate func startTimeNanoseconds(forAbsoluteFrameOrdinal ordinal: UInt64) throws -> UInt64
    {
        let frameCount = UInt64(frameCount)
        let loopIndex = ordinal / frameCount
        let frameIndex = Int(ordinal % frameCount)
        let loopStart = loopIndex.multipliedReportingOverflow(by: totalDurationNanoseconds)
        guard !loopStart.overflow else { throw ComparativeLabError.invalidMeasurement }
        let start = loopStart.partialValue.addingReportingOverflow(
            frameStartOffsetsNanoseconds[frameIndex]
        )
        guard !start.overflow else { throw ComparativeLabError.invalidMeasurement }
        return start.partialValue
    }

    private func frameIndex(atLoopOffsetNanoseconds offset: UInt64) -> Int {
        var lower = 0
        var upper = frameStartOffsetsNanoseconds.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if frameStartOffsetsNanoseconds[middle] <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return max(0, lower - 1)
    }
}

/// One source-frame presentation/change observation after startup normalization.
///
/// `frameIndex` must identify the source frame rendered by the comparator, not a decoder-internal cache key.
/// `mainThreadCallbackNanoseconds` is optional so the same oracle can score players that cannot expose a
/// callback duration without changing their execution path.
public struct AnimatedPresentationObservation: Codable, Equatable, Sendable {
    public let sequence: Int
    public let elapsedNanoseconds: UInt64
    public let frameIndex: Int
    public let mainThreadCallbackNanoseconds: UInt64?

    public init(
        sequence: Int,
        elapsedNanoseconds: UInt64,
        frameIndex: Int,
        mainThreadCallbackNanoseconds: UInt64? = nil
    ) throws {
        guard sequence >= 0, frameIndex >= 0 else {
            throw ComparativeLabError.invalidMeasurement
        }
        self.sequence = sequence
        self.elapsedNanoseconds = elapsedNanoseconds
        self.frameIndex = frameIndex
        self.mainThreadCallbackNanoseconds = mainThreadCallbackNanoseconds
    }
}

/// Comparator-neutral presentation quality summary derived only from display observations and the source
/// timeline. All players are scored with the same rules; no Fovea-internal dropped-frame counters enter it.
public struct AnimatedPresentationScore: Codable, Equatable, Sendable {
    public let observationCount: Int
    public let transitionCount: Int
    public let frameStateMismatchObservationCount: Int
    public let staleObservationCount: Int
    public let aheadObservationCount: Int
    public let frameOrderViolationCount: Int
    public let observedSkippedSourceFrameCount: UInt64
    public let missedDeadlineCount: Int
    public let earlyDeadlineCount: Int
    public let maximumBehindFrameCount: UInt64
    public let maximumAheadFrameCount: UInt64
    public let p50AbsoluteTimingErrorNanoseconds: UInt64?
    public let p95AbsoluteTimingErrorNanoseconds: UInt64?
    public let maximumAbsoluteTimingErrorNanoseconds: UInt64?
    public let callbackSampleCount: Int
    public let p95MainThreadCallbackNanoseconds: UInt64?
    public let maximumMainThreadCallbackNanoseconds: UInt64?
}

public enum AnimatedPresentationOracle {
    /// Scores a presentation trace against a normalized repeating timeline.
    ///
    /// The first real comparator callback defines phase zero and may refer to any valid source frame. The oracle
    /// rotates the source timeline to that frame without synthesizing a callback or changing the player's
    /// behavior. Collecting one full source progression therefore still scores every transition boundary even
    /// when libraries expose different initial callback semantics. A late transition misses its deadline only
    /// when lateness is strictly greater than the caller's preregistered tolerance.
    public static func score(
        timeline: AnimatedPresentationTimeline,
        observations: [AnimatedPresentationObservation],
        deadlineToleranceNanoseconds: UInt64
    ) throws -> AnimatedPresentationScore {
        guard !observations.isEmpty, observations.count <= 1_000_000,
            observations[0].sequence == 0,
            observations[0].elapsedNanoseconds == 0,
            observations[0].frameIndex < timeline.frameCount
        else {
            throw ComparativeLabError.invalidMeasurement
        }

        let phase = observations[0].frameIndex
        if phase != 0 {
            let rotatedDurations =
                Array(timeline.frameDurationsNanoseconds[phase...])
                + Array(timeline.frameDurationsNanoseconds[..<phase])
            let rotatedTimeline = try AnimatedPresentationTimeline(
                frameDurationsNanoseconds: rotatedDurations
            )
            let rotatedObservations = try observations.map { observation in
                try AnimatedPresentationObservation(
                    sequence: observation.sequence,
                    elapsedNanoseconds: observation.elapsedNanoseconds,
                    frameIndex: (observation.frameIndex - phase + timeline.frameCount)
                        % timeline.frameCount,
                    mainThreadCallbackNanoseconds: observation.mainThreadCallbackNanoseconds
                )
            }
            return try score(
                timeline: rotatedTimeline,
                observations: rotatedObservations,
                deadlineToleranceNanoseconds: deadlineToleranceNanoseconds
            )
        }

        var previousElapsed: UInt64 = 0
        var previousFrameIndex = 0
        var observedOrdinal: UInt64 = 0
        var transitionErrors: [UInt64] = []
        transitionErrors.reserveCapacity(min(observations.count, 4_096))
        var callbackDurations: [UInt64] = []
        callbackDurations.reserveCapacity(min(observations.count, 4_096))

        var transitionCount = 0
        var mismatchObservationCount = 0
        var staleObservationCount = 0
        var aheadObservationCount = 0
        var frameOrderViolationCount = 0
        var observedSkippedSourceFrameCount: UInt64 = 0
        var missedDeadlineCount = 0
        var earlyDeadlineCount = 0
        var maximumBehindFrameCount: UInt64 = 0
        var maximumAheadFrameCount: UInt64 = 0

        for (offset, observation) in observations.enumerated() {
            guard observation.sequence == offset,
                observation.frameIndex < timeline.frameCount,
                offset == 0 || observation.elapsedNanoseconds > previousElapsed
            else {
                throw ComparativeLabError.invalidMeasurement
            }
            if let callback = observation.mainThreadCallbackNanoseconds {
                callbackDurations.append(callback)
            }

            let expectedOrdinal = try timeline.absoluteFrameOrdinal(
                at: observation.elapsedNanoseconds
            )

            if offset > 0, observation.frameIndex != previousFrameIndex {
                let frameCount = timeline.frameCount
                let forwardDelta =
                    observation.frameIndex > previousFrameIndex
                    ? observation.frameIndex - previousFrameIndex
                    : frameCount - previousFrameIndex + observation.frameIndex
                guard forwardDelta > 0 else { throw ComparativeLabError.invalidMeasurement }

                let ordinalAdvance = UInt64(forwardDelta)
                let advanced = observedOrdinal.addingReportingOverflow(ordinalAdvance)
                guard !advanced.overflow else { throw ComparativeLabError.invalidMeasurement }
                observedOrdinal = advanced.partialValue
                transitionCount += 1

                if ordinalAdvance > 1 {
                    let skipped = ordinalAdvance - 1
                    let totalSkipped = observedSkippedSourceFrameCount.addingReportingOverflow(
                        skipped)
                    guard !totalSkipped.overflow else {
                        throw ComparativeLabError.invalidMeasurement
                    }
                    observedSkippedSourceFrameCount = totalSkipped.partialValue
                }

                if observedOrdinal > expectedOrdinal {
                    let lead = observedOrdinal - expectedOrdinal
                    if lead > 1 { frameOrderViolationCount += 1 }
                }

                let expectedStart = try timeline.startTimeNanoseconds(
                    forAbsoluteFrameOrdinal: observedOrdinal
                )
                let absoluteError: UInt64
                if observation.elapsedNanoseconds >= expectedStart {
                    let lateness = observation.elapsedNanoseconds - expectedStart
                    absoluteError = lateness
                    if lateness > deadlineToleranceNanoseconds {
                        missedDeadlineCount += 1
                    }
                } else {
                    let earliness = expectedStart - observation.elapsedNanoseconds
                    absoluteError = earliness
                    if earliness > deadlineToleranceNanoseconds {
                        earlyDeadlineCount += 1
                    }
                }
                transitionErrors.append(absoluteError)
            }

            if expectedOrdinal > observedOrdinal {
                staleObservationCount += 1
                mismatchObservationCount += 1
                maximumBehindFrameCount = max(
                    maximumBehindFrameCount,
                    expectedOrdinal - observedOrdinal
                )
            } else if observedOrdinal > expectedOrdinal {
                aheadObservationCount += 1
                mismatchObservationCount += 1
                maximumAheadFrameCount = max(
                    maximumAheadFrameCount,
                    observedOrdinal - expectedOrdinal
                )
            }

            previousElapsed = observation.elapsedNanoseconds
            previousFrameIndex = observation.frameIndex
        }

        return AnimatedPresentationScore(
            observationCount: observations.count,
            transitionCount: transitionCount,
            frameStateMismatchObservationCount: mismatchObservationCount,
            staleObservationCount: staleObservationCount,
            aheadObservationCount: aheadObservationCount,
            frameOrderViolationCount: frameOrderViolationCount,
            observedSkippedSourceFrameCount: observedSkippedSourceFrameCount,
            missedDeadlineCount: missedDeadlineCount,
            earlyDeadlineCount: earlyDeadlineCount,
            maximumBehindFrameCount: maximumBehindFrameCount,
            maximumAheadFrameCount: maximumAheadFrameCount,
            p50AbsoluteTimingErrorNanoseconds: percentile(
                transitionErrors,
                numerator: 50,
                denominator: 100
            ),
            p95AbsoluteTimingErrorNanoseconds: percentile(
                transitionErrors,
                numerator: 95,
                denominator: 100
            ),
            maximumAbsoluteTimingErrorNanoseconds: transitionErrors.max(),
            callbackSampleCount: callbackDurations.count,
            p95MainThreadCallbackNanoseconds: percentile(
                callbackDurations,
                numerator: 95,
                denominator: 100
            ),
            maximumMainThreadCallbackNanoseconds: callbackDurations.max()
        )
    }

    private static func percentile(
        _ values: [UInt64],
        numerator: Int,
        denominator: Int
    ) -> UInt64? {
        guard !values.isEmpty, numerator > 0, numerator <= denominator else { return nil }
        let sorted = values.sorted()
        let product = sorted.count.multipliedReportingOverflow(by: numerator)
        guard !product.overflow else { return sorted.last }
        let rank = (product.partialValue + denominator - 1) / denominator
        return sorted[max(0, rank - 1)]
    }
}

/// Source-bound W5 presentation artifact. The score is recomputed from the raw trace during decoding, so a
/// stored summary cannot silently diverge from the observations that support it.
public struct ComparatorAnimatedPresentationArtifact: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let workloadID: ComparativeWorkloadID
    public let comparator: ComparatorIdentity
    public let environment: ComparatorRunEnvironment
    public let runIndex: Int
    public let datasetDigest: String
    public let startupLatencyNanoseconds: UInt64
    public let deadlineToleranceNanoseconds: UInt64
    public let timeline: AnimatedPresentationTimeline
    public let observations: [AnimatedPresentationObservation]
    public let score: AnimatedPresentationScore
    public let provisional: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case workloadID
        case comparator
        case environment
        case runIndex
        case datasetDigest
        case startupLatencyNanoseconds
        case deadlineToleranceNanoseconds
        case timeline
        case observations
        case score
        case provisional
    }

    public init(
        comparator: ComparatorIdentity,
        environment: ComparatorRunEnvironment,
        runIndex: Int,
        datasetDigest: String,
        startupLatencyNanoseconds: UInt64,
        deadlineToleranceNanoseconds: UInt64,
        timeline: AnimatedPresentationTimeline,
        observations: [AnimatedPresentationObservation]
    ) throws {
        guard runIndex >= 0,
            datasetDigest.count == 64,
            datasetDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else {
            throw ComparativeLabError.invalidMeasurement
        }
        let score = try AnimatedPresentationOracle.score(
            timeline: timeline,
            observations: observations,
            deadlineToleranceNanoseconds: deadlineToleranceNanoseconds
        )
        self.schemaVersion = 1
        self.workloadID = .w5AnimatedMedia
        self.comparator = comparator
        self.environment = environment
        self.runIndex = runIndex
        self.datasetDigest = datasetDigest
        self.startupLatencyNanoseconds = startupLatencyNanoseconds
        self.deadlineToleranceNanoseconds = deadlineToleranceNanoseconds
        self.timeline = timeline
        self.observations = observations
        self.score = score
        self.provisional = !environment.permitsReleaseClaim
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let workloadID = try container.decode(ComparativeWorkloadID.self, forKey: .workloadID)
        let comparator = try container.decode(ComparatorIdentity.self, forKey: .comparator)
        let environment = try container.decode(ComparatorRunEnvironment.self, forKey: .environment)
        let runIndex = try container.decode(Int.self, forKey: .runIndex)
        let datasetDigest = try container.decode(String.self, forKey: .datasetDigest)
        let startupLatencyNanoseconds = try container.decode(
            UInt64.self,
            forKey: .startupLatencyNanoseconds
        )
        let deadlineToleranceNanoseconds = try container.decode(
            UInt64.self,
            forKey: .deadlineToleranceNanoseconds
        )
        let timeline = try container.decode(AnimatedPresentationTimeline.self, forKey: .timeline)
        let observations = try container.decode(
            [AnimatedPresentationObservation].self,
            forKey: .observations
        )
        let encodedScore = try container.decode(AnimatedPresentationScore.self, forKey: .score)
        let provisional = try container.decode(Bool.self, forKey: .provisional)

        guard schemaVersion == 1, workloadID == .w5AnimatedMedia else {
            throw ComparativeLabError.invalidMeasurement
        }
        let rebuilt = try Self(
            comparator: comparator,
            environment: environment,
            runIndex: runIndex,
            datasetDigest: datasetDigest,
            startupLatencyNanoseconds: startupLatencyNanoseconds,
            deadlineToleranceNanoseconds: deadlineToleranceNanoseconds,
            timeline: timeline,
            observations: observations
        )
        guard encodedScore == rebuilt.score, provisional == rebuilt.provisional else {
            throw ComparativeLabError.invalidMeasurement
        }
        self = rebuilt
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(workloadID, forKey: .workloadID)
        try container.encode(comparator, forKey: .comparator)
        try container.encode(environment, forKey: .environment)
        try container.encode(runIndex, forKey: .runIndex)
        try container.encode(datasetDigest, forKey: .datasetDigest)
        try container.encode(startupLatencyNanoseconds, forKey: .startupLatencyNanoseconds)
        try container.encode(deadlineToleranceNanoseconds, forKey: .deadlineToleranceNanoseconds)
        try container.encode(timeline, forKey: .timeline)
        try container.encode(observations, forKey: .observations)
        try container.encode(score, forKey: .score)
        try container.encode(provisional, forKey: .provisional)
    }
}
