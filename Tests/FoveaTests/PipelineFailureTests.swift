import AkashicDisk
import FoveaCore
import FoveaHTTP
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
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
    }

    let events = await diagnostics.snapshot().map(\.event)
    let failed = try XCTUnwrap(events.first { $0.kind == .pipelineFailed })
    XCTAssertEqual(failed.failureCategory, .transport)
    XCTAssertEqual(failed.failureStage, .transport)
    XCTAssertEqual(failed.failureDisposition, .retryable)
    XCTAssertEqual(failed.reason, "url-session-transport")
    XCTAssertFalse(events.contains { $0.reason?.contains("signature=secret") == true })
  }

  func testMissingContentTypeIsObservableButValidImageStillLoads() async throws {
    let diagnostics = BoundedDiagnosticsSink()
    let (pipeline, _, _, _) = try await makePipeline(
      stubs: [.init(statusCode: 200, headers: ["Cache-Control": "no-store"], body: try makePNG())],
      diagnostics: diagnostics
    )
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/missing-content-type.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    _ = try await pipeline.image(for: request)

    let events = await diagnostics.snapshot().map(\.event)
    XCTAssertTrue(
      events.contains {
        $0.kind == .responseAnomaly && $0.reason == "missing-content-type"
      }
    )
  }

  func testProbeFailureIsNormalizedAndTerminal() async throws {
    let (pipeline, _, _, _) = try await makePipeline(
      stubs: [
        .init(
          statusCode: 200,
          headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
          body: Data("not-an-image".utf8)
        )
      ]
    )
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/corrupt.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    do {
      _ = try await pipeline.image(for: request)
      XCTFail("Expected structured probe failure")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .securityLimit)
      XCTAssertEqual(failure.stage, .probe)
      XCTAssertEqual(failure.disposition, .terminal)
      XCTAssertEqual(failure.reasonCode, "unsupported-image-format")
    }
  }

  func testHTTPStatusDispositionIsStable() async throws {
    let (pipeline, _, _, _) = try await makePipeline(
      stubs: [.init(statusCode: 503, headers: [:], body: Data())]
    )
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/unavailable.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    do {
      _ = try await pipeline.image(for: request)
      XCTFail("Expected structured HTTP failure")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .http)
      XCTAssertEqual(failure.stage, .responseValidation)
      XCTAssertEqual(failure.disposition, .retryable)
      XCTAssertEqual(failure.reasonCode, "unsupported-http-status")
      XCTAssertEqual(failure.statusCode, 503)
    }
  }
}

extension PipelineFailureTests {
  func testMetadataSecurityFailurePublishesNoReusableStateSecCase004() async throws {
    let body = try makePNGWithOversizedTextMetadata(payloadBytes: 1_024)
    let root = try makeTemporaryDirectory()
    let transport = FakeHTTPTransport(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
        body: body
      )
    ])
    let encoded = try await OriginalEncodedStore.open(root: root.appendingPathComponent("encoded"))
    let records = try await RepresentationRecordStore.open(
      root: root.appendingPathComponent("records")
    )
    let pipeline = FoveaPipeline(
      configuration: PipelineConfiguration(
        decodeLimits: DecodeLimits(maximumMetadataBytes: 128)
      ),
      transport: transport,
      encodedStore: encoded,
      recordStore: records,
      decoder: ImageIOImageDecoder()
    )
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/metadata-limit.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    do {
      _ = try await pipeline.image(for: request)
      XCTFail("Oversized metadata must be rejected")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .securityLimit)
      XCTAssertEqual(failure.stage, .probe)
      XCTAssertEqual(failure.reasonCode, "metadata-limit-exceeded")
    }

    let candidates = await records.records(
      for: request.fetchBaseKey.digestHex,
      namespace: request.namespace.value,
      namespaceGeneration: 0
    )
    let physicalID = await encoded.physicalID(
      contentID: ContentID(data: body).description,
      namespace: request.namespace.value
    )
    XCTAssertTrue(candidates.isEmpty)
    XCTAssertNil(physicalID)
  }
}

private func makePNGWithOversizedTextMetadata(payloadBytes: Int) throws -> Data {
  var data = try makePNG(width: 10, height: 10)
  let iendSignature = Data([0, 0, 0, 0, 73, 69, 78, 68])
  guard let iend = data.range(of: iendSignature)?.lowerBound else {
    throw NSError(domain: "FoveaTests", code: 5)
  }
  var chunk = Data()
  let length = UInt32(payloadBytes).bigEndian
  withUnsafeBytes(of: length) { chunk.append(contentsOf: $0) }
  chunk.append(contentsOf: Data("tEXt".utf8))
  chunk.append(Data(repeating: 65, count: payloadBytes))
  chunk.append(Data(repeating: 0, count: 4))
  data.insert(contentsOf: chunk, at: iend)
  return data
}
