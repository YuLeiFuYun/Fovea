import AkashicCore
import Foundation
import FoveaCore
import FoveaHTTP
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class CacheRefreshTransactionTests: XCTestCase {
  func testCancellationAfterSameVariantRefreshRestoresPreviousRecord_CACHE_PT_039() async throws {
    let request = try ImageRequest.publicImage(
      url: XCTUnwrap(URL(string: "https://example.test/cancelled-refresh.png")),
      target: TargetPixels(width: 20, height: 20),
      appID: "refresh-cancellation"
    )
    let body = try makePNG(width: 20, height: 20)
    let contentID = ContentID(data: body)
    let old = RepresentationRecord(
      securityNamespace: request.namespace.value,
      namespaceGeneration: 0,
      baseKeyDigest: request.fetchBaseKey.digestHex,
      variantKeyDigest: request.fetchVariantKey.digestHex,
      statusCode: 200,
      requestTime: Date(timeIntervalSince1970: 1),
      responseTime: Date(timeIntervalSince1970: 2),
      responseDate: Date(timeIntervalSince1970: 2),
      expiresAt: Date(timeIntervalSince1970: 3),
      etag: "old",
      lastModified: nil,
      disposition: .reusable,
      contentID: contentID.description,
      payloadLength: body.count,
      contentType: "image/png"
    )
    let records = GatedRefreshRecordStore(initial: old)
    await records.gateNextPut()
    let pipeline = FoveaPipeline(
      transport: RefreshNotModifiedTransport(),
      encodedStore: RefreshEncodedStore(data: body, contentID: contentID.description),
      recordStore: records,
      decoder: ImageIOImageDecoder()
    )

    let refresh = Task { try await pipeline.image(for: request) }
    await records.waitUntilGatedPut()
    refresh.cancel()
    await records.releaseGatedPut()

    do {
      _ = try await refresh.value
      XCTFail("刷新取消必须向调用方传播")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.disposition, .cancelled)
    }
    let persisted = await records.record(for: old.variantKeyDigest)
    XCTAssertEqual(persisted, old)
  }
}

private actor GatedRefreshRecordStore: RepresentationRecordStoring {
  private var stored: [String: RepresentationRecord]
  private var shouldGateNextPut = false
  private var gatedPutReached = false
  private var putWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  init(initial: RepresentationRecord) {
    self.stored = [initial.variantKeyDigest: initial]
  }

  func gateNextPut() {
    shouldGateNextPut = true
  }

  func records(
    for baseKeyDigest: String,
    namespace: String,
    namespaceGeneration: UInt64
  ) -> [RepresentationRecord] {
    stored.values.filter {
      $0.baseKeyDigest == baseKeyDigest && $0.namespaceGeneration == namespaceGeneration
    }
  }

  func put(_ record: RepresentationRecord) async throws {
    stored[record.variantKeyDigest] = record
    guard shouldGateNextPut else { return }
    shouldGateNextPut = false
    gatedPutReached = true
    for waiter in putWaiters { waiter.resume() }
    putWaiters.removeAll()
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func containsReference(
    to contentID: String,
    namespace: String,
    excludingVariantDigest: String?
  ) -> Bool {
    stored.values.contains {
      $0.contentID == contentID && $0.variantKeyDigest != excludingVariantDigest
    }
  }

  func remove(
    _ variantDigest: String,
    namespace: String,
    namespaceGeneration: UInt64
  ) {
    stored.removeValue(forKey: variantDigest)
  }

  func removeAll(namespace: String) {
    stored.removeAll()
  }

  func waitUntilGatedPut() async {
    if gatedPutReached { return }
    await withCheckedContinuation { putWaiters.append($0) }
  }

  func releaseGatedPut() {
    for waiter in releaseWaiters { waiter.resume() }
    releaseWaiters.removeAll()
  }

  func record(for variantDigest: String) -> RepresentationRecord? {
    stored[variantDigest]
  }
}

private actor RefreshEncodedStore: OriginalEncodedStoring {
  private let data: Data
  private let contentID: String

  init(data: Data, contentID: String) {
    self.data = data
    self.contentID = contentID
  }

  func read(contentID: String, namespace: String) throws -> Data {
    guard contentID == self.contentID else { throw AkashicError.notFound }
    return data
  }

  func commit(data: Data, contentID: String, namespace: String) throws -> StoredBlob {
    StoredBlob(physicalID: PhysicalBlobID(), byteCount: data.count, wasCreated: false)
  }

  func physicalID(contentID: String, namespace: String) -> PhysicalBlobID? { nil }
  func remove(contentID: String, namespace: String) {}
  func removeAll(namespace: String) {}
}

private actor RefreshNotModifiedTransport: HTTPTransporting {
  nonisolated let reusePolicy = TransportReusePolicy.reusable(
    contextIdentifier: "refresh-transaction-test"
  )

  func execute(_ request: TransportRequest) async throws -> TransportResponse {
    let body = Data()
    return TransportResponse(
      head: TransportResponseHead(
        statusCode: 304,
        headers: ["Cache-Control": "max-age=3600", "ETag": "new"],
        url: request.request.url
      ),
      body: body,
      digestHex: ContentID(data: body).digestHex,
      metrics: TransportMetrics(receivedBytes: 0, spilledToDisk: false)
    )
  }
}
