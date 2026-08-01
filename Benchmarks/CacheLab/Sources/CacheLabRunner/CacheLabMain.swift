import CacheLabCore
import Foundation

private struct Arguments {
    let repetitions: Int
    let output: URL
    let formal: Bool

    init(_ values: [String]) throws {
        var repetitions = 3
        var output = URL(fileURLWithPath: ".artifacts/cache-lab/raw-results.json")
        var formal = false
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
            default:
                throw CacheLabError.invalidConfiguration
            }
        }
        if formal, repetitions < 20 { throw CacheLabError.invalidConfiguration }
        self.repetitions = repetitions
        self.output = output
        self.formal = formal
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
        for kind in DiskContestantKind.allCases {
            let root = scratch.appendingPathComponent(
                "correctness-\(kind.rawValue)", isDirectory: true)
            diskCorrectness.append(
                try await CacheLabWorkloads.runDiskCorrectness(kind: kind, root: root)
            )
        }

        var runs: [CacheLabRunRecord] = []
        for repetition in 0..<arguments.repetitions {
            let memoryOrder = rotated(MemoryContestantKind.allCases, by: repetition)
            let diskOrder = rotated(DiskContestantKind.allCases, by: repetition)
            var hotScan: [MemoryHotScanResult] = []
            var concurrent: [MemoryConcurrentResult] = []
            var diskMixed: [DiskMixedResult] = []
            for kind in memoryOrder {
                let root = scratch.appendingPathComponent(
                    "r\(repetition)-hot-\(kind.rawValue)", isDirectory: true)
                print(
                    "Cache Lab \(repetition + 1)/\(arguments.repetitions): hot-scan \(kind.rawValue)"
                )
                hotScan.append(
                    await CacheLabWorkloads.runHotScan(kind: kind, root: root)
                )
            }
            for kind in memoryOrder.reversed() {
                let root = scratch.appendingPathComponent(
                    "r\(repetition)-concurrent-\(kind.rawValue)", isDirectory: true)
                print(
                    "Cache Lab \(repetition + 1)/\(arguments.repetitions): concurrent \(kind.rawValue)"
                )
                concurrent.append(
                    await CacheLabWorkloads.runConcurrentMemory(kind: kind, root: root)
                )
            }
            for kind in diskOrder {
                let root = scratch.appendingPathComponent(
                    "r\(repetition)-disk-\(kind.rawValue)", isDirectory: true)
                print("Cache Lab \(repetition + 1)/\(arguments.repetitions): disk \(kind.rawValue)")
                diskMixed.append(
                    try await CacheLabWorkloads.runDiskMixed(
                        kind: kind,
                        root: root,
                        objectsPerSize: arguments.formal ? 64 : 8
                    )
                )
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
        let report = CacheLabReport(
            executionMode: arguments.formal ? "formal" : "calibration",
            provisional: !arguments.formal,
            sourceIdentity: [
                "Fovea": ProcessInfo.processInfo.environment["FOVEA_CACHE_LAB_IDENTITY"]
                    ?? "current-worktree-unbound",
                "LRUCache": "cb5b2bd0da83ad29c0bec762d39f41c8ad0eaf3e",
                "PINCache": "2fb85948463292c2e824148cf17dc62a4c217a94",
                "PINOperation": "a74f978733bdaf982758bfa23d70a189f4b4c1b6",
            ],
            experimentPlanDigest: try requiredDigestEnvironment("FOVEA_CACHE_LAB_PLAN_DIGEST"),
            claimFamilyDigest: try requiredDigestEnvironment("FOVEA_CLAIM_FAMILY_DIGEST"),
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
