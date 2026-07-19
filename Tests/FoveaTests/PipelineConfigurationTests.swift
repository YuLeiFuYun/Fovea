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
    XCTAssertEqual(decoded.maximumQueuedFetches, first.maximumQueuedFetches)
    XCTAssertEqual(decoded.maximumQueuedDecodes, first.maximumQueuedDecodes)
    XCTAssertEqual(decoded.semanticFingerprint, first.semanticFingerprint)
    XCTAssertEqual(decoded.fullFingerprint, first.fullFingerprint)
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
