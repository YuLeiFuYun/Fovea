import CryptoKit
import Foundation
import FoveaCore
import FoveaSystem
import ImageCraftCore

struct ProgressiveResourceRequestOutcome: Codable, Sendable {
    let requestIndex: Int
    let previewCount: Int
    let finalCount: Int
    let finalPixelWidth: Int
    let finalPixelHeight: Int
    let targetInvariantSatisfied: Bool
}

struct ProgressiveResourceConfigurationSummary: Codable, Sendable {
    let baselinePhysicalFootprintBytes: UInt64
    let peakPhysicalFootprintBytes: UInt64
    let peakPhysicalFootprintDeltaBytes: Int64
    let baselinePhysicalFootprintLifetimePeakBytes: UInt64
    let firstPreparationPhysicalFootprintLifetimePeakBytes: UInt64
    let firstPreparationPhysicalFootprintLifetimePeakIncreaseBytes: UInt64
    let progressivePhaseBarrierPhysicalFootprintBytes: UInt64
    let progressivePhaseBarrierPhysicalFootprintLifetimePeakBytes: UInt64
    let progressivePhaseBarrierPhysicalFootprintLifetimePeakIncreaseBytes: UInt64
    let progressivePhaseBarrierPreparationOwnerCount: Int
    let progressivePhaseBarrierReadyCount: Int
    let fullRunPhysicalFootprintLifetimePeakBytes: UInt64
    let fullRunPhysicalFootprintLifetimePeakIncreaseBytes: UInt64
    let firstPreparationLifetimePeakCoversCompleteProgressivePhase: Bool
    let peakHostVisibleLogicalBytes: Int
    let peakTransportLogicalBytes: Int
    let peakRelayPendingBytes: Int
    let peakProgressHandoffBytes: Int
    let peakSessionEncodedBytes: Int
    let peakPreparationEncodedBytes: Int
    let peakPreviewLogicalBytes: Int
    let peakActiveSessionCount: Int
    let peakActivePreparationCount: Int
    let finalOwnerBytesAllZero: Bool
    let completedRequestCount: Int
    let previewCount: Int
    let finalCount: Int
    let targetPixelInvariantSatisfied: Bool
    let recorderDroppedSampleCount: UInt64
    let periodicSampleCount: Int
    let allFootprintSamplesAvailable: Bool
    let allLifetimePeakSamplesAvailable: Bool
}

struct ProgressiveResourceMechanismReport: Codable, Sendable {
    let schemaVersion: Int
    let contract: String
    let evidenceClass: String
    let fixtureSHA256: String
    let fixtureByteCount: Int
    let protocolChunkByteCount: Int
    let periodicFootprintSampleMilliseconds: Int
    let targetPixels: Int
    let progressiveConcurrency: Int
    let transportMemoryThreshold: Int
    let outcomes: [ProgressiveResourceRequestOutcome]
    let summary: ProgressiveResourceConfigurationSummary
    let samples: [FoveaProgressiveResourceSample]
    let allCorrect: Bool
}

enum ProgressiveResourceMechanismLab {
    private struct Fixture {
        let url: URL
        let sha256: String
    }

    private static let baselineFixtureSHA256 =
        "494941339b490cededbb482a47ff7e1352761a4dcc93c82527775ae46c573a87"
    private static let heldOut12MPFixtureSHA256 =
        "cf7b122e910c285cd1af565022c65d9fcfc003c38033b91eaac24ea0d7cde716"
    private static let protocolChunkByteCount = 32 * 1024
    private static let periodicFootprintSampleMilliseconds = 1

    static func run(options: NetworkLabOptions) async throws -> ProgressiveResourceMechanismReport {
        let target = options.progressiveTargetPixels
        let concurrency = options.progressiveConcurrency
        let threshold = options.progressiveTransportThreshold
        guard (1...4_096).contains(target), (1...16).contains(concurrency),
            (1...(4 * 1024 * 1024)).contains(threshold)
        else {
            throw ProgressiveResourceMechanismError.invalidConfiguration
        }

        let fixtureSpec = fixture(options: options)
        let fixture = try Data(contentsOf: fixtureSpec.url)
        guard digestHex(fixture) == fixtureSpec.sha256 else {
            throw ProgressiveResourceMechanismError.fixtureDigestMismatch
        }
        ProgressiveResourceURLProtocol.configure(
            body: fixture,
            chunkByteCount: protocolChunkByteCount
        )

        let root =
            options.cacheRoot
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "FoveaProgressiveResourceLab-\(UUID().uuidString)",
                isDirectory: true
            )
        if options.cacheRoot == nil {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        defer {
            if !options.keepCache, options.cacheRoot == nil {
                try? FileManager.default.removeItem(at: root)
            }
        }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProgressiveResourceURLProtocol.self]
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.httpShouldSetCookies = false

        let configuration = PipelineConfiguration(
            memoryCostLimit: 1,
            maximumTransportBytes: fixture.count + 1,
            transportMemoryThreshold: threshold,
            maximumConcurrentFetches: max(1, concurrency),
            maximumConcurrentDecodes: max(1, concurrency),
            maximumDecodeWorkingSetBytes: 192 * 1024 * 1024,
            maximumQueuedFetches: max(16, concurrency * 4),
            maximumQueuedDecodes: max(16, concurrency * 4)
        )
        let recorder = FoveaProgressiveResourceRecorder(
            capacity: 16_384,
            preparationBarrierTarget: concurrency
        )
        let system = try await FoveaSystemPipeline.openProgressiveResourceLab(
            cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
            configuration: configuration,
            sessionConfiguration: sessionConfiguration,
            stagingDirectory: root.appendingPathComponent("staging", isDirectory: true),
            recorder: recorder,
            renderedImageCache: ProgressiveResourceNullRenderedCache()
        )
        recorder.recordBaseline()
        let periodicSampler = Task {
            while !Task.isCancelled {
                recorder.recordPeriodicFootprint()
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(periodicFootprintSampleMilliseconds) * 1_000_000
                    )
                } catch {
                    return
                }
            }
        }

        let outcomes: [ProgressiveResourceRequestOutcome]
        do {
            outcomes = try await withThrowingTaskGroup(
                of: ProgressiveResourceRequestOutcome.self,
                returning: [ProgressiveResourceRequestOutcome].self
            ) { group in
                for requestIndex in 0..<concurrency {
                    group.addTask {
                        try await executeRequest(
                            pipeline: system.pipeline,
                            requestIndex: requestIndex,
                            target: target
                        )
                    }
                }
                var values: [ProgressiveResourceRequestOutcome] = []
                values.reserveCapacity(concurrency)
                for try await value in group { values.append(value) }
                return values.sorted { $0.requestIndex < $1.requestIndex }
            }
        } catch {
            periodicSampler.cancel()
            await periodicSampler.value
            await system.invalidateAndCancel()
            throw error
        }

        periodicSampler.cancel()
        await periodicSampler.value
        recorder.recordAllRequestsDrained()
        let snapshot = recorder.snapshot()
        await system.invalidateAndCancel()

        let barrierSamples = snapshot.samples.filter {
            $0.transition == .progressivePhaseBarrierReady
        }
        guard barrierSamples.count == 1,
            let barrierSample = barrierSamples.first,
            let baselineSample = snapshot.samples.first(where: {
                $0.transition == .baselineAfterSetup
            }), let baseline = baselineSample.taskPhysicalFootprintBytes,
            let baselineLifetimePeak = baselineSample.taskPhysicalFootprintLifetimePeakBytes,
            let firstPreparationLifetimePeak = snapshot.samples.first(where: {
                $0.transition == .preparationTransferred
            })?.taskPhysicalFootprintLifetimePeakBytes,
            let barrierPhysical = barrierSample.taskPhysicalFootprintBytes,
            let barrierLifetimePeak = barrierSample.taskPhysicalFootprintLifetimePeakBytes,
            let fullRunLifetimePeak = snapshot.samples.last?.taskPhysicalFootprintLifetimePeakBytes
        else {
            throw ProgressiveResourceMechanismError.missingPhysicalFootprint
        }
        let physicalSamples = snapshot.samples.compactMap(\.taskPhysicalFootprintBytes)
        guard let peakPhysical = physicalSamples.max() else {
            throw ProgressiveResourceMechanismError.missingPhysicalFootprint
        }
        let summary = summarize(
            snapshot: snapshot,
            outcomes: outcomes,
            baselinePhysical: baseline,
            peakPhysical: peakPhysical,
            baselineLifetimePeak: baselineLifetimePeak,
            firstPreparationLifetimePeak: firstPreparationLifetimePeak,
            barrierPhysical: barrierPhysical,
            barrierLifetimePeak: barrierLifetimePeak,
            barrierPreparationOwnerCount: barrierSample.activePreparationOwnerCount,
            barrierReadyCount: barrierSamples.count,
            fullRunLifetimePeak: fullRunLifetimePeak,
            concurrency: concurrency
        )
        let allCorrect =
            summary.finalOwnerBytesAllZero
            && summary.completedRequestCount == concurrency
            && summary.finalCount == concurrency
            && summary.targetPixelInvariantSatisfied
            && summary.recorderDroppedSampleCount == 0
            && summary.periodicSampleCount > 0
            && summary.allFootprintSamplesAvailable
            && summary.firstPreparationPhysicalFootprintLifetimePeakBytes
                >= summary.baselinePhysicalFootprintLifetimePeakBytes
            && summary.progressivePhaseBarrierPhysicalFootprintLifetimePeakBytes
                >= summary.firstPreparationPhysicalFootprintLifetimePeakBytes
            && summary.fullRunPhysicalFootprintLifetimePeakBytes
                >= summary.progressivePhaseBarrierPhysicalFootprintLifetimePeakBytes
            && summary.progressivePhaseBarrierPreparationOwnerCount == concurrency
            && summary.progressivePhaseBarrierReadyCount == 1
            && summary.peakActiveSessionCount == concurrency
            && summary.peakActivePreparationCount > 0
            && summary.peakPreparationEncodedBytes >= fixture.count

        return ProgressiveResourceMechanismReport(
            schemaVersion: 1,
            contract: "progressive-resource-envelope-v1",
            evidenceClass: "offline-urlprotocol-production-transport-directional-only",
            fixtureSHA256: fixtureSpec.sha256,
            fixtureByteCount: fixture.count,
            protocolChunkByteCount: protocolChunkByteCount,
            periodicFootprintSampleMilliseconds: periodicFootprintSampleMilliseconds,
            targetPixels: target,
            progressiveConcurrency: concurrency,
            transportMemoryThreshold: threshold,
            outcomes: outcomes,
            summary: summary,
            samples: snapshot.samples,
            allCorrect: allCorrect
        )
    }

    private static func executeRequest(
        pipeline: FoveaPipeline,
        requestIndex: Int,
        target: Int
    ) async throws -> ProgressiveResourceRequestOutcome {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "progressive-resource.example.test"
        components.path = "/w4-progressive.jpg"
        components.queryItems = [
            URLQueryItem(name: "request", value: String(requestIndex)),
            URLQueryItem(name: "nonce", value: UUID().uuidString.lowercased()),
        ]
        guard let url = components.url else {
            throw ProgressiveResourceMechanismError.invalidConfiguration
        }
        let request = try ImageRequest.publicImage(
            url: url,
            target: TargetPixels(width: target, height: target),
            appID: "dev.fovea.h013"
        )

        var previewCount = 0
        var finalCount = 0
        var finalWidth = 0
        var finalHeight = 0
        for try await event in pipeline.events(for: request) {
            switch event {
            case .preview(let image, _):
                previewCount += 1
                guard image.pixelWidth <= target, image.pixelHeight <= target else {
                    throw ProgressiveResourceMechanismError.targetInvariantFailed
                }
            case .final(let image):
                finalCount += 1
                finalWidth = image.pixelWidth
                finalHeight = image.pixelHeight
            }
        }
        return ProgressiveResourceRequestOutcome(
            requestIndex: requestIndex,
            previewCount: previewCount,
            finalCount: finalCount,
            finalPixelWidth: finalWidth,
            finalPixelHeight: finalHeight,
            targetInvariantSatisfied: finalCount == 1
                && finalWidth > 0 && finalHeight > 0
                && finalWidth <= target && finalHeight <= target
        )
    }

    private static func summarize(
        snapshot: FoveaProgressiveResourceSnapshot,
        outcomes: [ProgressiveResourceRequestOutcome],
        baselinePhysical: UInt64,
        peakPhysical: UInt64,
        baselineLifetimePeak: UInt64,
        firstPreparationLifetimePeak: UInt64,
        barrierPhysical: UInt64,
        barrierLifetimePeak: UInt64,
        barrierPreparationOwnerCount: Int,
        barrierReadyCount: Int,
        fullRunLifetimePeak: UInt64,
        concurrency: Int
    ) -> ProgressiveResourceConfigurationSummary {
        let peakDelta: Int64
        if peakPhysical >= baselinePhysical {
            peakDelta = Int64(min(UInt64(Int64.max), peakPhysical - baselinePhysical))
        } else {
            peakDelta = -Int64(min(UInt64(Int64.max), baselinePhysical - peakPhysical))
        }
        return ProgressiveResourceConfigurationSummary(
            baselinePhysicalFootprintBytes: baselinePhysical,
            peakPhysicalFootprintBytes: peakPhysical,
            peakPhysicalFootprintDeltaBytes: peakDelta,
            baselinePhysicalFootprintLifetimePeakBytes: baselineLifetimePeak,
            firstPreparationPhysicalFootprintLifetimePeakBytes: firstPreparationLifetimePeak,
            firstPreparationPhysicalFootprintLifetimePeakIncreaseBytes:
                nonnegativeDelta(firstPreparationLifetimePeak, from: baselineLifetimePeak),
            progressivePhaseBarrierPhysicalFootprintBytes: barrierPhysical,
            progressivePhaseBarrierPhysicalFootprintLifetimePeakBytes: barrierLifetimePeak,
            progressivePhaseBarrierPhysicalFootprintLifetimePeakIncreaseBytes:
                nonnegativeDelta(barrierLifetimePeak, from: baselineLifetimePeak),
            progressivePhaseBarrierPreparationOwnerCount: barrierPreparationOwnerCount,
            progressivePhaseBarrierReadyCount: barrierReadyCount,
            fullRunPhysicalFootprintLifetimePeakBytes: fullRunLifetimePeak,
            fullRunPhysicalFootprintLifetimePeakIncreaseBytes:
                nonnegativeDelta(fullRunLifetimePeak, from: baselineLifetimePeak),
            firstPreparationLifetimePeakCoversCompleteProgressivePhase: concurrency == 1,
            peakHostVisibleLogicalBytes: snapshot.samples.map(\.hostVisibleLogicalBytes).max() ?? 0,
            peakTransportLogicalBytes: snapshot.samples.map(\.transportLogicalBytes).max() ?? 0,
            peakRelayPendingBytes: snapshot.samples.map(\.relayPendingBytes).max() ?? 0,
            peakProgressHandoffBytes: snapshot.samples.map(\.progressHandoffBytes).max() ?? 0,
            peakSessionEncodedBytes: snapshot.samples.map(\.sessionEncodedBytes).max() ?? 0,
            peakPreparationEncodedBytes: snapshot.samples.map(\.preparationEncodedBytes).max() ?? 0,
            peakPreviewLogicalBytes: snapshot.samples.map(\.previewLogicalBytes).max() ?? 0,
            peakActiveSessionCount: snapshot.samples.map(\.activeSessionCount).max() ?? 0,
            peakActivePreparationCount: snapshot.samples.map(\.activePreparationOwnerCount).max()
                ?? 0,
            finalOwnerBytesAllZero: snapshot.activeTransportOwnerCount == 0
                && snapshot.activeRelayOwnerCount == 0
                && snapshot.activeSessionCount == 0
                && snapshot.activePreparationOwnerCount == 0
                && snapshot.activePreviewOwnerCount == 0
                && snapshot.transportLogicalBytes == 0
                && snapshot.relayPendingBytes == 0
                && snapshot.progressHandoffBytes == 0
                && snapshot.sessionEncodedBytes == 0
                && snapshot.preparationEncodedBytes == 0
                && snapshot.previewLogicalBytes == 0,
            completedRequestCount: outcomes.count,
            previewCount: outcomes.reduce(0) { $0 + $1.previewCount },
            finalCount: outcomes.reduce(0) { $0 + $1.finalCount },
            targetPixelInvariantSatisfied: outcomes.allSatisfy(\.targetInvariantSatisfied),
            recorderDroppedSampleCount: snapshot.droppedSampleCount,
            periodicSampleCount: snapshot.samples.count {
                $0.transition == .periodicFootprint
            },
            allFootprintSamplesAvailable: snapshot.samples.allSatisfy {
                $0.taskPhysicalFootprintBytes != nil
            },
            allLifetimePeakSamplesAvailable: snapshot.samples.allSatisfy {
                $0.taskPhysicalFootprintLifetimePeakBytes != nil
            }
        )
    }

    private static func nonnegativeDelta(_ value: UInt64, from baseline: UInt64) -> UInt64 {
        value >= baseline ? value - baseline : 0
    }

    private static func fixture(options: NetworkLabOptions) -> Fixture {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Benchmarks/ComparativeLab/Apps/GeneratedResources")
        if options.progressiveHeldOut12MP {
            return Fixture(
                url: resources.appendingPathComponent(
                    "h013-heldout-progressive-4000x3000-q78-444.jpg"
                ),
                sha256: heldOut12MPFixtureSHA256
            )
        }
        return Fixture(
            url: resources.appendingPathComponent("w4-progressive-1920x1280.jpg"),
            sha256: baselineFixtureSHA256
        )
    }

    private static func digestHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum ProgressiveResourceMechanismError: Error {
    case invalidConfiguration
    case fixtureDigestMismatch
    case missingPhysicalFootprint
    case targetInvariantFailed
}

private final class ProgressiveResourceNullRenderedCache: RenderedImageCaching,
    @unchecked Sendable
{
    func image(for key: RenderedImageCacheKey) -> DecodedImage? { nil }
    func insert(_ image: DecodedImage, for key: RenderedImageCacheKey, cost: Int) {}
    func remove(_ key: RenderedImageCacheKey) {}
    func removeAll(where predicate: @Sendable (RenderedImageCacheKey) -> Bool) {}
    func removeAllAndReport() -> RenderedImageCacheRemovalSummary {
        RenderedImageCacheRemovalSummary(itemCount: 0, costBytes: 0)
    }
    var currentCost: Int { 0 }
    var count: Int { 0 }
}

private final class ProgressiveResourceFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var body = Data()
    private var chunkByteCount = 32 * 1024

    func configure(body: Data, chunkByteCount: Int) {
        lock.withLock {
            self.body = body
            self.chunkByteCount = max(1, chunkByteCount)
        }
    }

    func snapshot() -> (body: Data, chunkByteCount: Int) {
        lock.withLock { (body, chunkByteCount) }
    }
}

private final class ProgressiveResourceProtocolDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private weak var owner: ProgressiveResourceURLProtocol?
    private var stopped = false

    init(owner: ProgressiveResourceURLProtocol) {
        self.owner = owner
    }

    func cancel() {
        lock.withLock { stopped = true }
    }

    func run(body: Data, chunkByteCount: Int) {
        for start in stride(from: 0, to: body.count, by: chunkByteCount) {
            guard let owner = activeOwner() else { return }
            let end = min(body.count, start + chunkByteCount)
            owner.deliver(body.subdata(in: start..<end))
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard let owner = completeOwner() else { return }
        owner.finishDelivery()
    }

    private func activeOwner() -> ProgressiveResourceURLProtocol? {
        lock.withLock { stopped ? nil : owner }
    }

    private func completeOwner() -> ProgressiveResourceURLProtocol? {
        lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            return owner
        }
    }
}

private final class ProgressiveResourceURLProtocol: URLProtocol {
    private static let state = ProgressiveResourceFixtureState()
    private static let deliveryQueue = DispatchQueue(
        label: "dev.fovea.h013.urlprotocol",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private var delivery: ProgressiveResourceProtocolDelivery?

    static func configure(body: Data, chunkByteCount: Int) {
        state.configure(body: body, chunkByteCount: chunkByteCount)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "progressive-resource.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let fixture = Self.state.snapshot()
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "image/jpeg",
                "Content-Length": String(fixture.body.count),
                "Cache-Control": "no-store",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let delivery = ProgressiveResourceProtocolDelivery(owner: self)
        self.delivery = delivery
        Self.deliveryQueue.async {
            delivery.run(body: fixture.body, chunkByteCount: fixture.chunkByteCount)
        }
    }

    override func stopLoading() {
        delivery?.cancel()
        delivery = nil
    }

    fileprivate func deliver(_ data: Data) {
        client?.urlProtocol(self, didLoad: data)
    }

    fileprivate func finishDelivery() {
        client?.urlProtocolDidFinishLoading(self)
    }
}
