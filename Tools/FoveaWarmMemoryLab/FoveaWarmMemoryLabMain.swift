import CryptoKit
import Foundation
@_spi(FoveaBenchmarking) import FoveaCore
import FoveaHTTP
import FoveaPersistence
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO

private enum LabError: Error {
    case invalidArguments
    case missingFinal
    case pixelMismatch
}

private struct Options {
    let output: URL
    let iterations: Int
    let targetWidth: Int
    let targetHeight: Int

    init(_ arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw LabError.invalidArguments }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let output = values["--output"],
            let iterations = values["--iterations"].flatMap(Int.init),
            let targetWidth = values["--target-width"].flatMap(Int.init),
            let targetHeight = values["--target-height"].flatMap(Int.init),
            (10...10_000).contains(iterations),
            (1...16_384).contains(targetWidth),
            (1...16_384).contains(targetHeight)
        else { throw LabError.invalidArguments }
        self.output = URL(fileURLWithPath: output)
        self.iterations = iterations
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
    }
}

private struct DurationSummary: Codable {
    let medianNanoseconds: UInt64
    let p95Nanoseconds: UInt64
    let samplesNanoseconds: [UInt64]
}

private struct BreakdownSamples: Codable {
    let requestValidation: DurationSummary
    let namespaceGeneration: DurationSummary
    let aliasAuthorization: DurationSummary
    let aliasIndexLookup: DurationSummary
    let representationAuthorization: DurationSummary
    let varySelection: DurationSummary
    let fixedIdentityAuthorization: DurationSummary
    let renderedImageLookup: DurationSummary
    let freshnessClock: DurationSummary
    let freshnessEvaluation: DurationSummary
    let activeNamespaceFence: DurationSummary
    let cancellationFence: DurationSummary
    let coordinatorTotal: DurationSummary
    let total: DurationSummary
}

private struct RuntimeFingerprint: Codable {
    let operatingSystemVersion: String
    let architecture: String
    let processorCount: Int
    let activeProcessorCount: Int
}

private struct Report: Codable {
    let schemaVersion: UInt16
    let evidenceVersion: String
    let runtime: RuntimeFingerprint
    let fixtureName: String
    let fixtureByteCount: Int
    let fixtureSHA256: String
    let targetWidth: Int
    let targetHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let warmupIterations: Int
    let measuredIterations: Int
    let orderCounts: [String: Int]
    let publicImage: DurationSummary
    let publicEvents: DurationSummary
    let internalBreakdown: BreakdownSamples
}

@main
private enum FoveaWarmMemoryLab {
    static func main() async throws {
        let options = try Options(CommandLine.arguments)
        let fixture = try await PreparedWarmMemoryFixture.make(options: options)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let samples = try await collectSamples(
            pipeline: fixture.pipeline,
            request: fixture.request,
            measuredIterations: options.iterations
        )
        let report = makeReport(options: options, fixture: fixture, samples: samples)
        try write(report, to: options.output)
    }
}

private struct PreparedWarmMemoryFixture {
    let root: URL
    let pipeline: FoveaPipeline
    let request: ImageRequest
    let initial: DecodedImage
    let fixtureName: String
    let fixtureByteCount: Int
    let fixtureSHA256: String

    static func make(options: Options) async throws -> PreparedWarmMemoryFixture {
        let fixture = try BenchmarkFixtureCatalog.load(named: "hero-48mp-8000x6000.jpg")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fovea-warm-memory-lab-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let transport = FakeHTTPTransport(
            stubs: [
                FakeHTTPTransport.Stub(
                    statusCode: 200,
                    headers: [
                        "cache-control": "public, max-age=3600",
                        "content-type": "image/jpeg",
                        "content-length": String(fixture.data.count),
                    ],
                    body: fixture.data
                )
            ]
        )
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded", isDirectory: true),
            softLimitBytes: 64 * 1_024 * 1_024
        )
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records", isDirectory: true)
        )
        let pipeline = FoveaPipeline(
            configuration: PipelineConfiguration(memoryCostLimit: 64 * 1_024 * 1_024),
            transport: transport,
            encodedStore: encoded,
            recordStore: records,
            profileAccessPolicy: .publicOnly,
            codec: ImageIOImageDecoder()
        )
        let request = try ImageRequest.publicImage(
            url: URL(string: "https://benchmark.invalid/hero-48mp.jpg")!,
            logicalSource: LogicalSourceID("benchmark:hero-48mp"),
            target: try TargetPixels(width: options.targetWidth, height: options.targetHeight),
            colorPolicy: .convertToSRGB,
            appID: "fovea-warm-memory-lab"
        )
        let initial = try await pipeline.image(for: request)
        let second = try await pipeline.image(for: request)
        guard initial.pixelWidth == second.pixelWidth,
            initial.pixelHeight == second.pixelHeight
        else { throw LabError.pixelMismatch }
        return PreparedWarmMemoryFixture(
            root: root,
            pipeline: pipeline,
            request: request,
            initial: initial,
            fixtureName: fixture.metadata.resourceID,
            fixtureByteCount: fixture.data.count,
            fixtureSHA256: sha256(fixture.data)
        )
    }
}

private struct WarmMemorySamples {
    let publicImage: [UInt64]
    let publicEvents: [UInt64]
    let timings: [FoveaWarmMemoryTimingSample]
    let orderCounts: [String: Int]
}

private func collectSamples(
    pipeline: FoveaPipeline,
    request: ImageRequest,
    measuredIterations: Int
) async throws -> WarmMemorySamples {
    let warmups = 20
    var images: [UInt64] = []
    var events: [UInt64] = []
    var timings: [FoveaWarmMemoryTimingSample] = []
    var orderCounts: [String: Int] = [:]
    for iteration in 0..<(warmups + measuredIterations) {
        let rotation = iteration % 3
        let sample = try await measureRotation(rotation, pipeline: pipeline, request: request)
        guard iteration >= warmups else { continue }
        orderCounts["rotation-\(rotation)", default: 0] += 1
        images.append(sample.image)
        events.append(sample.events)
        timings.append(sample.timing)
    }
    return WarmMemorySamples(
        publicImage: images,
        publicEvents: events,
        timings: timings,
        orderCounts: orderCounts
    )
}

private func measureRotation(
    _ rotation: Int,
    pipeline: FoveaPipeline,
    request: ImageRequest
) async throws -> (image: UInt64, events: UInt64, timing: FoveaWarmMemoryTimingSample) {
    switch rotation {
    case 0:
        let image = try await measure { _ = try await pipeline.image(for: request) }
        let events = try await measure { try await consumeFinal(pipeline.events(for: request)) }
        return (image, events, try await pipeline.warmMemoryTimingForBenchmarking(request))
    case 1:
        let timing = try await pipeline.warmMemoryTimingForBenchmarking(request)
        let image = try await measure { _ = try await pipeline.image(for: request) }
        let events = try await measure { try await consumeFinal(pipeline.events(for: request)) }
        return (image, events, timing)
    default:
        let events = try await measure { try await consumeFinal(pipeline.events(for: request)) }
        let timing = try await pipeline.warmMemoryTimingForBenchmarking(request)
        let image = try await measure { _ = try await pipeline.image(for: request) }
        return (image, events, timing)
    }
}

private func makeReport(
    options: Options,
    fixture: PreparedWarmMemoryFixture,
    samples: WarmMemorySamples
) -> Report {
    Report(
        schemaVersion: 1,
        evidenceVersion: "fovea-warm-memory-control-plane-v1",
        runtime: runtimeFingerprint(),
        fixtureName: fixture.fixtureName,
        fixtureByteCount: fixture.fixtureByteCount,
        fixtureSHA256: fixture.fixtureSHA256,
        targetWidth: options.targetWidth,
        targetHeight: options.targetHeight,
        outputWidth: fixture.initial.pixelWidth,
        outputHeight: fixture.initial.pixelHeight,
        warmupIterations: 20,
        measuredIterations: options.iterations,
        orderCounts: samples.orderCounts,
        publicImage: summary(samples.publicImage),
        publicEvents: summary(samples.publicEvents),
        internalBreakdown: BreakdownSamples(
            requestValidation: summary(samples.timings.map(\.requestValidationNanoseconds)),
            namespaceGeneration: summary(samples.timings.map(\.namespaceGenerationNanoseconds)),
            aliasAuthorization: summary(samples.timings.map(\.aliasAuthorizationNanoseconds)),
            aliasIndexLookup: summary(samples.timings.map(\.aliasIndexLookupNanoseconds)),
            representationAuthorization: summary(
                samples.timings.map(\.representationAuthorizationNanoseconds)
            ),
            varySelection: summary(samples.timings.map(\.varySelectionNanoseconds)),
            fixedIdentityAuthorization: summary(
                samples.timings.map(\.fixedIdentityAuthorizationNanoseconds)
            ),
            renderedImageLookup: summary(samples.timings.map(\.renderedImageLookupNanoseconds)),
            freshnessClock: summary(samples.timings.map(\.freshnessClockNanoseconds)),
            freshnessEvaluation: summary(samples.timings.map(\.freshnessEvaluationNanoseconds)),
            activeNamespaceFence: summary(samples.timings.map(\.activeNamespaceFenceNanoseconds)),
            cancellationFence: summary(samples.timings.map(\.cancellationFenceNanoseconds)),
            coordinatorTotal: summary(samples.timings.map(\.coordinatorTotalNanoseconds)),
            total: summary(samples.timings.map(\.totalNanoseconds))
        )
    )
}

private func write(_ report: Report, to output: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try encoder.encode(report).write(to: output, options: .atomic)
}

private func consumeFinal(
    _ events: AsyncThrowingStream<ImageLoadingEvent, any Error>
) async throws {
    for try await event in events {
        if case .final = event { return }
    }
    throw LabError.missingFinal
}

private func measure(_ operation: () async throws -> Void) async rethrows -> UInt64 {
    let started = DispatchTime.now().uptimeNanoseconds
    try await operation()
    return DispatchTime.now().uptimeNanoseconds &- started
}

private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw LabError.missingFinal }
    return value
}

private func summary(_ samples: [UInt64]) -> DurationSummary {
    precondition(!samples.isEmpty)
    let sorted = samples.sorted()
    let middle = sorted.count / 2
    let median: UInt64
    if sorted.count.isMultiple(of: 2) {
        median =
            sorted[middle - 1] / 2 + sorted[middle] / 2
            + (sorted[middle - 1] % 2 + sorted[middle] % 2) / 2
    } else {
        median = sorted[middle]
    }
    let p95Index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
    return DurationSummary(
        medianNanoseconds: median,
        p95Nanoseconds: sorted[p95Index],
        samplesNanoseconds: samples
    )
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func runtimeFingerprint() -> RuntimeFingerprint {
    #if arch(arm64)
        let architecture = "arm64"
    #elseif arch(x86_64)
        let architecture = "x86_64"
    #else
        let architecture = "other"
    #endif
    let info = ProcessInfo.processInfo
    return RuntimeFingerprint(
        operatingSystemVersion: info.operatingSystemVersionString,
        architecture: architecture,
        processorCount: info.processorCount,
        activeProcessorCount: info.activeProcessorCount
    )
}
