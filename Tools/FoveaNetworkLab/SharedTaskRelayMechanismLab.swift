import Foundation
import FoveaCore

struct SharedTaskRelayMechanismCaseReport: Codable, Sendable {
    let name: String
    let blockCount: Int
    let operationsPerBlock: Int
    let medianNanosecondsPerValue: UInt64
    let p95NanosecondsPerValue: UInt64
    let allValuesCorrect: Bool
}

struct SharedTaskRelayMechanismReport: Codable, Sendable {
    let schemaVersion: Int
    let evidenceClass: String
    let warmupOperations: Int
    let cases: [SharedTaskRelayMechanismCaseReport]
    let allCorrect: Bool
}

enum SharedTaskRelayMechanismLab {
    private static let warmupOperations = 2_000
    private static let serialBlockCount = 9
    private static let serialOperationsPerBlock = 8_000
    private static let concurrentBlockCount = 9
    private static let concurrentWorkerCount = 8
    private static let concurrentOperationsPerWorker = 1_000
    private static let cancellationBlockCount = 11
    private static let cancellationOperationsPerBlock = 64
    private static let expectedValue = 42

    static func run() async throws -> SharedTaskRelayMechanismReport {
        let registry = SharedTaskRegistry<String, Int>()
        let subscription = await registry.subscribe(key: "completed-relay") {
            expectedValue
        }
        guard try await subscription.value() == expectedValue else {
            return SharedTaskRelayMechanismReport(
                schemaVersion: 1,
                evidenceClass: "offline-shared-task-relay-mechanism-directional-only",
                warmupOperations: warmupOperations,
                cases: [],
                allCorrect: false
            )
        }

        for _ in 0..<warmupOperations {
            _ = try await subscription.value()
        }

        let serial = try await measureSerial(subscription)
        let concurrent = try await measureConcurrent(subscription)
        await subscription.cancel()
        let cancellationBurst = await measureCancellationBurst()

        let cases = [serial, concurrent, cancellationBurst]
        return SharedTaskRelayMechanismReport(
            schemaVersion: 1,
            evidenceClass: "offline-shared-task-relay-mechanism-directional-only",
            warmupOperations: warmupOperations,
            cases: cases,
            allCorrect: cases.allSatisfy(\.allValuesCorrect)
        )
    }

    private static func measureSerial(
        _ subscription: SharedTaskSubscription<String, Int>
    ) async throws -> SharedTaskRelayMechanismCaseReport {
        var samples: [UInt64] = []
        samples.reserveCapacity(serialBlockCount)
        var correct = true
        for _ in 0..<serialBlockCount {
            let started = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<serialOperationsPerBlock {
                if try await subscription.value() != expectedValue { correct = false }
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds &- started
            samples.append(elapsed / UInt64(serialOperationsPerBlock))
        }
        samples.sort()
        return SharedTaskRelayMechanismCaseReport(
            name: "completed-serial",
            blockCount: serialBlockCount,
            operationsPerBlock: serialOperationsPerBlock,
            medianNanosecondsPerValue: percentile(samples, numerator: 50, denominator: 100),
            p95NanosecondsPerValue: percentile(samples, numerator: 95, denominator: 100),
            allValuesCorrect: correct
        )
    }

    private static func measureConcurrent(
        _ subscription: SharedTaskSubscription<String, Int>
    ) async throws -> SharedTaskRelayMechanismCaseReport {
        let operationsPerBlock = concurrentWorkerCount * concurrentOperationsPerWorker
        var samples: [UInt64] = []
        samples.reserveCapacity(concurrentBlockCount)
        var correct = true
        for _ in 0..<concurrentBlockCount {
            let started = DispatchTime.now().uptimeNanoseconds
            let blockCorrect = try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<concurrentWorkerCount {
                    group.addTask {
                        for _ in 0..<concurrentOperationsPerWorker {
                            if try await subscription.value() != expectedValue { return false }
                        }
                        return true
                    }
                }
                var blockCorrect = true
                for try await workerCorrect in group {
                    blockCorrect = blockCorrect && workerCorrect
                }
                return blockCorrect
            }
            correct = correct && blockCorrect
            let elapsed = DispatchTime.now().uptimeNanoseconds &- started
            samples.append(elapsed / UInt64(operationsPerBlock))
        }
        samples.sort()
        return SharedTaskRelayMechanismCaseReport(
            name: "completed-concurrent-8",
            blockCount: concurrentBlockCount,
            operationsPerBlock: operationsPerBlock,
            medianNanosecondsPerValue: percentile(samples, numerator: 50, denominator: 100),
            p95NanosecondsPerValue: percentile(samples, numerator: 95, denominator: 100),
            allValuesCorrect: correct
        )
    }

    private static func measureCancellationBurst() async -> SharedTaskRelayMechanismCaseReport {
        var latencies: [UInt64] = []
        latencies.reserveCapacity(cancellationBlockCount * cancellationOperationsPerBlock)
        var correct = true
        for block in 0..<cancellationBlockCount {
            let registry = SharedTaskRegistry<String, Int>(recordsCancellationCounts: true)
            var subscriptions: [SharedTaskSubscription<String, Int>] = []
            var keys: [String] = []
            subscriptions.reserveCapacity(cancellationOperationsPerBlock)
            keys.reserveCapacity(cancellationOperationsPerBlock)
            for operation in 0..<cancellationOperationsPerBlock {
                let key = "cancel-\(block)-\(operation)"
                keys.append(key)
                subscriptions.append(
                    await registry.subscribe(key: key) {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                        return expectedValue
                    }
                )
            }

            let started = DispatchTime.now().uptimeNanoseconds
            await withTaskGroup(of: UInt64.self) { group in
                for subscription in subscriptions {
                    group.addTask {
                        await subscription.cancel()
                        return DispatchTime.now().uptimeNanoseconds &- started
                    }
                }
                for await latency in group { latencies.append(latency) }
            }

            for key in keys {
                if await registry.cancellationCount(for: key) != 1 { correct = false }
            }
            await Task.yield()
        }
        latencies.sort()
        return SharedTaskRelayMechanismCaseReport(
            name: "cancel-distinct-keys-burst-latency-64",
            blockCount: cancellationBlockCount,
            operationsPerBlock: cancellationOperationsPerBlock,
            medianNanosecondsPerValue: percentile(latencies, numerator: 50, denominator: 100),
            p95NanosecondsPerValue: percentile(latencies, numerator: 95, denominator: 100),
            allValuesCorrect: correct
        )
    }

    private static func percentile(
        _ sorted: [UInt64],
        numerator: Int,
        denominator: Int
    ) -> UInt64 {
        guard !sorted.isEmpty else { return 0 }
        let index = min(
            sorted.count - 1,
            max(0, (sorted.count * numerator + denominator - 1) / denominator - 1)
        )
        return sorted[index]
    }
}
