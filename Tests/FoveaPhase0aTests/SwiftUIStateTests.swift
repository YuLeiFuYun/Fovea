import FoveaCore
import FoveaSwiftUI
import FoveaTesting
import ImageCraftCore
import XCTest

@MainActor
final class SwiftUIStateTests: XCTestCase {
  func testLateResultCannotOverwriteNewIdentity_UI_PT_001() async throws {
    let body = try makePNG(width: 100, height: 50)
    let (pipeline, _, _, _) = try makePipeline(stubs: [
      .init(
        statusCode: 200, headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
        body: body, delayNanoseconds: 100_000_000),
      .init(
        statusCode: 200, headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
        body: body),
    ])
    let model = FoveaImageModel()
    let first = ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.com/first.png")),
      target: try TargetPixels(width: 10, height: 10),
      appID: "tests"
    )
    let second = ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.com/second.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    let firstTask = Task { await model.load(request: first, pipeline: pipeline) }
    try await Task.sleep(for: .milliseconds(10))
    await model.load(request: second, pipeline: pipeline)
    _ = await firstTask.result

    guard case .success(let image) = model.phase else {
      return XCTFail("Expected final image")
    }
    XCTAssertEqual(image.pixelWidth, 20)
    XCTAssertEqual(image.pixelHeight, 10)
  }
}
