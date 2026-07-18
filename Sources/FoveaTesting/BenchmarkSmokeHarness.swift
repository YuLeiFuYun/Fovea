import AkashicDisk
import Foundation
import FoveaCore
import FoveaHTTP
import ImageCraftCore
import ImageCraftImageIO

public enum BenchmarkHarnessError: Error, Equatable, Sendable {
  case invalidFixtureURL
  case outputExceedsTarget
}

public enum BenchmarkSmokeHarness {
  public static func runW1FeedScroll(outputDirectory: URL) async throws -> BenchmarkSmokeArtifact {
    let fixture = try BenchmarkFixtureCatalog.load(named: "feed-2048x1536.jpg")
    let resources = try (0..<64).map { index -> DeterministicImageOrigin.Resource in
      guard let url = URL(string: "https://fovea.invalid/feed/\(index).jpg") else {
        throw BenchmarkHarnessError.invalidFixtureURL
      }
      return DeterministicImageOrigin.Resource(
        url: url,
        body: fixture.data,
        contentType: "image/jpeg",
        etag: "\"feed-\(index)-v1\"",
        delayNanoseconds: 6_000_000
      )
    }
    let origin = DeterministicImageOrigin(resources: resources)
    let diagnostics = BoundedDiagnosticsSink(capacity: 20_000)
    let root = try temporaryRoot(workload: "W1")
    defer { try? FileManager.default.removeItem(at: root) }
    let pipeline = try await makePipeline(root: root, origin: origin, diagnostics: diagnostics)

    let baselineMemory = ProcessMemorySampler.physicalFootprintBytes()
    var peakMemory = baselineMemory
    let runStarted = DispatchTime.now().uptimeNanoseconds
    var trace: [BenchmarkTraceEvent] = []
    var sequence = 0
    var attempted = 0
    var completed = 0
    var cancelled = 0
    var failed = 0
    let targets = try [
      TargetPixels(width: 96, height: 96),
      TargetPixels(width: 360, height: 240),
      TargetPixels(width: 240, height: 360),
    ]

    for (step, offset) in w1ScrollOffsets().enumerated() {
      let footprint = ProcessMemorySampler.physicalFootprintBytes()
      peakMemory = maximum(peakMemory, footprint)
      trace.append(
        BenchmarkTraceEvent(
          sequence: sequence,
          elapsedNanoseconds: elapsed(since: runStarted),
          simulatedTimeMilliseconds: step * 1_000,
          category: "scroll",
          logicalIndex: min(992, Int(offset * 992.0)),
          physicalFootprintBytes: footprint
        )
      )
      sequence += 1

      let firstVisible = min(992, Int(offset * 992.0))
      var pending: [PendingLoad] = []
      pending.reserveCapacity(8)
      for slot in 0..<8 {
        let logicalIndex = min(999, firstVisible + slot)
        let sharedSlot = slot >= 6 ? slot - 6 : slot
        let resourceIndex = ((firstVisible + sharedSlot) * 17) % resources.count
        let target = targets[logicalIndex % targets.count]
        let request = try ImageRequest.publicImage(
          url: resources[resourceIndex].url,
          target: target,
          appID: "benchmark-w1"
        )
        let started = DispatchTime.now().uptimeNanoseconds
        let task = Task { () -> LoadObservation in
          do {
            let image = try await pipeline.image(for: request)
            return LoadObservation(
              outcome: "completed",
              latencyNanoseconds: elapsed(since: started),
              decodedPixelCount: image.pixelWidth * image.pixelHeight,
              physicalFootprintBytes: ProcessMemorySampler.physicalFootprintBytes()
            )
          } catch is CancellationError {
            return LoadObservation(
              outcome: "cancelled",
              latencyNanoseconds: elapsed(since: started),
              decodedPixelCount: nil,
              physicalFootprintBytes: ProcessMemorySampler.physicalFootprintBytes()
            )
          } catch {
            return LoadObservation(
              outcome: "failed",
              latencyNanoseconds: elapsed(since: started),
              decodedPixelCount: nil,
              physicalFootprintBytes: ProcessMemorySampler.physicalFootprintBytes()
            )
          }
        }
        pending.append(
          PendingLoad(
            logicalIndex: logicalIndex,
            resourceID: "feed-\(resourceIndex)",
            target: target,
            shouldCancel: (step * 8 + slot) % 17 == 0,
            task: task
          )
        )
        attempted += 1
      }

      try await Task.sleep(nanoseconds: 2_000_000)
      for load in pending where load.shouldCancel { load.task.cancel() }

      for load in pending {
        let observation = await load.task.value
        switch observation.outcome {
        case "completed": completed += 1
        case "cancelled": cancelled += 1
        default: failed += 1
        }
        peakMemory = maximum(peakMemory, observation.physicalFootprintBytes)
        trace.append(
          BenchmarkTraceEvent(
            sequence: sequence,
            elapsedNanoseconds: elapsed(since: runStarted),
            simulatedTimeMilliseconds: step * 1_000,
            category: "image-load",
            logicalIndex: load.logicalIndex,
            resourceID: load.resourceID,
            target: descriptor(load.target),
            outcome: observation.outcome,
            latencyNanoseconds: observation.latencyNanoseconds,
            decodedPixelCount: observation.decodedPixelCount,
            physicalFootprintBytes: observation.physicalFootprintBytes
          )
        )
        sequence += 1
      }
    }

    let diagnosticEvents = await diagnostics.snapshot()
    let dropped = await diagnostics.droppedEventCount
    let originMetrics = await origin.metrics()
    let summary = summarize(
      attempted: attempted,
      completed: completed,
      cancelled: cancelled,
      failed: failed,
      baselineMemory: baselineMemory,
      peakMemory: peakMemory,
      diagnostics: diagnosticEvents,
      droppedDiagnostics: dropped,
      origin: originMetrics
    )
    let artifact = BenchmarkSmokeArtifact(
      workloadID: "W1-Feed-Scroll-Smoke",
      profileID: "W1-SCROLL-V1-smoke-sampled-1s",
      datasetLogicalItemCount: 1_000,
      uniqueResourceCount: resources.count,
      cacheState: "cold-to-warm-with-reentry",
      sources: [fixture.metadata],
      targets: targets.map(descriptor),
      trace: trace,
      diagnostics: diagnosticEvents,
      summary: summary
    )
    try BenchmarkArtifactWriter.write(artifact, to: outputDirectory)
    return artifact
  }

  public static func runW2DetailHero(outputDirectory: URL) async throws -> BenchmarkSmokeArtifact {
    let fixtures = try [
      BenchmarkFixtureCatalog.load(named: "hero-12mp-4000x3000.jpg"),
      BenchmarkFixtureCatalog.load(named: "hero-24mp-6000x4000.jpg"),
      BenchmarkFixtureCatalog.load(named: "hero-48mp-8000x6000.jpg"),
    ]
    let resources = try fixtures.enumerated().map { index, fixture in
      guard let url = URL(string: "https://fovea.invalid/hero/\(index).jpg") else {
        throw BenchmarkHarnessError.invalidFixtureURL
      }
      return DeterministicImageOrigin.Resource(
        url: url,
        body: fixture.data,
        contentType: "image/jpeg",
        etag: "\"hero-\(index)-v1\"",
        delayNanoseconds: 1_000_000
      )
    }
    let origin = DeterministicImageOrigin(resources: resources)
    let diagnostics = BoundedDiagnosticsSink(capacity: 4_096)
    let root = try temporaryRoot(workload: "W2")
    defer { try? FileManager.default.removeItem(at: root) }
    let pipeline = try await makePipeline(
      root: root,
      origin: origin,
      diagnostics: diagnostics,
      memoryCacheCostLimit: 128 * 1024 * 1024
    )
    let targets = try [
      TargetPixels(width: 390, height: 260),
      TargetPixels(width: 780, height: 520),
      TargetPixels(width: 1_170, height: 780),
    ]

    let baselineMemory = ProcessMemorySampler.physicalFootprintBytes()
    var peakMemory = baselineMemory
    let runStarted = DispatchTime.now().uptimeNanoseconds
    var trace: [BenchmarkTraceEvent] = []
    var sequence = 0
    var completed = 0
    var failed = 0

    for (sourceIndex, resource) in resources.enumerated() {
      for target in targets {
        let request = try ImageRequest.publicImage(
          url: resource.url,
          target: target,
          appID: "benchmark-w2"
        )
        let started = DispatchTime.now().uptimeNanoseconds
        do {
          let image = try await pipeline.image(for: request)
          guard image.pixelWidth <= target.width, image.pixelHeight <= target.height else {
            throw BenchmarkHarnessError.outputExceedsTarget
          }
          completed += 1
          let footprint = ProcessMemorySampler.physicalFootprintBytes()
          peakMemory = maximum(peakMemory, footprint)
          trace.append(
            BenchmarkTraceEvent(
              sequence: sequence,
              elapsedNanoseconds: elapsed(since: runStarted),
              category: "hero-load",
              logicalIndex: sourceIndex,
              resourceID: fixtures[sourceIndex].metadata.resourceID,
              target: descriptor(target),
              outcome: "completed",
              latencyNanoseconds: elapsed(since: started),
              decodedPixelCount: image.pixelWidth * image.pixelHeight,
              physicalFootprintBytes: footprint
            )
          )
        } catch {
          failed += 1
          trace.append(
            BenchmarkTraceEvent(
              sequence: sequence,
              elapsedNanoseconds: elapsed(since: runStarted),
              category: "hero-load",
              logicalIndex: sourceIndex,
              resourceID: fixtures[sourceIndex].metadata.resourceID,
              target: descriptor(target),
              outcome: "failed",
              latencyNanoseconds: elapsed(since: started),
              physicalFootprintBytes: ProcessMemorySampler.physicalFootprintBytes()
            )
          )
          throw error
        }
        sequence += 1
      }
    }

    let diagnosticEvents = await diagnostics.snapshot()
    let dropped = await diagnostics.droppedEventCount
    let originMetrics = await origin.metrics()
    let summary = summarize(
      attempted: resources.count * targets.count,
      completed: completed,
      cancelled: 0,
      failed: failed,
      baselineMemory: baselineMemory,
      peakMemory: peakMemory,
      diagnostics: diagnosticEvents,
      droppedDiagnostics: dropped,
      origin: originMetrics
    )
    let artifact = BenchmarkSmokeArtifact(
      workloadID: "W2-Detail-Hero-Smoke",
      profileID: "W2-TARGET-DECODE-V1-smoke",
      datasetLogicalItemCount: fixtures.count,
      uniqueResourceCount: resources.count,
      cacheState: "cold-network-then-original-encoded",
      sources: fixtures.map(\.metadata),
      targets: targets.map(descriptor),
      trace: trace,
      diagnostics: diagnosticEvents,
      summary: summary
    )
    try BenchmarkArtifactWriter.write(artifact, to: outputDirectory)
    return artifact
  }

  private static func makePipeline(
    root: URL,
    origin: DeterministicImageOrigin,
    diagnostics: BoundedDiagnosticsSink,
    memoryCacheCostLimit: Int = 64 * 1024 * 1024
  ) async throws -> FoveaPipeline {
    let encoded = try await OriginalEncodedStore.open(
      root: root.appendingPathComponent("encoded", isDirectory: true),
      softLimitBytes: 64 * 1024 * 1024
    )
    let records = try await RepresentationRecordStore.open(
      root: root.appendingPathComponent("records", isDirectory: true)
    )
    return FoveaPipeline(
      transport: origin,
      encodedStore: encoded,
      recordStore: records,
      memoryCacheCostLimit: memoryCacheCostLimit,
      diagnostics: diagnostics,
      decoder: ImageIOImageDecoder()
    )
  }

  private static func summarize(
    attempted: Int,
    completed: Int,
    cancelled: Int,
    failed: Int,
    baselineMemory: UInt64?,
    peakMemory: UInt64?,
    diagnostics: [RecordedDiagnosticEvent],
    droppedDiagnostics: Int,
    origin: DeterministicImageOrigin.Metrics
  ) -> BenchmarkSummary {
    let events = diagnostics.map(\.event)
    let decodedPixels =
      events
      .filter { $0.kind == .decodeCompleted }
      .compactMap(\.outputPixelCount)
      .reduce(0, +)
    let sourcePixels =
      events
      .filter { $0.kind == .decodeCompleted }
      .compactMap(\.sourcePixelCount)
      .reduce(0, +)
    return BenchmarkSummary(
      attemptedLoads: attempted,
      completedLoads: completed,
      cancelledLoads: cancelled,
      failedLoads: failed,
      decodedMegapixels: Double(decodedPixels) / 1_000_000.0,
      sourceMegapixelsObserved: Double(sourcePixels) / 1_000_000.0,
      baselinePhysicalFootprintBytes: baselineMemory,
      peakPhysicalFootprintBytes: peakMemory,
      physicalFootprintDeltaBytes: memoryDelta(baseline: baselineMemory, peak: peakMemory),
      networkRequestCount: origin.requestCount,
      networkBytes: origin.deliveredBytes,
      duplicateRequestCount: origin.duplicateRequestCount,
      singleFlightJoinCount: events.filter { $0.kind == .fetchJoined }.count,
      fetchCancellationCount: events.filter { $0.kind == .fetchCancelled }.count,
      originalEncodedHitCount: events.filter { $0.kind == .originalEncodedHit }.count,
      renderedMemoryHitCount: events.filter { $0.kind == .renderedMemoryHit }.count,
      droppedDiagnosticEventCount: droppedDiagnostics
    )
  }

  private static func w1ScrollOffsets() -> [Double] {
    var offsets: [Double] = []
    var offset = 0.0
    for second in 0...40 {
      switch second {
      case 10...11, 22...23, 32...33:
        offset -= 0.08
      case 16...17, 28:
        break
      case 38:
        offset = 0
      case 39:
        offset = 0.02
      case 40:
        offset = 0.08
      default:
        offset += 0.035
      }
      offset = min(1, max(0, offset))
      offsets.append(offset)
    }
    return offsets
  }

  private static func descriptor(_ target: TargetPixels) -> BenchmarkTargetDescriptor {
    BenchmarkTargetDescriptor(width: target.width, height: target.height)
  }

  private static func temporaryRoot(workload: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("FoveaBenchmark", isDirectory: true)
      .appendingPathComponent("\(workload)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private static func elapsed(since start: UInt64) -> UInt64 {
    DispatchTime.now().uptimeNanoseconds &- start
  }

  private static func maximum(_ lhs: UInt64?, _ rhs: UInt64?) -> UInt64? {
    switch (lhs, rhs) {
    case (let lhs?, let rhs?): max(lhs, rhs)
    case (let lhs?, nil): lhs
    case (nil, let rhs?): rhs
    case (nil, nil): nil
    }
  }

  private static func memoryDelta(baseline: UInt64?, peak: UInt64?) -> Int64? {
    guard let baseline, let peak else { return nil }
    if peak >= baseline {
      return Int64(min(peak - baseline, UInt64(Int64.max)))
    }
    return -Int64(min(baseline - peak, UInt64(Int64.max)))
  }
}

private struct PendingLoad: Sendable {
  let logicalIndex: Int
  let resourceID: String
  let target: TargetPixels
  let shouldCancel: Bool
  let task: Task<LoadObservation, Never>
}

private struct LoadObservation: Sendable {
  let outcome: String
  let latencyNanoseconds: UInt64
  let decodedPixelCount: Int?
  let physicalFootprintBytes: UInt64?
}
