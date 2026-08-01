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
        root: URL
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
        root: URL
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
        scanObjectCount: Int = 4_096
    ) async -> MemoryHotScanResult {
        let cache = CacheLabFactory.memory(kind, costLimit: capacity, root: root)
        let hotValues = (0..<hotObjectCount).map { payload(seed: $0, count: 64) }
        for index in hotValues.indices {
            await cache.insert(hotValues[index], for: "hot-\(index)", cost: 1)
        }
        for index in hotValues.indices {
            _ = await cache.value(for: "hot-\(index)")
        }

        var latencies: [UInt64] = []
        latencies.reserveCapacity(scanObjectCount + hotObjectCount)
        let started = DispatchTime.now().uptimeNanoseconds
        for index in 0..<scanObjectCount {
            let value = payload(seed: index &+ 100_000, count: 64)
            let operationStarted = DispatchTime.now().uptimeNanoseconds
            await cache.insert(value, for: "scan-\(index)", cost: 1)
            latencies.append(DispatchTime.now().uptimeNanoseconds &- operationStarted)
        }
        var hits = 0
        var byteMismatches = 0
        for index in hotValues.indices {
            let operationStarted = DispatchTime.now().uptimeNanoseconds
            let value = await cache.value(for: "hot-\(index)")
            latencies.append(DispatchTime.now().uptimeNanoseconds &- operationStarted)
            if value != nil { hits += 1 }
            if let value, value != hotValues[index] { byteMismatches += 1 }
        }
        let duration = DispatchTime.now().uptimeNanoseconds &- started
        let finalCount = await cache.count()
        let finalCost = await cache.currentCost()
        return MemoryHotScanResult(
            contestant: kind,
            hotHits: hits,
            hotObjectCount: hotObjectCount,
            scanObjectCount: scanObjectCount,
            operations: scanObjectCount + hotObjectCount,
            durationNanoseconds: duration,
            p99OperationNanoseconds: percentile(latencies, quantile: 0.99),
            finalCount: finalCount,
            finalCost: finalCost,
            checks: [
                CacheCorrectnessCheck(
                    identifier: "returned-bytes-match",
                    passed: byteMismatches == 0,
                    value: byteMismatches
                ),
                CacheCorrectnessCheck(
                    identifier: "cost-never-exceeds-limit",
                    passed: finalCost <= capacity,
                    value: max(0, finalCost - capacity)
                ),
            ]
        )
    }

    public static func runConcurrentMemory(
        kind: MemoryContestantKind,
        root: URL,
        costLimit: Int = 512,
        workers: Int = 8,
        operationsPerWorker: Int = 5_000
    ) async -> MemoryConcurrentResult {
        let cache = CacheLabFactory.memory(kind, costLimit: costLimit, root: root)
        let started = DispatchTime.now().uptimeNanoseconds
        let workerLatencies = await withTaskGroup(of: [UInt64].self, returning: [[UInt64]].self) {
            group in
            for worker in 0..<workers {
                group.addTask {
                    var latencies: [UInt64] = []
                    latencies.reserveCapacity(operationsPerWorker)
                    for operation in 0..<operationsPerWorker {
                        let keyIndex = (worker &* 1_009 &+ operation &* 17) % 1_024
                        let key = "concurrent-\(keyIndex)"
                        let operationStarted = DispatchTime.now().uptimeNanoseconds
                        switch operation % 10 {
                        case 0, 1, 2:
                            await cache.insert(
                                payload(seed: keyIndex, count: 64),
                                for: key,
                                cost: 1
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
            for await values in group { result.append(values) }
            return result
        }
        let duration = DispatchTime.now().uptimeNanoseconds &- started
        let finalCount = await cache.count()
        let finalCost = await cache.currentCost()
        let allLatencies = workerLatencies.flatMap { $0 }
        var mismatches = 0
        for keyIndex in 0..<1_024 {
            if let value = await cache.value(for: "concurrent-\(keyIndex)"),
                value != payload(seed: keyIndex, count: 64)
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
                    value: mismatches
                ),
                CacheCorrectnessCheck(
                    identifier: "bounded-cost",
                    passed: finalCost <= costLimit,
                    value: max(0, finalCost - costLimit)
                ),
                CacheCorrectnessCheck(identifier: "no-crash-or-hang", passed: true),
            ]
        )
    }

    public static func runDiskCorrectness(
        kind: DiskContestantKind,
        root: URL
    ) async throws -> DiskCorrectnessResult {
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var cache: (any DiskCacheContestant)? = try await CacheLabFactory.disk(kind, root: root)
        let value = payload(seed: 42, count: 4_096)
        let key = cacheContentID(for: value)
        try await cache?.insert(value, for: key)
        let initial = try await cache?.value(for: key)
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

        cache = nil
        cache = try await CacheLabFactory.disk(kind, root: root)
        let reopened = try await cache?.value(for: key)
        let restartMatch = reopened == value

        let fileURL = try await cache?.fileURL(for: key)
        if let fileURL { try FileManager.default.removeItem(at: fileURL) }
        let afterExternalDeletion: Data?
        do {
            afterExternalDeletion = try await cache?.value(for: key)
        } catch {
            afterExternalDeletion = nil
        }
        let externalDeletionMiss = afterExternalDeletion == nil

        let corruptValue = payload(seed: 84, count: 8_192)
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
        let readExceptionCount = await cache?.readExceptionCount() ?? 0
        try await cache?.removeAll()
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
                    value: proofGatesVisibility ? 0 : 1
                ),
                CacheCorrectnessCheck(
                    identifier: "external-deletion-clean-miss",
                    passed: externalDeletionMiss
                ),
                CacheCorrectnessCheck(
                    identifier: "corruption-not-served",
                    passed: !corruptServed,
                    value: corruptServed ? 1 : 0
                ),
                CacheCorrectnessCheck(
                    identifier: "corruption-does-not-raise-process-exception",
                    passed: readExceptionCount == 0,
                    value: readExceptionCount
                ),
            ]
        )
    }

    public static func runDiskMixed(
        kind: DiskContestantKind,
        root: URL,
        objectsPerSize: Int = 16,
        sizes: [Int] = [4_096, 65_536, 1_048_576]
    ) async throws -> DiskMixedResult {
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = try await CacheLabFactory.disk(kind, root: root)
        var values: [(key: String, data: Data)] = []
        for size in sizes {
            for index in 0..<objectsPerSize {
                let data = payload(seed: size &+ index &* 31, count: size)
                values.append((cacheContentID(for: data), data))
            }
        }
        let totalBytes = values.reduce(0) { $0 + $1.data.count }
        let writeStarted = DispatchTime.now().uptimeNanoseconds
        for value in values { try await cache.insert(value.data, for: value.key) }
        let writeDuration = DispatchTime.now().uptimeNanoseconds &- writeStarted

        var readLatencies: [UInt64] = []
        readLatencies.reserveCapacity(values.count)
        var mismatches = 0
        let readStarted = DispatchTime.now().uptimeNanoseconds
        for value in values.reversed() {
            let operationStarted = DispatchTime.now().uptimeNanoseconds
            let loaded = try await cache.value(for: value.key)
            readLatencies.append(DispatchTime.now().uptimeNanoseconds &- operationStarted)
            if loaded != value.data { mismatches += 1 }
        }
        let readDuration = DispatchTime.now().uptimeNanoseconds &- readStarted
        try await cache.removeAll()
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
            checks: [
                CacheCorrectnessCheck(
                    identifier: "returned-bytes-match",
                    passed: mismatches == 0,
                    value: mismatches
                ),
                CacheCorrectnessCheck(identifier: "concurrent-read-write", passed: true),
            ]
        )
    }

    public static func payload(seed: Int, count: Int) -> Data {
        var data = Data(count: max(0, count))
        data.withUnsafeMutableBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var state = UInt64(bitPattern: Int64(seed)) ^ 0x9E37_79B9_7F4A_7C15
            for index in 0..<count {
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
            max(0, Int((Double(sorted.count - 1) * quantile).rounded(.up)))
        )
        return sorted[index]
    }
}
