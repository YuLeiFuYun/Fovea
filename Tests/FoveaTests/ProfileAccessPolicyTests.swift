import AkashicCore
import Foundation
import FoveaCore
import FoveaHTTP
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class ProfileAccessPolicyTests: XCTestCase {
  func testDeniedProfileFailsBeforeCacheOrNetwork_AUTH_PT_014() async throws {
    let encoded = AccessSpyEncodedStore()
    let records = AccessSpyRecordStore()
    let transport = AccessSpyTransport()
    let allowedScope = ProfileAccessScope(
      namespace: SecurityNamespaceID("account-a"),
      authorizationContext: AuthorizationContextID("reader")
    )
    let pipeline = FoveaPipeline(
      transport: transport,
      encodedStore: encoded,
      recordStore: records,
      profileAccessPolicy: .allowOnly([allowedScope]),
      decoder: AccessRejectingDecoder()
    )
    let denied = try ImageRequest(
      url: try XCTUnwrap(URL(string: "https://example.test/private.png")),
      target: try TargetPixels(width: 20, height: 20),
      namespace: SecurityNamespaceID("account-a"),
      authorizationContext: AuthorizationContextID("admin")
    )

    do {
      _ = try await pipeline.image(for: denied)
      XCTFail("未授权 profile 必须在访问缓存或网络前失败")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .authorization)
      XCTAssertEqual(failure.stage, .requestValidation)
      XCTAssertEqual(failure.reasonCode, "profile-access-denied")
    }

    let encodedOperations = await encoded.operationCount
    let recordOperations = await records.operationCount
    let executions = await transport.executionCount
    XCTAssertEqual(encodedOperations, 0)
    XCTAssertEqual(recordOperations, 0)
    XCTAssertEqual(executions, 0)
  }

  func testPublicOnlyPolicyRejectsPrivateProfileBeforeTransport_AUTH_PT_014() async throws {
    let transport = AccessSpyTransport()
    let pipeline = FoveaPipeline(
      transport: transport,
      encodedStore: AccessSpyEncodedStore(),
      recordStore: AccessSpyRecordStore(),
      profileAccessPolicy: .publicOnly,
      decoder: AccessRejectingDecoder()
    )
    let request = try ImageRequest(
      url: try XCTUnwrap(URL(string: "https://example.test/private.png")),
      target: try TargetPixels(width: 20, height: 20),
      namespace: SecurityNamespaceID("account-a"),
      authorizationContext: AuthorizationContextID("reader")
    )

    do {
      _ = try await pipeline.image(for: request)
      XCTFail("public-only policy 必须拒绝私有 profile")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .authorization)
      XCTAssertEqual(failure.stage, .requestValidation)
      XCTAssertEqual(failure.reasonCode, "profile-access-denied")
    }
    let executions = await transport.executionCount
    XCTAssertEqual(executions, 0)
  }

  func testPublicOnlyPolicyRejectsPrivateNamespaceWithPublicContext_AUTH_PT_014()
    async throws
  {
    let transport = AccessSpyTransport()
    let pipeline = FoveaPipeline(
      transport: transport,
      encodedStore: AccessSpyEncodedStore(),
      recordStore: AccessSpyRecordStore(),
      profileAccessPolicy: .publicOnly,
      decoder: AccessRejectingDecoder()
    )
    let request = try ImageRequest(
      url: try XCTUnwrap(URL(string: "https://example.test/signed-private.png")),
      target: try TargetPixels(width: 20, height: 20),
      namespace: SecurityNamespaceID("account-a"),
      authorizationContext: .public
    )

    do {
      _ = try await pipeline.image(for: request)
      XCTFail("public-only policy 不得接受私有 namespace")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.reasonCode, "profile-access-denied")
    }
    let executions = await transport.executionCount
    XCTAssertEqual(executions, 0)
  }

  func testAllowlistedProfileReachesTransport_AUTH_PT_014() async throws {
    let body = try makePNG()
    let encoded = AccessSpyEncodedStore()
    let records = AccessSpyRecordStore()
    let transport = AccessSpyTransport(body: body)
    let scope = ProfileAccessScope(
      namespace: SecurityNamespaceID("account-a"),
      authorizationContext: AuthorizationContextID("reader")
    )
    let pipeline = FoveaPipeline(
      transport: transport,
      encodedStore: encoded,
      recordStore: records,
      profileAccessPolicy: .allowOnly([scope]),
      decoder: ImageIOImageDecoder()
    )
    let allowed = try ImageRequest(
      url: try XCTUnwrap(URL(string: "https://example.test/private.png")),
      target: try TargetPixels(width: 20, height: 20),
      namespace: scope.namespace,
      authorizationContext: scope.authorizationContext
    )

    _ = try await pipeline.image(for: allowed)

    let executions = await transport.executionCount
    XCTAssertEqual(executions, 1)
  }
}

private actor AccessSpyEncodedStore: OriginalEncodedStoring {
  private(set) var operationCount = 0

  func read(contentID: String, namespace: String) throws -> Data {
    operationCount += 1
    throw AkashicError.notFound
  }

  func commit(data: Data, contentID: String, namespace: String) throws -> StoredBlob {
    operationCount += 1
    return StoredBlob(physicalID: PhysicalBlobID(), byteCount: data.count, wasCreated: true)
  }

  func physicalID(contentID: String, namespace: String) -> PhysicalBlobID? {
    operationCount += 1
    return nil
  }

  func remove(contentID: String, namespace: String) {
    operationCount += 1
  }

  func removeAll(namespace: String) {
    operationCount += 1
  }
}

private actor AccessSpyRecordStore: RepresentationRecordStoring {
  private(set) var operationCount = 0

  func records(
    for baseKeyDigest: String,
    namespace: String,
    namespaceGeneration: UInt64
  ) -> [RepresentationRecord] {
    operationCount += 1
    return []
  }

  func put(_ record: RepresentationRecord) {
    operationCount += 1
  }

  func containsReference(
    to contentID: String,
    namespace: String,
    excludingVariantDigest: String?
  ) -> Bool {
    operationCount += 1
    return false
  }

  func remove(
    _ variantDigest: String,
    namespace: String,
    namespaceGeneration: UInt64
  ) {
    operationCount += 1
  }

  func removeAll(namespace: String) {
    operationCount += 1
  }
}

private actor AccessSpyTransport: HTTPTransporting {
  nonisolated let reusePolicy = TransportReusePolicy.reusable(
    contextIdentifier: "tests-profile-access-v1"
  )
  private let body: Data
  private(set) var executionCount = 0

  init(body: Data = Data()) {
    self.body = body
  }

  func execute(_ request: TransportRequest) throws -> TransportResponse {
    executionCount += 1
    return TransportResponse(
      head: TransportResponseHead(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
        url: request.request.url
      ),
      body: body,
      digestHex: ContentID(data: body).digestHex,
      metrics: TransportMetrics(receivedBytes: body.count, spilledToDisk: false)
    )
  }
}

private struct AccessRejectingDecoder: ImageDecoding {
  func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
    throw ImageCraftError.decodeFailed
  }

  func decode(
    data: Data,
    probe: ImageProbe,
    request: ImageDecodeRequest,
    limits: DecodeLimits
  ) throws -> DecodedImage {
    throw ImageCraftError.decodeFailed
  }
}
