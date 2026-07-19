import AkashicDisk
import FoveaCore
import FoveaHTTP
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class PipelineConfigurationTests: XCTestCase {
  func testEquivalentConfigurationsHaveStableFingerprintsPipePt001() throws {
    let first = PipelineConfiguration(
      decodeLimits: DecodeLimits(allowedFormats: [.png, .jpeg, .gif])
    )
    let second = PipelineConfiguration(
      decodeLimits: DecodeLimits(allowedFormats: [.gif, .png, .jpeg])
    )
    let encoded = try JSONEncoder().encode(first)
    let decoded = try JSONDecoder().decode(PipelineConfiguration.self, from: encoded)

    XCTAssertEqual(first, second)
    XCTAssertEqual(first.semanticFingerprint, second.semanticFingerprint)
    XCTAssertEqual(first.fullFingerprint, second.fullFingerprint)
    XCTAssertEqual(decoded, first)
    XCTAssertEqual(decoded.transportRetryPolicy, first.transportRetryPolicy)
    XCTAssertEqual(decoded.memoryCostLimit, first.memoryCostLimit)
    XCTAssertEqual(decoded.transportMemoryThreshold, first.transportMemoryThreshold)
    XCTAssertEqual(decoded.maximumConcurrentFetches, first.maximumConcurrentFetches)
    XCTAssertEqual(decoded.maximumConcurrentDecodes, first.maximumConcurrentDecodes)
    XCTAssertEqual(decoded.maximumDecodeWorkingSetBytes, first.maximumDecodeWorkingSetBytes)
    XCTAssertEqual(decoded.maximumQueuedFetches, first.maximumQueuedFetches)
    XCTAssertEqual(decoded.maximumQueuedDecodes, first.maximumQueuedDecodes)
    XCTAssertEqual(decoded.semanticFingerprint, first.semanticFingerprint)
    XCTAssertEqual(decoded.fullFingerprint, first.fullFingerprint)
  }

  func testLegacyConfigurationWithoutWorkingSetBudgetUsesSafeDefault_PIPE_PT_010() throws {
    let configuration = PipelineConfiguration(maximumDecodeWorkingSetBytes: 32 * 1024 * 1024)
    let encoded = try JSONEncoder().encode(configuration)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "maximumDecodeWorkingSetBytes")
    let legacy = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(PipelineConfiguration.self, from: legacy)

    XCTAssertEqual(decoded.maximumDecodeWorkingSetBytes, 192 * 1024 * 1024)
  }

  func testWorkingSetBudgetIsOperationalAndChangesFullFingerprint_PIPE_PT_010() {
    let first = PipelineConfiguration(maximumDecodeWorkingSetBytes: 32 * 1024 * 1024)
    let second = PipelineConfiguration(maximumDecodeWorkingSetBytes: 96 * 1024 * 1024)

    XCTAssertEqual(first.semanticFingerprint, second.semanticFingerprint)
    XCTAssertNotEqual(first.fullFingerprint, second.fullFingerprint)
  }

  func testSemanticChangeChangesBothFingerprintsPipePt002() {
    let first = PipelineConfiguration(
      decodeLimits: DecodeLimits(maximumPixelCount: 10_000_000)
    )
    let second = PipelineConfiguration(
      decodeLimits: DecodeLimits(maximumPixelCount: 20_000_000)
    )

    XCTAssertNotEqual(first.semanticFingerprint, second.semanticFingerprint)
    XCTAssertNotEqual(first.fullFingerprint, second.fullFingerprint)
  }

  func testOperationalChangeOnlyChangesFullFingerprintPipePt002() {
    let first = PipelineConfiguration(
      memoryCostLimit: 16 * 1024 * 1024,
      maximumConcurrentFetches: 2,
      maximumConcurrentDecodes: 1
    )
    let second = PipelineConfiguration(
      memoryCostLimit: 128 * 1024 * 1024,
      maximumConcurrentFetches: 8,
      maximumConcurrentDecodes: 4
    )

    XCTAssertEqual(first.semanticFingerprint, second.semanticFingerprint)
    XCTAssertNotEqual(first.fullFingerprint, second.fullFingerprint)
  }

  func testRetryPolicyIsOperationalButChangesExactTransportIdentityPipePt002() throws {
    let first = PipelineConfiguration(
      transportRetryPolicy: TransportRetryPolicy(maximumAttempts: 1)
    )
    let second = PipelineConfiguration(
      transportRetryPolicy: TransportRetryPolicy(maximumAttempts: 3)
    )
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/config-retry.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    XCTAssertEqual(first.semanticFingerprint, second.semanticFingerprint)
    XCTAssertNotEqual(first.fullFingerprint, second.fullFingerprint)
    XCTAssertNotEqual(
      request.fetchExecutionKey(
        selectedVariant: nil,
        revalidationFingerprint: "unconditional",
        transportPolicyFingerprint: first.transportPolicyFingerprint
      ),
      request.fetchExecutionKey(
        selectedVariant: nil,
        revalidationFingerprint: "unconditional",
        transportPolicyFingerprint: second.transportPolicyFingerprint
      )
    )
  }

  func testNewConfigurationGenerationDoesNotChangeInFlightOldTask_PIPE_PT_003() async throws {
    let body = try makePNG(width: 40, height: 20)
    let root = try makeTemporaryDirectory()
    let oldPipeline = FoveaPipeline(
      configuration: PipelineConfiguration(
        decodeLimits: DecodeLimits(maximumEncodedBytes: body.count + 1)
      ),
      transport: FakeHTTPTransport(stubs: [
        .init(
          statusCode: 200,
          headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
          body: body,
          delayNanoseconds: 40_000_000
        )
      ]),
      encodedStore: try await OriginalEncodedStore.open(
        root: root.appendingPathComponent("old-encoded")
      ),
      recordStore: try await RepresentationRecordStore.open(
        root: root.appendingPathComponent("old-records")
      ),
      decoder: ImageIOImageDecoder()
    )
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/config-generation.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    let oldTask = Task { try await oldPipeline.image(for: request) }
    try await Task.sleep(for: .milliseconds(10))

    let newPipeline = FoveaPipeline(
      configuration: PipelineConfiguration(
        decodeLimits: DecodeLimits(maximumEncodedBytes: 1)
      ),
      transport: FakeHTTPTransport(stubs: [
        .init(
          statusCode: 200,
          headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
          body: body
        )
      ]),
      encodedStore: try await OriginalEncodedStore.open(
        root: root.appendingPathComponent("new-encoded")
      ),
      recordStore: try await RepresentationRecordStore.open(
        root: root.appendingPathComponent("new-records")
      ),
      decoder: ImageIOImageDecoder()
    )
    do {
      _ = try await newPipeline.image(for: request)
      XCTFail("新配置的字节限制必须作用于新 pipeline")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .securityLimit)
      XCTAssertEqual(failure.stage, .probe)
    }

    let oldImage = try await oldTask.value
    XCTAssertEqual(oldImage.pixelWidth, 20)
    XCTAssertEqual(oldPipeline.configuration.decodeLimits.maximumEncodedBytes, body.count + 1)
    XCTAssertEqual(newPipeline.configuration.decodeLimits.maximumEncodedBytes, 1)
  }

  func testPipelineIDsAreIndependentAndConfigurationIsImmutablePipePt004() async throws {
    let root = try makeTemporaryDirectory()
    let encoded = try await OriginalEncodedStore.open(root: root.appendingPathComponent("encoded"))
    let records = try await RepresentationRecordStore.open(
      root: root.appendingPathComponent("records")
    )
    let configuration = PipelineConfiguration(maximumConcurrentFetches: 1)
    let first = FoveaPipeline(
      configuration: configuration,
      transport: FakeHTTPTransport(stubs: []),
      encodedStore: encoded,
      recordStore: records,
      decoder: ImageIOImageDecoder()
    )
    let second = FoveaPipeline(
      configuration: configuration,
      transport: FakeHTTPTransport(stubs: []),
      encodedStore: encoded,
      recordStore: records,
      decoder: ImageIOImageDecoder()
    )

    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(first.configuration, configuration)
    XCTAssertEqual(second.configuration.fullFingerprint, configuration.fullFingerprint)
  }

  func testMemoryLimitCannotDivergeFromPipelineConfigurationPipePt004() async throws {
    let body = try makePNG(width: 40, height: 40)
    let diagnostics = BoundedDiagnosticsSink(capacity: 64)
    let root = try makeTemporaryDirectory()
    let pipeline = FoveaPipeline(
      configuration: PipelineConfiguration(memoryCostLimit: 1),
      transport: FakeHTTPTransport(stubs: [
        .init(
          statusCode: 200,
          headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
          body: body
        )
      ]),
      encodedStore: try await OriginalEncodedStore.open(
        root: root.appendingPathComponent("encoded")
      ),
      recordStore: try await RepresentationRecordStore.open(
        root: root.appendingPathComponent("records")
      ),
      diagnostics: diagnostics,
      decoder: ImageIOImageDecoder()
    )
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/memory-limit.png")),
      target: try TargetPixels(width: 40, height: 40),
      appID: "tests"
    )

    _ = try await pipeline.image(for: request)
    _ = try await pipeline.image(for: request)

    let events = await diagnostics.snapshot().map(\.event)
    XCTAssertEqual(events.filter { $0.kind == .renderedMemoryHit }.count, 0)
    XCTAssertEqual(events.filter { $0.kind == .originalEncodedHit }.count, 1)
    XCTAssertEqual(pipeline.configuration.memoryCostLimit, 1)
  }

  func testSeparatePipelinesDoNotShareInFlightFetchesPipePt008() async throws {
    let body = try makePNG()
    let transport = FakeHTTPTransport(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
        body: body,
        delayNanoseconds: 40_000_000
      ),
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
        body: body,
        delayNanoseconds: 40_000_000
      ),
    ])
    let root = try makeTemporaryDirectory()
    let encoded = try await OriginalEncodedStore.open(root: root.appendingPathComponent("encoded"))
    let records = try await RepresentationRecordStore.open(
      root: root.appendingPathComponent("records")
    )
    let first = FoveaPipeline(
      transport: transport,
      encodedStore: encoded,
      recordStore: records,
      decoder: ImageIOImageDecoder()
    )
    let second = FoveaPipeline(
      transport: transport,
      encodedStore: encoded,
      recordStore: records,
      decoder: ImageIOImageDecoder()
    )
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/pipeline-isolation.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    async let firstImage = first.image(for: request)
    async let secondImage = second.image(for: request)
    _ = try await [firstImage, secondImage]

    let requestCount = await transport.capturedRequests().count
    XCTAssertEqual(requestCount, 2)
  }
}
