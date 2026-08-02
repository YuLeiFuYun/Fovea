import ComparativeLabCore
import Foundation

private struct W7PreparedLoad: Sendable {
    let sequence: Int
    let observationResourceID: String
    let target: ComparatorPixelTarget
    let load: ComparatorLoad
    let shouldCancel: Bool
}

private enum W7WorkloadError: Error {
    case blockerCapacityNotObserved
}

private struct W7CompletedLoad: Sendable {
    let sequence: Int
    let observationResourceID: String
    let target: ComparatorPixelTarget
    let output: ComparatorLoadOutput
}

extension WorkloadRunner {
    // AsyncPermitPool guarantees at most eight newer client grants. Because the common
    // client budget is also eight, as many as seven already-admitted requests can still
    // reach the black-box origin before the background probe. V7 therefore fixes the
    // observable origin-start bound at 8 + (8 - 1) = 15 without weakening the internal
    // scheduler invariant.
    private static let maximumObservableOriginStartBypasses = 15

    static func runW7(
        adapter: any ComparatorAdapter,
        runIndex: Int
    ) async throws -> WorkloadResult {
        let target = try ComparatorPixelTarget(width: 32, height: 32)
        let accumulator = ObservationAccumulator()
        let threadSampler = ThreadCountSampler()
        let started = DispatchTime.now().uptimeNanoseconds
        threadSampler.start()

        let coalescing = try await prepareCoalescingBurst(
            adapter: adapter,
            target: target,
            runIndex: runIndex
        )
        let collectionTask = Task.detached { await collect(coalescing) }
        try await Task.sleep(nanoseconds: 20_000_000)
        for prepared in coalescing where prepared.shouldCancel {
            prepared.load.cancel()
        }
        let coalescingResults = await collectionTask.value
        for item in coalescingResults.sorted(by: { $0.sequence < $1.sequence }) {
            await accumulator.append(
                resourceID: item.observationResourceID,
                target: item.target,
                output: item.output
            )
        }

        let blockers = try await prepareBlockers(
            adapter: adapter,
            target: target,
            runIndex: runIndex
        )
        let blockerCollection = Task.detached { await collect(blockers) }
        try await waitForW7Blockers()
        let starvationProbe = try await prepareStarvationProbe(
            adapter: adapter,
            target: target,
            runIndex: runIndex
        )
        let probeCollection = Task.detached { await collect(starvationProbe) }
        let blockerResults = await blockerCollection.value
        let probeResults = await probeCollection.value

        let balanced = try await prepareBalancedPriorityBurst(
            adapter: adapter,
            target: target,
            runIndex: runIndex
        )
        let balancedResults = await collect(balanced)
        let scheduling = blockers + starvationProbe + balanced
        let schedulingResults = blockerResults + probeResults + balancedResults
        for item in schedulingResults.sorted(by: { $0.sequence < $1.sequence }) {
            await accumulator.append(
                resourceID: item.observationResourceID,
                target: item.target,
                output: item.output
            )
        }

        let duration = DispatchTime.now().uptimeNanoseconds &- started
        let threads = threadSampler.stop()
        let snapshot = await accumulator.snapshot()
        let origin = DeterministicBenchmarkURLProtocol.metrics()
        let sharedOriginRequests = origin.routeRequestCounts["/w7/shared", default: 0]
        let originPeakConcurrency = origin.peakConcurrentRequestCount
        let coalescingCancelled = coalescingResults.count {
            $0.output.measurement.outcome == .cancelled
        }
        let coalescingCompleted = coalescingResults.count {
            $0.output.measurement.outcome == .completed
        }
        let schedulingCompleted = schedulingResults.count {
            $0.output.measurement.outcome == .completed
        }
        let allLatencies = (coalescingResults + schedulingResults).map {
            $0.output.measurement.latencyNanoseconds
        }
        let balancedResultsForPriority = schedulingResults.filter {
            $0.observationResourceID.hasPrefix("w7|balanced|")
        }
        let priorityLatencies = Dictionary(grouping: balancedResultsForPriority) { item in
            item.observationResourceID.split(separator: "|")[2]
        }.mapValues { values in values.map(\.output.measurement.latencyNanoseconds) }
        let probeLowIndex = origin.w7ServiceStartOrder.firstIndex(of: "probe-low")
        let probeNewerBypasses = probeLowIndex.map { index in
            origin.w7ServiceStartOrder[..<index].count { $0.hasPrefix("probe-high-") }
        }
        let throughputMilli =
            duration == 0
            ? 0
            : Int((Double(1_000) * 1_000 * 1_000_000_000 / Double(duration)).rounded())
        let baselineThreads = threads.baseline ?? 0
        let peakThreads = threads.peak ?? 0
        let peakThreadDelta = max(0, peakThreads - baselineThreads)

        var checks: [BenchmarkCheck] = [
            BenchmarkCheck(
                identifier: "logical-request-count-exact",
                passed: coalescing.count + scheduling.count == 1_000,
                value: abs(coalescing.count + scheduling.count - 1_000)
            ),
            BenchmarkCheck(
                identifier: "observation-count-exact",
                passed: snapshot.observations.count == 1_000,
                value: abs(snapshot.observations.count - 1_000)
            ),
            BenchmarkCheck(
                identifier: "single-flight-origin-request-bound",
                passed: sharedOriginRequests <= 16,
                value: max(0, sharedOriginRequests - 16)
            ),
            BenchmarkCheck(
                identifier: "cancelled-subscriber-count-exact",
                passed: coalescingCancelled == 256,
                value: abs(coalescingCancelled - 256)
            ),
            BenchmarkCheck(
                identifier: "survivor-completion-count-exact",
                passed: coalescingCompleted == 256,
                value: abs(coalescingCompleted - 256)
            ),
            BenchmarkCheck(
                identifier: "priority-burst-no-starvation",
                passed: schedulingCompleted == 488,
                value: abs(schedulingCompleted - 488)
            ),
            BenchmarkCheck(
                identifier: "failed-load-count-zero",
                passed: snapshot.failed == 0,
                value: snapshot.failed
            ),
            BenchmarkCheck(
                identifier: "target-pixel-invariant",
                passed: snapshot.targetPixelViolationCount == 0,
                value: snapshot.targetPixelViolationCount
            ),
            BenchmarkCheck(
                identifier: "peak-thread-count-bounded",
                passed: peakThreads > 0 && peakThreads <= 256,
                value: peakThreads > 256 ? peakThreads - 256 : 0
            ),
            BenchmarkCheck(
                identifier: "origin-peak-concurrency-bounded",
                passed: originPeakConcurrency > 0 && originPeakConcurrency <= 8,
                value: originPeakConcurrency > 8 ? originPeakConcurrency - 8 : 0
            ),
            BenchmarkCheck(
                identifier: "background-probe-bypass-bound",
                passed: probeNewerBypasses != nil
                    && probeNewerBypasses! <= maximumObservableOriginStartBypasses,
                value: probeNewerBypasses.map {
                    max(0, $0 - maximumObservableOriginStartBypasses)
                } ?? Int.max
            ),
            BenchmarkCheck(
                identifier: "w7-shared-origin-request-count",
                passed: true,
                value: sharedOriginRequests
            ),
            BenchmarkCheck(
                identifier: "w7-baseline-thread-count",
                passed: true,
                value: baselineThreads
            ),
            BenchmarkCheck(
                identifier: "w7-peak-thread-count",
                passed: true,
                value: peakThreads
            ),
            BenchmarkCheck(
                identifier: "w7-peak-thread-delta",
                passed: true,
                value: peakThreadDelta
            ),
            BenchmarkCheck(
                identifier: "w7-origin-peak-concurrency",
                passed: true,
                value: originPeakConcurrency
            ),
            BenchmarkCheck(
                identifier: "w7-background-probe-newer-bypass-count",
                passed: true,
                value: probeNewerBypasses ?? Int.max
            ),
            BenchmarkCheck(
                identifier: "w7-p99-logical-latency-ns",
                passed: true,
                value: boundedInt(percentile(allLatencies, quantile: 0.99))
            ),
            BenchmarkCheck(
                identifier: "w7-throughput-milli-requests-per-second",
                passed: true,
                value: throughputMilli
            ),
        ]
        for priority in ComparatorPriority.allCasesForW7 {
            let value = percentile(
                priorityLatencies[Substring(priority.rawValue)] ?? [], quantile: 0.95)
            checks.append(
                BenchmarkCheck(
                    identifier: "w7-\(priority.rawValue)-p95-latency-ns",
                    passed: true,
                    value: boundedInt(value)
                )
            )
        }

        return WorkloadResult(
            observations: snapshot.observations,
            checks: checks,
            durationNanoseconds: duration,
            decodedMegapixels: snapshot.decodedMegapixels,
            completedLoads: snapshot.completed,
            cancelledLoads: snapshot.cancelled,
            failedLoads: snapshot.failed
        )
    }

    private static func prepareCoalescingBurst(
        adapter: any ComparatorAdapter,
        target: ComparatorPixelTarget,
        runIndex: Int
    ) async throws -> [W7PreparedLoad] {
        var values: [W7PreparedLoad] = []
        values.reserveCapacity(512)
        for group in 0..<16 {
            let request = try ComparatorRequest(
                resourceID: "w7-shared-\(group)",
                url: w7URL(path: "/w7/shared", queryName: "group", value: group),
                target: target,
                contentMode: .aspectFit,
                priority: .visible,
                securityNamespace: "public-w7"
            )
            for subscriber in 0..<32 {
                let shouldCancel = group < 4 || (group < 12 && subscriber < 16)
                values.append(
                    W7PreparedLoad(
                        sequence: values.count,
                        observationResourceID:
                            "w7|coalesce|g\(group)|s\(subscriber)|"
                            + (shouldCancel ? "cancel" : "keep"),
                        target: target,
                        load: try await adapter.makeLoad(request),
                        shouldCancel: shouldCancel
                    )
                )
            }
        }
        precondition(values.count == 512, "W7 coalescing trace drifted for run \(runIndex)")
        return values
    }

    private static func prepareBlockers(
        adapter: any ComparatorAdapter,
        target: ComparatorPixelTarget,
        runIndex: Int
    ) async throws -> [W7PreparedLoad] {
        var values: [W7PreparedLoad] = []
        values.reserveCapacity(8)
        for index in 0..<8 {
            let request = try ComparatorRequest(
                resourceID: "w7-blocker-\(runIndex)-\(index)",
                url: w7URL(path: "/w7/blocker", label: "blocker-\(index)"),
                target: target,
                contentMode: .aspectFit,
                priority: .visible,
                securityNamespace: "public-w7"
            )
            values.append(
                W7PreparedLoad(
                    sequence: 512 + index,
                    observationResourceID: "w7|blocker|visible|\(index)",
                    target: target,
                    load: try await adapter.makeLoad(request),
                    shouldCancel: false
                )
            )
        }
        return values
    }

    private static func waitForW7Blockers() async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let metrics = DeterministicBenchmarkURLProtocol.metrics()
            if metrics.routeRequestCounts["/w7/blocker", default: 0] == 8,
                metrics.peakConcurrentRequestCount == 8
            {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw W7WorkloadError.blockerCapacityNotObserved
    }

    private static func prepareStarvationProbe(
        adapter: any ComparatorAdapter,
        target: ComparatorPixelTarget,
        runIndex: Int
    ) async throws -> [W7PreparedLoad] {
        var values: [W7PreparedLoad] = []
        values.reserveCapacity(32)
        let low = try ComparatorRequest(
            resourceID: "w7-probe-low-\(runIndex)",
            url: w7URL(path: "/w7/unique", label: "probe-low"),
            target: target,
            contentMode: .aspectFit,
            priority: .background,
            securityNamespace: "public-w7"
        )
        values.append(
            W7PreparedLoad(
                sequence: 520,
                observationResourceID: "w7|probe|background|low",
                target: target,
                load: try await adapter.makeLoad(low),
                shouldCancel: false
            )
        )
        for index in 0..<31 {
            let request = try ComparatorRequest(
                resourceID: "w7-probe-high-\(runIndex)-\(index)",
                url: w7URL(path: "/w7/unique", label: "probe-high-\(index)"),
                target: target,
                contentMode: .aspectFit,
                priority: .immediate,
                securityNamespace: "public-w7"
            )
            values.append(
                W7PreparedLoad(
                    sequence: 521 + index,
                    observationResourceID: "w7|probe|immediate|\(index)",
                    target: target,
                    load: try await adapter.makeLoad(request),
                    shouldCancel: false
                )
            )
        }
        return values
    }

    private static func prepareBalancedPriorityBurst(
        adapter: any ComparatorAdapter,
        target: ComparatorPixelTarget,
        runIndex: Int
    ) async throws -> [W7PreparedLoad] {
        var values: [W7PreparedLoad] = []
        values.reserveCapacity(448)
        for index in 0..<112 {
            for priority in ComparatorPriority.allCasesForW7 {
                let unique = values.count
                let label = "balanced-\(priority.rawValue)-\(index)"
                let request = try ComparatorRequest(
                    resourceID: "w7-balanced-\(runIndex)-\(unique)",
                    url: w7URL(path: "/w7/unique", label: label),
                    target: target,
                    contentMode: .aspectFit,
                    priority: priority,
                    securityNamespace: "public-w7"
                )
                values.append(
                    W7PreparedLoad(
                        sequence: 552 + unique,
                        observationResourceID: "w7|balanced|\(priority.rawValue)|\(index)",
                        target: target,
                        load: try await adapter.makeLoad(request),
                        shouldCancel: false
                    )
                )
            }
        }
        precondition(values.count == 448, "W7 balanced trace drifted for run \(runIndex)")
        return values
    }

    private static func collect(_ values: [W7PreparedLoad]) async -> [W7CompletedLoad] {
        await withTaskGroup(of: W7CompletedLoad.self, returning: [W7CompletedLoad].self) {
            group in
            for value in values {
                group.addTask {
                    W7CompletedLoad(
                        sequence: value.sequence,
                        observationResourceID: value.observationResourceID,
                        target: value.target,
                        output: await value.load.result()
                    )
                }
            }
            var outputs: [W7CompletedLoad] = []
            outputs.reserveCapacity(values.count)
            for await output in group { outputs.append(output) }
            return outputs
        }
    }

    private static func w7URL(path: String, queryName: String, value: Int) -> URL {
        w7URL(path: path, label: "\(queryName)-\(value)")
    }

    private static func w7URL(path: String, label: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "benchmark.invalid"
        components.path = path
        components.queryItems = [URLQueryItem(name: "label", value: label)]
        return components.url!
    }

    private static func percentile(_ values: [UInt64], quantile: Double) -> UInt64 {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(
            sorted.count - 1, max(0, Int((Double(sorted.count - 1) * quantile).rounded(.up))))
        return sorted[index]
    }

    private static func boundedInt(_ value: UInt64) -> Int {
        Int(min(value, UInt64(Int.max)))
    }
}

extension ComparatorPriority {
    fileprivate static let allCasesForW7: [ComparatorPriority] = [
        .background, .utility, .visible, .immediate,
    ]
}
