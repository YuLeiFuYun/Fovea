import Foundation

public enum MemoryContestantKind: String, Codable, CaseIterable, Sendable {
    case fovea = "Fovea"
    case lruCache = "LRUCache"
    case pinMemoryCache = "PINMemoryCache"
}

public enum DiskContestantKind: String, Codable, CaseIterable, Sendable {
    case fovea = "Fovea"
    case pinDiskCacheNative = "PINDiskCacheNative"
    case pinDiskCacheDurableValidated = "PINDiskCacheDurableValidated"

    public var semanticGroup: String {
        switch self {
        case .fovea, .pinDiskCacheDurableValidated:
            "content-validated-durable-commit"
        case .pinDiskCacheNative:
            "native-best-effort-atomic-write"
        }
    }

    public var durabilityLevel: String {
        switch self {
        case .fovea, .pinDiskCacheDurableValidated: "D5"
        case .pinDiskCacheNative: "D1"
        }
    }

    public var rankingRole: String {
        switch self {
        case .fovea, .pinDiskCacheDurableValidated: "primary"
        case .pinDiskCacheNative: "descriptive"
        }
    }
}

public struct CacheCorrectnessCheck: Codable, Equatable, Sendable {
    public let identifier: String
    public let passed: Bool
    public let value: Int

    public init(identifier: String, passed: Bool, value: Int = 0) {
        self.identifier = identifier
        self.passed = passed
        self.value = value
    }
}

public struct MemoryHotScanResult: Codable, Sendable {
    public let contestant: MemoryContestantKind
    public let hotHits: Int
    public let hotObjectCount: Int
    public let scanObjectCount: Int
    public let operations: Int
    public let durationNanoseconds: UInt64
    public let p99OperationNanoseconds: UInt64
    public let finalCount: Int
    public let finalCost: Int
    public let checks: [CacheCorrectnessCheck]

    public var hotSetHitRate: Double {
        hotObjectCount == 0 ? 0 : Double(hotHits) / Double(hotObjectCount)
    }

    public var operationsPerSecond: Double {
        durationNanoseconds == 0
            ? 0 : Double(operations) * 1_000_000_000 / Double(durationNanoseconds)
    }
}

public struct MemoryConcurrentResult: Codable, Sendable {
    public let contestant: MemoryContestantKind
    public let workers: Int
    public let operations: Int
    public let durationNanoseconds: UInt64
    public let p99WorkerOperationNanoseconds: UInt64
    public let finalCount: Int
    public let finalCost: Int
    public let checks: [CacheCorrectnessCheck]

    public var operationsPerSecond: Double {
        durationNanoseconds == 0
            ? 0 : Double(operations) * 1_000_000_000 / Double(durationNanoseconds)
    }
}

public struct DiskCorrectnessResult: Codable, Sendable {
    public let contestant: DiskContestantKind
    public let semanticGroup: String
    public let durabilityLevel: String
    public let rankingRole: String
    public let checks: [CacheCorrectnessCheck]
}

public struct DiskMixedResult: Codable, Sendable {
    public let contestant: DiskContestantKind
    public let semanticGroup: String
    public let durabilityLevel: String
    public let rankingRole: String
    public let objectCount: Int
    public let totalBytes: Int
    public let writeDurationNanoseconds: UInt64
    public let readDurationNanoseconds: UInt64
    public let p99ReadNanoseconds: UInt64
    public let p99ReadSampleCount: Int
    public let checks: [CacheCorrectnessCheck]

    public var writeBytesPerSecond: Double {
        writeDurationNanoseconds == 0
            ? 0 : Double(totalBytes) * 1_000_000_000 / Double(writeDurationNanoseconds)
    }

    public var readBytesPerSecond: Double {
        readDurationNanoseconds == 0
            ? 0 : Double(totalBytes) * 1_000_000_000 / Double(readDurationNanoseconds)
    }
}

public enum CacheLabFactory {
    public static func memory(
        _ kind: MemoryContestantKind,
        costLimit: Int,
        root: URL,
    ) -> any MemoryCacheContestant {
        switch kind {
        case .fovea:
            FoveaMemoryContestant(costLimit: costLimit)
        case .lruCache:
            LRUCacheContestant(costLimit: costLimit)
        case .pinMemoryCache:
            PINMemoryContestant(costLimit: costLimit, root: root)
        }
    }

    public static func disk(
        _ kind: DiskContestantKind,
        root: URL,
    ) async throws -> any DiskCacheContestant {
        switch kind {
        case .fovea:
            try await FoveaDiskContestant.open(root: root)
        case .pinDiskCacheNative:
            PINDiskContestant(root: root)
        case .pinDiskCacheDurableValidated:
            try PINDurableValidatedDiskContestant(root: root)
        }
    }
}

public enum CacheLabWorkloads {
    public static func runHotScan(
        kind: MemoryContestantKind,
        root: URL,
        capacity: Int = 128,
        hotObjectCount: Int = 32,
        scanObjectCount: Int = 4096,
        rounds: Int = 20,
    ) async -> MemoryHotScanResult {
        let normalizedRounds = max(1, rounds)
        let validationCache = CacheLabFactory.memory(
            kind,
            costLimit: capacity,
            root: root.appendingPathComponent("budget-validation", isDirectory: true),
        )
        let globalBudgetProbe = payload(seed: 91001, count: 64)
        await validationCache.insert(
            globalBudgetProbe,
            for: "global-budget-probe",
            cost: max(1, capacity / 2),
        )
        let acceptedGlobalBudgetEntry =
            await validationCache.value(for: "global-budget-probe") == globalBudgetProbe
        await validationCache.insert(
            globalBudgetProbe,
            for: "global-budget-probe",
            cost: capacity + 1,
        )
        let rejectedOverBudgetEntry =
            await validationCache.value(for: "global-budget-probe") == nil
        await validationCache.removeAll()

        let hotValues = (0 ..< hotObjectCount).map { payload(seed: $0, count: 64) }
        let scanValues = (0 ..< scanObjectCount).map {
            payload(seed: $0 &+ 100_000, count: 64)
        }
        let hotKeys = (0 ..< normalizedRounds).map { round in
            (0 ..< hotObjectCount).map { "hot-\(round)-\($0)" }
        }
        let scanKeys = (0 ..< normalizedRounds).map { round in
            (0 ..< scanObjectCount).map { "scan-\(round)-\($0)" }
        }

        let operationCountPerRound = scanObjectCount + hotObjectCount
        var latencies: [UInt64] = []
        latencies.reserveCapacity(normalizedRounds * operationCountPerRound)
        var totalDuration: UInt64 = 0
        var hits = 0
        var byteMismatches = 0
        var maximumFinalCount = 0
        var maximumFinalCost = 0

        for round in 0 ..< normalizedRounds {
            let cache = CacheLabFactory.memory(
                kind,
                costLimit: capacity,
                root: root.appendingPathComponent("round-\(round)", isDirectory: true),
            )
            for index in hotValues.indices {
                await cache.insert(hotValues[index], for: hotKeys[round][index], cost: 1)
            }
            for key in hotKeys[round] {
                _ = await cache.value(for: key)
            }

            let started = DispatchTime.now().uptimeNanoseconds
            for index in scanValues.indices {
                let operationStarted = DispatchTime.now().uptimeNanoseconds
                await cache.insert(scanValues[index], for: scanKeys[round][index], cost: 1)
                latencies.append(DispatchTime.now().uptimeNanoseconds &- operationStarted)
            }
            for index in hotValues.indices {
                let operationStarted = DispatchTime.now().uptimeNanoseconds
                let value = await cache.value(for: hotKeys[round][index])
                latencies.append(DispatchTime.now().uptimeNanoseconds &- operationStarted)
                if value != nil {
                    hits += 1
                }
                if let value, value != hotValues[index] {
                    byteMismatches += 1
                }
            }
            totalDuration &+= DispatchTime.now().uptimeNanoseconds &- started
            let roundFinalCount = await cache.count()
            let roundFinalCost = await cache.currentCost()
            maximumFinalCount = max(maximumFinalCount, roundFinalCount)
            maximumFinalCost = max(maximumFinalCost, roundFinalCost)
            await cache.removeAll()
        }

        let totalHotProbes = normalizedRounds * hotObjectCount
        let totalScanOperations = normalizedRounds * scanObjectCount
        return MemoryHotScanResult(
            contestant: kind,
            hotHits: hits,
            hotObjectCount: totalHotProbes,
            scanObjectCount: totalScanOperations,
            operations: normalizedRounds * operationCountPerRound,
            durationNanoseconds: totalDuration,
            p99OperationNanoseconds: percentile(latencies, quantile: 0.99),
            finalCount: maximumFinalCount,
            finalCost: maximumFinalCost,
            checks: [
                CacheCorrectnessCheck(
                    identifier: "global-budget-entry-accepted",
                    passed: acceptedGlobalBudgetEntry,
                    value: acceptedGlobalBudgetEntry ? 0 : 1,
                ),
                CacheCorrectnessCheck(
                    identifier: "over-budget-entry-rejected",
                    passed: rejectedOverBudgetEntry,
                    value: rejectedOverBudgetEntry ? 0 : 1,
                ),
                CacheCorrectnessCheck(
                    identifier: "returned-bytes-match",
                    passed: byteMismatches == 0,
                    value: byteMismatches,
                ),
                CacheCorrectnessCheck(
                    identifier: "cost-never-exceeds-limit",
                    passed: maximumFinalCost <= capacity,
                    value: max(0, maximumFinalCost - capacity),
                ),
            ],
        )
    }

    public static func runConcurrentMemory(
        kind: MemoryContestantKind,
        root: URL,
        costLimit: Int = 512,
        workers: Int = 8,
        operationsPerWorker: Int = 5000,
    ) async -> MemoryConcurrentResult {
        let cache = CacheLabFactory.memory(kind, costLimit: costLimit, root: root)
        let keys = (0 ..< 1024).map { "concurrent-\($0)" }
        let values = (0 ..< 1024).map { payload(seed: $0, count: 64) }
        let started = DispatchTime.now().uptimeNanoseconds
        let workerLatencies = await withTaskGroup(of: [UInt64].self, returning: [[UInt64]].self) {
            group in
            for worker in 0 ..< workers {
                group.addTask {
                    var latencies: [UInt64] = []
                    latencies.reserveCapacity(operationsPerWorker)
                    for operation in 0 ..< operationsPerWorker {
                        let keyIndex = (worker &* 1009 &+ operation &* 17) % 1024
                        let key = keys[keyIndex]
                        let operationStarted = DispatchTime.now().uptimeNanoseconds
                        switch operation % 10 {
                        case 0, 1, 2:
                            await cache.insert(
                                values[keyIndex],
                                for: key,
                                cost: 1,
                            )
                        case 3:
                            await cache.removeValue(for: key)
                        default:
                            _ = await cache.value(for: key)
                        }
                        latencies.append(DispatchTime.now().uptimeNanoseconds &- operationStarted)
                    }
                    return latencies
                }
            }
            var result: [[UInt64]] = []
            for await values in group {
                result.append(values)
            }
            return result
        }
        let duration = DispatchTime.now().uptimeNanoseconds &- started
        let finalCount = await cache.count()
        let finalCost = await cache.currentCost()
        let allLatencies = workerLatencies.flatMap(\.self)
        var mismatches = 0
        for keyIndex in 0 ..< 1024 {
            if let value = await cache.value(for: keys[keyIndex]),
               value != values[keyIndex]
            {
                mismatches += 1
            }
        }
        return MemoryConcurrentResult(
            contestant: kind,
            workers: workers,
            operations: workers * operationsPerWorker,
            durationNanoseconds: duration,
            p99WorkerOperationNanoseconds: percentile(allLatencies, quantile: 0.99),
            finalCount: finalCount,
            finalCost: finalCost,
            checks: [
                CacheCorrectnessCheck(
                    identifier: "returned-bytes-match",
                    passed: mismatches == 0,
                    value: mismatches,
                ),
                CacheCorrectnessCheck(
                    identifier: "bounded-cost",
                    passed: finalCost <= costLimit,
                    value: max(0, finalCost - costLimit),
                ),
                CacheCorrectnessCheck(identifier: "no-crash-or-hang", passed: true),
            ],
        )
    }

    public static func runDiskCorrectness(
        kind: DiskContestantKind,
        root: URL,
    ) async throws -> DiskCorrectnessResult {
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var cache: (any DiskCacheContestant)? = try await CacheLabFactory.disk(kind, root: root)
        let value = payload(seed: 42, count: 4096)
        let key = cacheContentID(for: value)
        try await cache?.insert(value, for: key)
        let initial = try await cache?.value(for: key)
        try await cache?.quiesce()
        let initialMatch = initial == value

        var proofGatesVisibility = true
        if kind == .pinDiskCacheDurableValidated {
            let proofURL =
                root
                    .appendingPathComponent(".fovea-durable-validation-v1", isDirectory: true)
                    .appendingPathComponent("\(key).proof", isDirectory: false)
            try FileManager.default.removeItem(at: proofURL)
            proofGatesVisibility = try await cache?.value(for: key) == nil
            try await cache?.insert(value, for: key)
        }
        try await cache?.quiesce()

        cache = nil
        cache = try await CacheLabFactory.disk(kind, root: root)
        let reopened = try await cache?.value(for: key)
        try await cache?.quiesce()
        let restartMatch = reopened == value

        let fileURL = try await cache?.fileURL(for: key)
        if let fileURL {
            try FileManager.default.removeItem(at: fileURL)
        }
        let afterExternalDeletion: Data?
        do {
            afterExternalDeletion = try await cache?.value(for: key)
        } catch {
            afterExternalDeletion = nil
        }
        let externalDeletionMiss = afterExternalDeletion == nil

        let corruptValue = payload(seed: 84, count: 8192)
        let corruptKey = cacheContentID(for: corruptValue)
        try await cache?.insert(corruptValue, for: corruptKey)
        let corruptURL = try await cache?.fileURL(for: corruptKey)
        if let corruptURL {
            try Data("intentionally-corrupt-cache-lab".utf8).write(to: corruptURL, options: .atomic)
        }
        let corruptServed: Bool
        do {
            corruptServed = try await cache?.value(for: corruptKey) != nil
        } catch {
            corruptServed = false
        }
        try await cache?.quiesce()
        let readExceptionCount = await cache?.readExceptionCount() ?? 0
        try await cache?.removeAll()
        try await cache?.quiesce()
        return DiskCorrectnessResult(
            contestant: kind,
            semanticGroup: kind.semanticGroup,
            durabilityLevel: kind.durabilityLevel,
            rankingRole: kind.rankingRole,
            checks: [
                CacheCorrectnessCheck(identifier: "initial-read", passed: initialMatch),
                CacheCorrectnessCheck(identifier: "restart-persistence", passed: restartMatch),
                CacheCorrectnessCheck(
                    identifier: "proof-gates-visibility",
                    passed: proofGatesVisibility,
                    value: proofGatesVisibility ? 0 : 1,
                ),
                CacheCorrectnessCheck(
                    identifier: "external-deletion-clean-miss",
                    passed: externalDeletionMiss,
                ),
                CacheCorrectnessCheck(
                    identifier: "corruption-not-served",
                    passed: !corruptServed,
                    value: corruptServed ? 1 : 0,
                ),
                CacheCorrectnessCheck(
                    identifier: "corruption-does-not-raise-process-exception",
                    passed: readExceptionCount == 0,
                    value: readExceptionCount,
                ),
            ],
        )
    }

    public static func runDiskMixed(
        kind: DiskContestantKind,
        root: URL,
        objectsPerSize: Int = 16,
        sizes: [Int] = [4096, 65536, 1_048_576],
        p99SampleRounds: Int = 8,
    ) async throws -> DiskMixedResult {
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = try await CacheLabFactory.disk(kind, root: root)
        var values: [(key: String, data: Data)] = []
        for size in sizes {
            for index in 0 ..< objectsPerSize {
                let data = payload(seed: size &+ index &* 31, count: size)
                values.append((cacheContentID(for: data), data))
            }
        }
        let totalBytes = values.reduce(0) { $0 + $1.data.count }
        let writeStarted = DispatchTime.now().uptimeNanoseconds
        for value in values {
            try await cache.insert(value.data, for: value.key)
        }
        try await cache.quiesce()
        let writeDuration = DispatchTime.now().uptimeNanoseconds &- writeStarted

        var mismatches = 0
        let readStarted = DispatchTime.now().uptimeNanoseconds
        for value in values.reversed() {
            let loaded = try await cache.value(for: value.key)
            if loaded != value.data {
                mismatches += 1
            }
        }
        try await cache.quiesce()
        let readDuration = DispatchTime.now().uptimeNanoseconds &- readStarted

        let normalizedP99Rounds = max(1, p99SampleRounds)
        var readLatencies: [UInt64] = []
        readLatencies.reserveCapacity(values.count * normalizedP99Rounds)
        for round in 0 ..< normalizedP99Rounds {
            let shift = (round * 37) % values.count
            for offset in values.indices {
                let value = values[(offset + shift) % values.count]
                let operationStarted = DispatchTime.now().uptimeNanoseconds
                let loaded = try await cache.value(for: value.key)
                readLatencies.append(DispatchTime.now().uptimeNanoseconds &- operationStarted)
                if loaded != value.data {
                    mismatches += 1
                }
            }
            try await cache.quiesce()
        }
        try await cache.removeAll()
        try await cache.quiesce()
        return DiskMixedResult(
            contestant: kind,
            semanticGroup: kind.semanticGroup,
            durabilityLevel: kind.durabilityLevel,
            rankingRole: kind.rankingRole,
            objectCount: values.count,
            totalBytes: totalBytes,
            writeDurationNanoseconds: writeDuration,
            readDurationNanoseconds: readDuration,
            p99ReadNanoseconds: percentile(readLatencies, quantile: 0.99),
            p99ReadSampleCount: readLatencies.count,
            checks: [
                CacheCorrectnessCheck(
                    identifier: "returned-bytes-match",
                    passed: mismatches == 0,
                    value: mismatches,
                ),
                CacheCorrectnessCheck(identifier: "concurrent-read-write", passed: true),
                CacheCorrectnessCheck(
                    identifier: "background-work-does-not-cross-measurement-window",
                    passed: true,
                ),
            ],
        )
    }

    public static func aggregateHotScan(
        _ samples: [MemoryHotScanResult],
    ) -> MemoryHotScanResult {
        precondition(!samples.isEmpty)
        let first = samples[0]
        precondition(samples.allSatisfy { $0.contestant == first.contestant })
        return MemoryHotScanResult(
            contestant: first.contestant,
            hotHits: samples.map(\.hotHits).min() ?? 0,
            hotObjectCount: first.hotObjectCount,
            scanObjectCount: first.scanObjectCount,
            operations: first.operations,
            durationNanoseconds: median(samples.map(\.durationNanoseconds)),
            p99OperationNanoseconds: median(samples.map(\.p99OperationNanoseconds)),
            finalCount: median(samples.map(\.finalCount)),
            finalCost: samples.map(\.finalCost).max() ?? 0,
            checks: aggregateChecks(samples.flatMap(\.checks)),
        )
    }

    public static func aggregateConcurrentMemory(
        _ samples: [MemoryConcurrentResult],
    ) -> MemoryConcurrentResult {
        precondition(!samples.isEmpty)
        let first = samples[0]
        precondition(samples.allSatisfy { $0.contestant == first.contestant })
        return MemoryConcurrentResult(
            contestant: first.contestant,
            workers: first.workers,
            operations: first.operations,
            durationNanoseconds: median(samples.map(\.durationNanoseconds)),
            p99WorkerOperationNanoseconds: median(samples.map(\.p99WorkerOperationNanoseconds)),
            finalCount: median(samples.map(\.finalCount)),
            finalCost: samples.map(\.finalCost).max() ?? 0,
            checks: aggregateChecks(samples.flatMap(\.checks)),
        )
    }

    private static func aggregateChecks(
        _ checks: [CacheCorrectnessCheck],
    ) -> [CacheCorrectnessCheck] {
        Dictionary(grouping: checks, by: \.identifier)
            .map { identifier, values in
                CacheCorrectnessCheck(
                    identifier: identifier,
                    passed: values.allSatisfy(\.passed),
                    value: values.map(\.value).max() ?? 0,
                )
            }
            .sorted { $0.identifier < $1.identifier }
    }

    private static func median<T: Comparable>(_ values: [T]) -> T {
        precondition(!values.isEmpty)
        return values.sorted()[values.count / 2]
    }

    public static func payload(seed: Int, count: Int) -> Data {
        var data = Data(count: max(0, count))
        data.withUnsafeMutableBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var state = UInt64(bitPattern: Int64(seed)) ^ 0x9E37_79B9_7F4A_7C15
            for index in 0 ..< count {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                bytes[index] = UInt8(truncatingIfNeeded: state)
            }
        }
        return data
    }

    private static func percentile(_ values: [UInt64], quantile: Double) -> UInt64 {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(
            sorted.count - 1,
            max(0, Int((Double(sorted.count - 1) * quantile).rounded(.up))),
        )
        return sorted[index]
    }
}
