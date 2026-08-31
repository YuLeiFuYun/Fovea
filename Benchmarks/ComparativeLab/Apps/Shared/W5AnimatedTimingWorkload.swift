import ComparativeLabCore
import Foundation
import UIKit

private final class W5AnimatedCaptureProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var progression: UInt64 = 0
    private var firstFrameIndex: Int?
    private var lastFrameIndex: Int?

    func record(event: ComparatorAnimatedPlayerFrameEvent, progression: UInt64) {
        lock.withLock {
            count += 1
            self.progression = progression
            if firstFrameIndex == nil { firstFrameIndex = event.sourceFrameIndex }
            lastFrameIndex = event.sourceFrameIndex
        }
    }

    func snapshot() -> (count: Int, progression: UInt64, first: Int?, last: Int?) {
        lock.withLock { (count, progression, firstFrameIndex, lastFrameIndex) }
    }
}

@MainActor
enum W5AnimatedTimingWorkload {
    private static let defaultFixtureID = "GIF-VARIABLE-DELAY-60"
    private static let maximumFrameBufferBytes = 32 * 1_024 * 1_024

    static func run(
        arguments: BenchmarkArguments,
        catalog: ResourceCatalog,
        adapter: any ComparatorAdapter,
        harnessIdentity: BenchmarkHarnessIdentity,
        experimentPlanID: String,
        experimentPlanDigest: String,
        claimFamilyDigest: String
    ) async throws -> W5AnimatedTimingEnvelope {
        guard arguments.workload == .w5AnimatedMedia,
            arguments.cacheState == .cold,
            arguments.networkProfile == .local,
            arguments.timeScale == 1,
            let playerAdapter = adapter as? any ComparatorAnimatedPlayerAdapter
        else {
            throw BenchmarkAppError.runFailed(
                "w5-animated-media-production-adapter-not-qualified"
            )
        }

        let fixtureID = arguments.w5FixtureID.isEmpty ? defaultFixtureID : arguments.w5FixtureID
        let source = try catalog.animatedPlayerFixture(identifier: fixtureID)
        guard source.fixture.frameCount == source.fixture.frameDurationsNanoseconds.count,
            source.fixture.loopCount == 0,
            let format = ComparatorAnimatedFormat(rawValue: source.fixture.format.lowercased())
        else {
            throw BenchmarkAppError.invalidResource(fixtureID)
        }
        let request: ComparatorAnimatedPlayerRequest
        do {
            request = try ComparatorAnimatedPlayerRequest(
                resourceID: fixtureID,
                encodedData: source.data,
                format: format,
                referenceFrameDurationsNanoseconds: source.fixture.frameDurationsNanoseconds,
                referenceLoopCount: source.fixture.loopCount,
                maximumFrameBufferBytes: maximumFrameBufferBytes
            )
        } catch {
            throw BenchmarkAppError.runFailed("w5-request:\(error)")
        }
        let preparationStartedAt = DispatchTime.now().uptimeNanoseconds
        let session: ComparatorAnimatedPlayerSession
        do {
            session = try playerAdapter.makeAnimatedPlayer(request)
        } catch {
            throw BenchmarkAppError.runFailed("w5-adapter-prepare:\(error)")
        }
        let expectedDurations = source.fixture.frameDurationsNanoseconds
        let actualDurations = session.sourceFrameDurationsNanoseconds
        guard actualDurations == expectedDurations,
            session.sourceLoopCount == source.fixture.loopCount
        else {
            let firstMismatchIndex = zip(expectedDurations, actualDurations)
                .enumerated()
                .first(where: { $0.element.0 != $0.element.1 })?
                .offset
            let mismatch =
                firstMismatchIndex.map { index in
                    "index=\(index):expected=\(expectedDurations[index]):actual=\(actualDurations[index])"
                } ?? "index=-1"
            throw BenchmarkAppError.runFailed(
                "w5-native-timeline-semantic-mismatch:"
                    + "expectedCount=\(expectedDurations.count):actualCount=\(actualDurations.count):"
                    + "expectedLoop=\(source.fixture.loopCount):actualLoop=\(session.sourceLoopCount):"
                    + mismatch
            )
        }

        let maximumFPS = max(1, UIScreen.main.maximumFramesPerSecond)
        let deadlineToleranceNanoseconds = UInt64(
            (1_000_000_000 + maximumFPS - 1) / maximumFPS
        )
        let timeline: AnimatedPresentationTimeline
        do {
            timeline = try AnimatedPresentationTimeline(
                frameDurationsNanoseconds: source.fixture.frameDurationsNanoseconds
            )
        } catch {
            throw BenchmarkAppError.runFailed("w5-timeline:\(error)")
        }
        let thermalMonitor = BenchmarkThermalMonitor()
        do {
            try await session.start()
        } catch {
            session.stop()
            _ = thermalMonitor.snapshotAndStop()
            throw BenchmarkAppError.runFailed("w5-start:\(error)")
        }
        let rawEvents: [ComparatorAnimatedPlayerFrameEvent]
        do {
            rawEvents = try await collectOneSourceLoop(
                events: session.events,
                frameCount: source.fixture.frameCount,
                nominalLoopDurationNanoseconds: timeline.totalDurationNanoseconds
            )
        } catch {
            session.stop()
            _ = thermalMonitor.snapshotAndStop()
            throw error
        }
        session.stop()
        let thermal = thermalMonitor.snapshotAndStop()
        guard let firstEvent = rawEvents.first,
            firstEvent.monotonicNanoseconds >= preparationStartedAt
        else {
            throw BenchmarkAppError.runFailed("w5-missing-initial-presentation")
        }
        let observations: [AnimatedPresentationObservation]
        do {
            observations = try AnimatedPresentationOracle.normalize(events: rawEvents)
        } catch {
            let firstIndex = rawEvents.first?.sourceFrameIndex ?? -1
            let lastIndex = rawEvents.last?.sourceFrameIndex ?? -1
            throw BenchmarkAppError.runFailed(
                "w5-normalize:\(error):count=\(rawEvents.count):first=\(firstIndex):last=\(lastIndex)"
            )
        }
        let presentation: ComparatorAnimatedPresentationArtifact
        do {
            presentation = try ComparatorAnimatedPresentationArtifact(
                comparator: adapter.identity,
                environment: catalog.environment,
                runIndex: arguments.runIndex,
                datasetDigest: source.fixture.sha256,
                startupLatencyNanoseconds: firstEvent.monotonicNanoseconds - preparationStartedAt,
                deadlineToleranceNanoseconds: deadlineToleranceNanoseconds,
                timeline: timeline,
                observations: observations
            )
        } catch {
            throw BenchmarkAppError.runFailed(
                "w5-score:\(error):observations=\(observations.count)"
            )
        }
        let checks = [
            BenchmarkCheck(
                identifier: "w5-native-timeline-exact",
                passed: session.sourceFrameDurationsNanoseconds
                    == source.fixture.frameDurationsNanoseconds,
                value: session.sourceFrameDurationsNanoseconds.count
            ),
            BenchmarkCheck(
                identifier: "w5-source-loop-progression-complete",
                passed: sourceProgression(
                    events: rawEvents,
                    frameCount: source.fixture.frameCount
                ) >= UInt64(source.fixture.frameCount),
                value: rawEvents.count
            ),
        ]

        return try W5AnimatedTimingEnvelope(
            planID: experimentPlanID,
            comparator: adapter.identity,
            harnessIdentity: harnessIdentity,
            experimentPlanDigest: experimentPlanDigest,
            claimFamilyDigest: claimFamilyDigest,
            environment: catalog.environment,
            runIndex: arguments.runIndex,
            fixtureID: source.fixture.id,
            fixtureDigest: source.fixture.sha256,
            maximumFrameBufferBytes: maximumFrameBufferBytes,
            maximumDisplayFramesPerSecond: maximumFPS,
            playerInputPath: session.inputPath,
            nativeSourceFrameDurationsNanoseconds: session.sourceFrameDurationsNanoseconds,
            nativeSourceLoopCount: session.sourceLoopCount,
            presentation: presentation,
            thermal: thermal,
            checks: checks
        )
    }

    private static func collectOneSourceLoop(
        events: AsyncStream<ComparatorAnimatedPlayerFrameEvent>,
        frameCount: Int,
        nominalLoopDurationNanoseconds: UInt64
    ) async throws -> [ComparatorAnimatedPlayerFrameEvent] {
        let doubled = nominalLoopDurationNanoseconds.multipliedReportingOverflow(by: 2)
        let baseTimeout = doubled.overflow ? UInt64.max : doubled.partialValue
        let timeout = baseTimeout.addingReportingOverflow(3_000_000_000)
        let timeoutNanoseconds = timeout.overflow ? UInt64.max : timeout.partialValue

        let progress = W5AnimatedCaptureProgress()
        return try await withThrowingTaskGroup(
            of: [ComparatorAnimatedPlayerFrameEvent].self
        ) { group in
            group.addTask {
                var captured: [ComparatorAnimatedPlayerFrameEvent] = []
                captured.reserveCapacity(frameCount + 1)
                var progression: UInt64 = 0
                var previousFrameIndex: Int?
                for await event in events {
                    if let previousFrameIndex, event.sourceFrameIndex != previousFrameIndex {
                        let delta =
                            event.sourceFrameIndex > previousFrameIndex
                            ? event.sourceFrameIndex - previousFrameIndex
                            : frameCount - previousFrameIndex + event.sourceFrameIndex
                        let sum = progression.addingReportingOverflow(UInt64(delta))
                        guard !sum.overflow else {
                            throw BenchmarkAppError.runFailed("w5-source-progression-overflow")
                        }
                        progression = sum.partialValue
                    }
                    captured.append(event)
                    previousFrameIndex = event.sourceFrameIndex
                    progress.record(event: event, progression: progression)
                    if progression >= UInt64(frameCount) { return captured }
                }
                throw BenchmarkAppError.runFailed("w5-player-ended-before-one-source-loop")
            }
            group.addTask {
                try await Task<Never, Never>.sleep(nanoseconds: timeoutNanoseconds)
                let snapshot = progress.snapshot()
                throw BenchmarkAppError.runFailed(
                    "w5-player-timing-timeout:count=\(snapshot.count):"
                        + "progression=\(snapshot.progression):"
                        + "first=\(snapshot.first ?? -1):last=\(snapshot.last ?? -1)"
                )
            }
            guard let result = try await group.next() else {
                throw BenchmarkAppError.runFailed("w5-player-timing-no-result")
            }
            group.cancelAll()
            return result
        }
    }

    private static func sourceProgression(
        events: [ComparatorAnimatedPlayerFrameEvent],
        frameCount: Int
    ) -> UInt64 {
        guard let first = events.first else { return 0 }
        var previous = first.sourceFrameIndex
        var total: UInt64 = 0
        for event in events.dropFirst() where event.sourceFrameIndex != previous {
            let delta =
                event.sourceFrameIndex > previous
                ? event.sourceFrameIndex - previous
                : frameCount - previous + event.sourceFrameIndex
            total =
                total.addingReportingOverflow(UInt64(delta)).overflow
                ? UInt64.max
                : total + UInt64(delta)
            previous = event.sourceFrameIndex
        }
        return total
    }
}
