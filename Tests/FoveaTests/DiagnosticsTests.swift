import AkashicCore
import AkashicDisk
import FoveaCore
import FoveaHTTP
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class DiagnosticsTests: XCTestCase {
  func testBoundedDiagnosticsDropsOldestEvent() async {
    let sink = BoundedDiagnosticsSink(capacity: 2)
    await sink.record(DiagnosticEvent(kind: .fetchStarted, keyDigest: "first"))
    await sink.record(DiagnosticEvent(kind: .fetchCompleted, keyDigest: "second"))
    await sink.record(DiagnosticEvent(kind: .decodeCompleted, keyDigest: "third"))

    let events = await sink.snapshot()
    let dropped = await sink.droppedEventCount
    XCTAssertEqual(events.map(\.event.keyDigest), ["second", "third"])
    XCTAssertEqual(dropped, 1)
  }

  func testPipelineDiagnosticsUseEphemeralCorrelationIDs_DIAG_PT_002() async throws {
    let body = try makePNG()
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/private-correlation.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    let firstSink = BoundedDiagnosticsSink()
    let secondSink = BoundedDiagnosticsSink()
    let first = try await makePipeline(
      stubs: [
        .init(
          statusCode: 200,
          headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
          body: body
        )
      ],
      diagnostics: firstSink
    ).0
    let second = try await makePipeline(
      stubs: [
        .init(
          statusCode: 200,
          headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
          body: body
        )
      ],
      diagnostics: secondSink
    ).0

    _ = try await first.image(for: request)
    _ = try await second.image(for: request)

    let firstIDs = await firstSink.snapshot().compactMap(\.event.keyDigest)
    let secondIDs = await secondSink.snapshot().compactMap(\.event.keyDigest)
    XCTAssertFalse(firstIDs.isEmpty)
    XCTAssertFalse(secondIDs.isEmpty)
    XCTAssertFalse(firstIDs.contains(request.fetchVariantKey.digestHex))
    XCTAssertFalse(firstIDs.contains(request.fetchExecutionKey.digestHex))
    XCTAssertNotEqual(Set(firstIDs), Set(secondIDs))
  }

  func testFailedCorruptRecordRemovalIsObservable() async throws {
    let body = try makePNG()
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/removal-diagnostics.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    let record = makeRepresentationRecord(
      namespace: request.namespace.value,
      baseKeyDigest: request.fetchBaseKey.digestHex,
      variantKeyDigest: request.fetchVariantKey.digestHex,
      expiresAt: Date().addingTimeInterval(3_600),
      contentID: ContentID(data: body).description,
      payloadLength: body.count
    )
    let diagnostics = BoundedDiagnosticsSink(capacity: 64)
    let pipeline = FoveaPipeline(
      transport: FakeHTTPTransport(stubs: [
        .init(
          statusCode: 200,
          headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
          body: body
        )
      ]),
      encodedStore: FailingReadEncodedStore(),
      recordStore: RemovalFailingRecordStore(record: record),
      diagnostics: diagnostics,
      decoder: ImageIOImageDecoder()
    )

    _ = try await pipeline.image(for: request)

    let events = await diagnostics.snapshot().map(\.event)
    XCTAssertTrue(
      events.contains {
        $0.kind == .cacheReadFailed && $0.reason == "original-encoded-read"
      }
    )
    XCTAssertTrue(
      events.contains {
        $0.kind == .cacheWriteFailed && $0.reason == "record-removal-failed"
      }
    )
  }

  func testSlowExternalSinkCannotDelayImageDelivery_DIAG_PT_003() async throws {
    let body = try makePNG()
    let root = try makeTemporaryDirectory()
    let pipeline = FoveaPipeline(
      transport: FakeHTTPTransport(stubs: [
        .init(
          statusCode: 200,
          headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
          body: body
        )
      ]),
      encodedStore: try await OriginalEncodedStore.open(
        root: root.appendingPathComponent("encoded")),
      recordStore: try await RepresentationRecordStore.open(
        root: root.appendingPathComponent("records")),
      diagnostics: SlowDiagnosticsSink(),
      decoder: ImageIOImageDecoder()
    )
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/slow-diagnostics.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    let clock = ContinuousClock()
    let started = clock.now
    _ = try await pipeline.image(for: request)
    let elapsed = started.duration(to: clock.now)
    XCTAssertLessThan(elapsed, .milliseconds(350))
  }

  func testExternalRelayReportsBoundedDrops_DIAG_PT_004() async throws {
    let downstream = CapturingSlowDiagnosticsSink(delay: .milliseconds(50))
    let relay = BufferedDiagnosticsRelay(downstream: downstream, capacity: 1)
    for index in 0..<20 {
      await relay.record(DiagnosticEvent(kind: .fetchQueued, byteCount: index))
    }
    let dropped = await relay.droppedEventCount
    XCTAssertGreaterThan(dropped, 0)

    try await Task.sleep(for: .milliseconds(120))
    await relay.record(DiagnosticEvent(kind: .fetchCompleted))
    try await Task.sleep(for: .milliseconds(180))

    let events = await downstream.events
    let summary = try XCTUnwrap(events.first { $0.kind == .diagnosticsDropped })
    XCTAssertGreaterThan(summary.byteCount ?? 0, 0)
  }

  func testPipelineDiagnosticsDistinguishFetchDecodeAndMemoryHit() async throws {
    let sink = BoundedDiagnosticsSink(capacity: 64)
    let body = try makePNG(width: 400, height: 300)
    let (pipeline, _, _, _) = try await makePipeline(
      stubs: [
        .init(
          statusCode: 200,
          headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
          body: body
        )
      ],
      diagnostics: sink
    )
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.com/diagnostics.png")),
      target: try TargetPixels(width: 100, height: 75),
      appID: "tests"
    )

    _ = try await pipeline.image(for: request)
    _ = try await pipeline.image(for: request)

    let events = await sink.snapshot().map(\.event)
    XCTAssertEqual(events.filter { $0.kind == .fetchStarted }.count, 1)
    XCTAssertEqual(events.filter { $0.kind == .fetchCompleted }.count, 1)
    XCTAssertEqual(events.filter { $0.kind == .decodeCompleted }.count, 1)
    XCTAssertEqual(events.filter { $0.kind == .originalEncodedHit }.count, 1)
    XCTAssertEqual(events.filter { $0.kind == .renderedMemoryHit }.count, 1)

    let decode = try XCTUnwrap(events.first { $0.kind == .decodeCompleted })
    XCTAssertEqual(decode.sourcePixelCount, 120_000)
    XCTAssertEqual(decode.outputPixelCount, 7_500)
    XCTAssertEqual(decode.targetWidth, 100)
    XCTAssertEqual(decode.targetHeight, 75)
  }
}

private actor SlowDiagnosticsSink: DiagnosticsSink {
  func record(_ event: DiagnosticEvent) async {
    try? await Task.sleep(for: .milliseconds(500))
  }
}

private actor CapturingSlowDiagnosticsSink: DiagnosticsSink {
  private let delay: Duration
  private(set) var events: [DiagnosticEvent] = []

  init(delay: Duration) {
    self.delay = delay
  }

  func record(_ event: DiagnosticEvent) async {
    try? await Task.sleep(for: delay)
    events.append(event)
  }
}

private actor FailingReadEncodedStore: OriginalEncodedStoring {
  func read(contentID: String, namespace: String) async throws -> Data {
    throw AkashicError.integrityMismatch
  }

  func commit(data: Data, contentID: String, namespace: String) async throws -> StoredBlob {
    throw AkashicError.storageUnavailable
  }

  func physicalID(contentID: String, namespace: String) async -> PhysicalBlobID? { nil }
  func remove(contentID: String, namespace: String) async throws {}
  func removeAll(namespace: String) async throws {}
}

private actor RemovalFailingRecordStore: RepresentationRecordStoring {
  private let record: RepresentationRecord

  init(record: RepresentationRecord) {
    self.record = record
  }

  func records(
    for baseKeyDigest: String,
    namespace: String,
    namespaceGeneration: UInt64
  ) async -> [RepresentationRecord] {
    guard record.baseKeyDigest == baseKeyDigest,
      record.securityNamespaceFingerprint == StorageNamespaceFingerprint(namespace: namespace),
      record.namespaceGeneration == namespaceGeneration
    else { return [] }
    return [record]
  }

  func put(_ record: RepresentationRecord) async throws {}

  func containsReference(
    to contentID: String,
    namespace: String,
    excludingVariantDigest: String?
  ) async -> Bool {
    true
  }

  func remove(
    _ variantDigest: String,
    namespace: String,
    namespaceGeneration: UInt64
  ) async throws {
    throw AkashicError.storageUnavailable
  }

  func removeAll(namespace: String) async throws {}
}
