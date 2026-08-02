import CacheLabCore
import Foundation
import Testing

private func temporaryDirectory(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fovea-cache-lab-tests", isDirectory: true)
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test
func `All memory contestants preserve basic value and cost semantics`() async throws {
    for kind in MemoryContestantKind.allCases {
        let root = try temporaryDirectory("memory-basic-\(kind.rawValue)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CacheLabFactory.memory(kind, costLimit: 4, root: root)
        let first = CacheLabWorkloads.payload(seed: 1, count: 32)
        let replacement = CacheLabWorkloads.payload(seed: 2, count: 32)
        await cache.insert(first, for: "shared", cost: 2)
        #expect(await cache.value(for: "shared") == first, "\(kind.rawValue) initial value")
        await cache.insert(replacement, for: "shared", cost: 3)
        #expect(await cache.value(for: "shared") == replacement, "\(kind.rawValue) replacement")
        #expect(await cache.currentCost() <= 4, "\(kind.rawValue) bounded cost")
        await cache.removeValue(for: "shared")
        #expect(await cache.value(for: "shared") == nil, "\(kind.rawValue) removal")
        await cache.removeAll()
        #expect(await cache.count() == 0, "\(kind.rawValue) clear")
    }
}

@Test
func `Fovea SIEVE resists a one-hit scan at least as well as specialist caches`() async throws {
    var results: [MemoryContestantKind: MemoryHotScanResult] = [:]
    for kind in MemoryContestantKind.allCases {
        let root = try temporaryDirectory("memory-scan-\(kind.rawValue)")
        defer { try? FileManager.default.removeItem(at: root) }
        results[kind] = await CacheLabWorkloads.runHotScan(
            kind: kind,
            root: root,
            capacity: 128,
            hotObjectCount: 32,
            scanObjectCount: 4096,
        )
    }
    let fovea = try #require(results[.fovea])
    #expect(fovea.checks.allSatisfy { $0.passed })
    #expect(fovea.hotObjectCount == 20 * 32)
    #expect(fovea.scanObjectCount == 20 * 4096)
    #expect(fovea.operations == 20 * (4096 + 32))
    #expect(fovea.hotHits == fovea.hotObjectCount)
    for kind in [MemoryContestantKind.lruCache, .pinMemoryCache] {
        let comparator = try #require(results[kind])
        #expect(fovea.hotSetHitRate >= comparator.hotSetHitRate)
    }
}

@Test
func `All memory contestants remain bounded and coherent under concurrent mixed access`() async throws {
    for kind in MemoryContestantKind.allCases {
        let root = try temporaryDirectory("memory-concurrent-\(kind.rawValue)")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await CacheLabWorkloads.runConcurrentMemory(
            kind: kind,
            root: root,
            costLimit: 256,
            workers: 8,
            operationsPerWorker: 1000,
        )
        #expect(result.checks.allSatisfy { $0.passed }, "\(kind.rawValue) concurrent checks")
        #expect(result.finalCost <= 256)
    }
}

@Test
func `Fovea and PIN disk stores persist, converge after external deletion, and reject corruption`() async throws {
    for kind in DiskContestantKind.allCases {
        let root = try temporaryDirectory("disk-adversarial-\(kind.rawValue)")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await CacheLabWorkloads.runDiskCorrectness(kind: kind, root: root)
        let checks = Dictionary(uniqueKeysWithValues: result.checks.map { ($0.identifier, $0) })
        if kind == .fovea || kind == .pinDiskCacheDurableValidated {
            #expect(result.checks.allSatisfy { $0.passed }, "\(kind.rawValue) disk checks")
        } else {
            #expect(checks["initial-read"]?.passed == true)
            #expect(checks["restart-persistence"]?.passed == true)
            #expect(checks["external-deletion-clean-miss"]?.passed == true)
            #expect(checks["corruption-not-served"]?.passed == true)
            #expect(checks["corruption-does-not-raise-process-exception"]?.passed == false)
        }
    }
}

@Test
func `Fovea and PIN disk stores return exact bytes across a mixed-size corpus`() async throws {
    for kind in DiskContestantKind.allCases {
        let root = try temporaryDirectory("disk-mixed-\(kind.rawValue)")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await CacheLabWorkloads.runDiskMixed(
            kind: kind,
            root: root,
            objectsPerSize: 2,
            sizes: [4096, 65536, 262_144],
        )
        #expect(result.checks.allSatisfy { $0.passed }, "\(kind.rawValue) mixed disk checks")
        #expect(result.p99ReadSampleCount == 8 * 2 * 3)
        #expect(
            result.checks.contains {
                $0.identifier == "background-work-does-not-cross-measurement-window"
                    && $0.passed
            },
        )
    }
}

@Test
func `Durable PIN wrapper hides native objects until a valid proof is published`() async throws {
    let root = try temporaryDirectory("pin-proof-visibility")
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try PINDurableValidatedDiskContestant(root: root)
    let value = CacheLabWorkloads.payload(seed: 91, count: 8192)
    let key = cacheContentID(for: value)
    try await cache.insert(value, for: key)
    #expect(try await cache.value(for: key) == value)

    let proofURL =
        root
            .appendingPathComponent(".fovea-durable-validation-v1", isDirectory: true)
            .appendingPathComponent("\(key).proof", isDirectory: false)
    try FileManager.default.removeItem(at: proofURL)
    #expect(try await cache.value(for: key) == nil)
}

@Test
func `Disk contestant roles prevent native PIN writes from entering the D5 ranking`() {
    #expect(DiskContestantKind.fovea.durabilityLevel == "D5")
    #expect(DiskContestantKind.pinDiskCacheDurableValidated.durabilityLevel == "D5")
    #expect(DiskContestantKind.pinDiskCacheDurableValidated.rankingRole == "primary")
    #expect(DiskContestantKind.pinDiskCacheNative.durabilityLevel == "D1")
    #expect(DiskContestantKind.pinDiskCacheNative.rankingRole == "descriptive")
    #expect(
        DiskContestantKind.pinDiskCacheNative.semanticGroup
            != DiskContestantKind.fovea.semanticGroup,
    )
}
