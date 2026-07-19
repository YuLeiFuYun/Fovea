import Foundation
import FoveaCore
import FoveaSystem
import FoveaTesting
import ImageCraftCore
import XCTest

final class FoveaSystemPipelineTests: XCTestCase {
  func testMemoryPressurePurgesRenderedMemoryWithoutRefetch_RES_PT_011() async throws {
    let body = try makePNG(width: 40, height: 20)
    let (pipeline, transport, _, _) = try await makePipeline(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
        body: body
      )
    ])
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/memory-pressure.png")),
      target: TargetPixels(width: 20, height: 20),
      appID: "memory-pressure-tests"
    )
    _ = try await pipeline.image(for: request)
    let monitor = FoveaMemoryPressureMonitor(pipeline: pipeline)

    let removed = await monitor.simulatePressureForTesting()
    let removedAgain = await monitor.simulatePressureForTesting()
    _ = try await pipeline.image(for: request)
    let requestCount = await transport.capturedRequests().count

    XCTAssertEqual(removed, 1)
    XCTAssertEqual(removedAgain, 0)
    XCTAssertEqual(requestCount, 1)
  }

  func testSafeCompositionRootCreatesSinglePersistentGeneration_PIPE_PT_009() async throws {
    let root = try makeTemporaryDirectory("system-pipeline")

    let first = try await FoveaSystemPipeline.open(cacheRoot: root)
    let second = try await FoveaSystemPipeline.open(cacheRoot: root)

    XCTAssertNotNil(UUID(uuidString: first.storageGenerationIdentifier))
    XCTAssertEqual(first.storageGenerationIdentifier, second.storageGenerationIdentifier)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("current-generation.json").path
      )
    )
  }
}
