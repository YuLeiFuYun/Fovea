import AkashicCore
import AkashicDisk
import CryptoKit
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaTesting
import ImageCraftCore
import XCTest

final class StagingAndStorageTests: XCTestCase {
  func testAccumulatorSpillsAndPreservesDigest() throws {
    let directory = try makeTemporaryDirectory()
    let accumulator = try BoundedStagingAccumulator(
      maximumBytes: 64,
      memoryThreshold: 4,
      stagingDirectory: directory
    )
    try accumulator.append(Data("hello".utf8))
    try accumulator.append(Data(" world".utf8))
    let result = try accumulator.finalize()
    XCTAssertEqual(result.data, Data("hello world".utf8))
    XCTAssertTrue(result.metrics.spilledToDisk)
    let expected = SHA256.hash(data: result.data).map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(result.digestHex, expected)
  }

  func testAccumulatorRejectsHardLimit() throws {
    let accumulator = try BoundedStagingAccumulator(
      maximumBytes: 4,
      memoryThreshold: 4,
      stagingDirectory: try makeTemporaryDirectory()
    )
    XCTAssertThrowsError(try accumulator.append(Data("12345".utf8))) { error in
      XCTAssertEqual(error as? TransportError, .bodyTooLarge)
    }
  }

  func testStoreRejectsMismatchedContentID() async throws {
    let store = try OriginalEncodedStore(root: try makeTemporaryDirectory())
    let data = Data("actual".utf8)
    do {
      _ = try await store.commit(
        data: data,
        contentID: ContentID(data: Data("other".utf8)).description,
        namespace: "public:tests"
      )
      XCTFail("Expected integrity mismatch")
    } catch let error as AkashicError {
      XCTAssertEqual(error, .integrityMismatch)
    }
  }

  func testSoftCapEvictsOldestWithoutBlockingNewBlob_GC_PT_011() async throws {
    let store = try OriginalEncodedStore(root: try makeTemporaryDirectory(), softLimitBytes: 8)
    let first = Data("123456".utf8)
    let second = Data("abcdef".utf8)
    let firstID = ContentID(data: first).description
    let secondID = ContentID(data: second).description
    _ = try await store.commit(data: first, contentID: firstID, namespace: "public:tests")
    try await Task.sleep(for: .milliseconds(5))
    _ = try await store.commit(data: second, contentID: secondID, namespace: "public:tests")

    do {
      _ = try await store.read(contentID: firstID, namespace: "public:tests")
      XCTFail("Oldest blob should have been evicted")
    } catch let error as AkashicError {
      XCTAssertEqual(error, .notFound)
    }
    let loaded = try await store.read(contentID: secondID, namespace: "public:tests")
    XCTAssertEqual(loaded, second)
  }

  func testBlobLargerThanSoftCapIsNotPublished() async throws {
    let store = try OriginalEncodedStore(
      root: try makeTemporaryDirectory(),
      softLimitBytes: 4
    )
    let data = Data("12345".utf8)
    let contentID = ContentID(data: data).description

    do {
      _ = try await store.commit(
        data: data,
        contentID: contentID,
        namespace: "public:tests"
      )
      XCTFail("Expected storage admission failure")
    } catch let error as AkashicError {
      XCTAssertEqual(error, .storageUnavailable)
    }

    let physicalID = await store.physicalID(
      contentID: contentID,
      namespace: "public:tests"
    )
    XCTAssertNil(physicalID)
  }

  func testIncompleteTransportDoesNotCreateRecord_CACHE_PT_010() async throws {
    let root = try makeTemporaryDirectory()
    let records = try RepresentationRecordStore(root: root.appendingPathComponent("records"))
    let pipeline = FoveaPipeline(
      transport: ThrowingTransport(error: TransportError.incompleteBody),
      encodedStore: try OriginalEncodedStore(root: root.appendingPathComponent("encoded")),
      recordStore: records
    )
    let request = ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.com/incomplete.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    await assertThrowsErrorAsync { try await pipeline.image(for: request) }
    let record = await records.record(for: variantKey(for: request).digestHex)
    XCTAssertNil(record)
  }

  func testCacheWriteFailureDoesNotOverrideFinal_ERR_PT_001() async throws {
    let body = try makePNG()
    let transport = FakeHTTPTransport(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
        body: body
      )
    ])
    let pipeline = FoveaPipeline(
      transport: transport,
      encodedStore: FailingEncodedStore(),
      recordStore: InMemoryRecordStore()
    )
    let request = ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.com/cache-failure.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    let image = try await pipeline.image(for: request)
    XCTAssertEqual(image.pixelWidth, 20)
    XCTAssertEqual(image.pixelHeight, 10)
  }
}

private struct ThrowingTransport: HTTPTransporting {
  let error: any Error & Sendable
  func execute(_ request: TransportRequest) async throws -> TransportResponse { throw error }
}

private actor FailingEncodedStore: OriginalEncodedStoring {
  func read(contentID: String, namespace: String) async throws -> Data {
    throw AkashicError.storageUnavailable
  }

  func commit(data: Data, contentID: String, namespace: String) async throws -> StoredBlob {
    throw AkashicError.storageUnavailable
  }

  func physicalID(contentID: String, namespace: String) async -> PhysicalBlobID? { nil }
  func remove(contentID: String, namespace: String) async throws {}
  func removeAll(namespace: String) async throws {}
}

private actor InMemoryRecordStore: RepresentationRecordStoring {
  private var records: [String: RepresentationRecord] = [:]

  func record(for variantDigest: String) async -> RepresentationRecord? { records[variantDigest] }
  func put(_ record: RepresentationRecord) async throws {
    records[record.variantKeyDigest] = record
  }
  func remove(_ variantDigest: String) async throws { records.removeValue(forKey: variantDigest) }
  func removeAll(namespace: String) async throws {
    records = records.filter { $0.value.securityNamespace != namespace }
  }
}
