import CacheLabCore
import Foundation

private struct Arguments {
    let repetitions: Int
    let output: URL
    let formal: Bool
    let scope: String
    let formalBlockIndex: Int?
    let correctnessOnly: Bool

    init(_ values: [String]) throws {
        var repetitions = 3
        var output = URL(fileURLWithPath: ".artifacts/cache-lab/raw-results.json")
        var formal = false
        var scope = "all"
        var formalBlockIndex: Int?
        var correctnessOnly = false
        var index = 1
        while index < values.count {
            switch values[index] {
            case "--repetitions":
                guard index + 1 < values.count, let parsed = Int(values[index + 1]), parsed > 0
                else {
                    throw CacheLabError.invalidConfiguration
                }
                repetitions = parsed
                index += 2
            case "--output":
                guard index + 1 < values.count else { throw CacheLabError.invalidConfiguration }
                output = URL(fileURLWithPath: values[index + 1])
                index += 2
            case "--formal":
                formal = true
                index += 1
            case "--scope":
                guard index + 1 < values.count,
                      ["all", "memory", "hot", "concurrent"].contains(values[index + 1])
                else { throw CacheLabError.invalidConfiguration }
                scope = values[index + 1]
                index += 2
            case "--formal-block-index":
                guard index + 1 < values.count,
                      let parsed = Int(values[index + 1]), parsed >= 0
                else { throw CacheLabError.invalidConfiguration }
                formalBlockIndex = parsed
                index += 2
            case "--correctness-only":
                correctnessOnly = true
                index += 1
            default:
                throw CacheLabError.invalidConfiguration
            }
        }
        if formal {
            guard scope == "all" else { throw CacheLabError.invalidConfiguration }
            if correctnessOnly {
                guard formalBlockIndex == nil else { throw CacheLabError.invalidConfiguration }
            } else {
                guard repetitions == 1, formalBlockIndex != nil else {
                    throw CacheLabError.invalidConfiguration
                }
            }
        } else if correctnessOnly || formalBlockIndex != nil {
            throw CacheLabError.invalidConfiguration
        }
        self.repetitions = repetitions
        self.output = output
        self.formal = formal
        self.scope = scope
        self.formalBlockIndex = formalBlockIndex
        self.correctnessOnly = correctnessOnly
    }
}

@main
enum CacheLabMain {
    static func main() async throws {
        let arguments = try Arguments(CommandLine.arguments)
        let fileManager = FileManager.default
        let output = arguments.output.standardizedFileURL
        try fileManager.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let scratch = output.deletingLastPathComponent().appendingPathComponent(
            "scratch-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        var diskCorrectness: [DiskCorrectnessResult] = []
        if arguments.scope == "all", !arguments.formal || arguments.correctnessOnly {
            for kind in DiskContestantKind.allCases {
                let root = scratch.appendingPathComponent(
                    "correctness-\(kind.rawValue)", isDirectory: true
                )
                try await diskCorrectness.append(
                    CacheLabWorkloads.runDiskCorrectness(kind: kind, root: root)
                )
            }
        }

        let memoryInnerTrials = 3
        var runs: [CacheLabRunRecord] = []
        if !arguments.correctnessOnly {
            for localRepetition in 0 ..< arguments.repetitions {
                let repetition = arguments.formalBlockIndex ?? localRepetition
                var hotSamples: [MemoryContestantKind: [MemoryHotScanResult]] = [:]
                var concurrentSamples: [MemoryContestantKind: [MemoryConcurrentResult]] = [:]
                for trial in 0 ..< memoryInnerTrials {
                    let memoryOrder = rotated(
                        MemoryContestantKind.allCases,
                        by: repetition + trial
                    )
                    if arguments.scope != "concurrent" {
                        for kind in memoryOrder {
                            let root = scratch.appendingPathComponent(
                                "r\(repetition)-t\(trial)-hot-\(kind.rawValue)",
                                isDirectory: true
                            )
                            print(
                                "Cache Lab block \(repetition + 1) "
                                    + "trial \(trial + 1)/\(memoryInnerTrials): hot-scan \(kind.rawValue)"
                            )
                            await hotSamples[kind, default: []].append(
                                CacheLabWorkloads.runHotScan(kind: kind, root: root)
                            )
                        }
                    }
                    if arguments.scope != "hot" {
                        for kind in memoryOrder.reversed() {
                            let root = scratch.appendingPathComponent(
                                "r\(repetition)-t\(trial)-concurrent-\(kind.rawValue)",
                                isDirectory: true
                            )
                            print(
                                "Cache Lab block \(repetition + 1) "
                                    + "trial \(trial + 1)/\(memoryInnerTrials): concurrent \(kind.rawValue)"
                            )
                            await concurrentSamples[kind, default: []].append(
                                CacheLabWorkloads.runConcurrentMemory(kind: kind, root: root)
                            )
                        }
                    }
                }
                let hotScan =
                    arguments.scope == "concurrent"
                        ? []
                        : MemoryContestantKind.allCases.map {
                            CacheLabWorkloads.aggregateHotScan(hotSamples[$0] ?? [])
                        }
                let concurrent =
                    arguments.scope == "hot"
                        ? []
                        : MemoryContestantKind.allCases.map {
                            CacheLabWorkloads.aggregateConcurrentMemory(concurrentSamples[$0] ?? [])
                        }

                var diskMixed: [DiskMixedResult] = []
                if arguments.scope == "all" {
                    let diskOrder = rotated(DiskContestantKind.allCases, by: repetition)
                    for kind in diskOrder {
                        let root = scratch.appendingPathComponent(
                            "r\(repetition)-disk-\(kind.rawValue)", isDirectory: true
                        )
                        print(
                            "Cache Lab block \(repetition + 1): disk \(kind.rawValue)"
                        )
                        try await diskMixed.append(
                            CacheLabWorkloads.runDiskMixed(
                                kind: kind,
                                root: root,
                                objectsPerSize: arguments.formal ? 64 : 8
                            )
                        )
                    }
                }
                runs.append(
                    CacheLabRunRecord(
                        repetition: repetition,
                        memoryHotScan: hotScan,
                        memoryConcurrent: concurrent,
                        diskMixed: diskMixed
                    )
                )
            }
        }
        let report = try CacheLabReport(
            executionMode:
            arguments.correctnessOnly
                ? "formal-correctness"
                : (arguments.formal ? "formal-block" : "calibration"),
            benchmarkScope: arguments.scope,
            provisional: !arguments.formal,
            sourceIdentity: [
                "Fovea": ProcessInfo.processInfo.environment["FOVEA_CACHE_LAB_IDENTITY"]
                    ?? "current-worktree-unbound",
                "Akashic": ProcessInfo.processInfo.environment[
                    "FOVEA_CACHE_LAB_AKASHIC_IDENTITY"
                ] ?? "akashic-source-unbound",
                "LRUCache": "cb5b2bd0da83ad29c0bec762d39f41c8ad0eaf3e",
                "PINCache": "2fb85948463292c2e824148cf17dc62a4c217a94",
                "PINOperation": "a74f978733bdaf982758bfa23d70a189f4b4c1b6",
            ],
            experimentPlanDigest: requiredDigestEnvironment("FOVEA_CACHE_LAB_PLAN_DIGEST"),
            claimFamilyDigest: requiredDigestEnvironment("FOVEA_CLAIM_FAMILY_DIGEST"),
            diskCorrectness: diskCorrectness,
            runs: runs
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: output, options: .atomic)
        print("Cache Lab results: \(output.path)")
    }

    private static func requiredDigestEnvironment(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name],
              value.count == 64,
              value.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else {
            throw CacheLabError.invalidConfiguration
        }
        return value
    }

    private static func rotated<T>(_ values: [T], by amount: Int) -> [T] {
        guard !values.isEmpty else { return [] }
        let shift = amount % values.count
        return Array(values[shift...]) + Array(values[..<shift])
    }
}
