import FoveaCore
import ImageCraftCore
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

  func testPipelineDiagnosticsDistinguishFetchDecodeAndMemoryHit() async throws {
    let sink = BoundedDiagnosticsSink(capacity: 64)
    let body = try makePNG(width: 400, height: 300)
    let (pipeline, _, _, _) = try makePipeline(
      stubs: [
        .init(
          statusCode: 200,
          headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
          body: body
        )
      ],
      diagnostics: sink
    )
    let request = ImageRequest.publicImage(
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
