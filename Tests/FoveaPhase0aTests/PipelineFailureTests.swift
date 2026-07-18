import FoveaCore
import FoveaTesting
import ImageCraftCore
import XCTest

final class PipelineFailureTests: XCTestCase {
  func testTransportFailureIsNormalizedAndRetryable_ERR_PT_009() async throws {
    let diagnostics = BoundedDiagnosticsSink()
    let (pipeline, _, _, _) = try await makePipeline(stubs: [], diagnostics: diagnostics)
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://private.example.test/image.png?signature=secret")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    do {
      _ = try await pipeline.image(for: request)
      XCTFail("Expected normalized transport failure")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .transport)
      XCTAssertEqual(failure.stage, .transport)
      XCTAssertEqual(failure.disposition, .retryable)
      XCTAssertEqual(failure.reasonCode, "url-session-transport")
      let description = String(describing: failure)
      XCTAssertFalse(description.contains("private.example.test"))
      XCTAssertFalse(description.contains("secret"))
    }

    let events = await diagnostics.snapshot()
    let failureEvent = try XCTUnwrap(events.last?.event)
    XCTAssertEqual(failureEvent.kind, .pipelineFailed)
    XCTAssertEqual(failureEvent.failureCategory, .transport)
    XCTAssertEqual(failureEvent.failureStage, .transport)
    XCTAssertEqual(failureEvent.failureDisposition, .retryable)
  }

  func testMissingContentTypeIsObservableButValidImageStillLoads() async throws {
    let diagnostics = BoundedDiagnosticsSink()
    let body = try makePNG()
    let (pipeline, _, _, _) = try await makePipeline(
      stubs: [.init(statusCode: 200, headers: ["Cache-Control": "no-store"], body: body)],
      diagnostics: diagnostics
    )
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/no-content-type.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    _ = try await pipeline.image(for: request)
    let events = await diagnostics.snapshot()
    XCTAssertTrue(
      events.contains {
        $0.event.kind == .responseAnomaly && $0.event.reason == "missing-content-type"
      }
    )
  }

  func testProbeFailureIsNormalizedAndTerminal() async throws {
    let (pipeline, _, _, _) = try await makePipeline(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png"],
        body: Data("not-an-image".utf8)
      )
    ])
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/broken.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    do {
      _ = try await pipeline.image(for: request)
      XCTFail("Expected normalized probe failure")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .probe)
      XCTAssertEqual(failure.stage, .probe)
      XCTAssertEqual(failure.disposition, .terminal)
      XCTAssertEqual(failure.reasonCode, "unsupported-or-corrupt-image")
    }
  }

  func testHTTPStatusDispositionIsStable() async throws {
    for (statusCode, expectedDisposition) in [
      (404, PipelineFailure.Disposition.terminal),
      (503, PipelineFailure.Disposition.retryable),
    ] {
      let (pipeline, _, _, _) = try await makePipeline(stubs: [
        .init(statusCode: statusCode)
      ])
      let request = try ImageRequest.publicImage(
        url: try XCTUnwrap(URL(string: "https://example.test/status-\(statusCode).png")),
        target: try TargetPixels(width: 20, height: 20),
        appID: "tests"
      )

      do {
        _ = try await pipeline.image(for: request)
        XCTFail("Expected HTTP failure")
      } catch let failure as PipelineFailure {
        XCTAssertEqual(failure.category, .http)
        XCTAssertEqual(failure.stage, .responseValidation)
        XCTAssertEqual(failure.disposition, expectedDisposition)
        XCTAssertEqual(failure.statusCode, statusCode)
      }
    }
  }
}
