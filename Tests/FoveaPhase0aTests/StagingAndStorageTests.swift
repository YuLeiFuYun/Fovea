import AkashicCore
import AkashicDisk
import CryptoKit
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
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

  func testRecordWriteFailureDoesNotMutateInMemoryIndex() async throws {
    let root = try makeTemporaryDirectory()
    let recordsRoot = root.appendingPathComponent("records")
    let store = try await RepresentationRecordStore.open(root: recordsRoot)
    try FileManager.default.removeItem(at: recordsRoot)
    let record = makeRepresentationRecord(
      namespace: "public:tests",
      baseKeyDigest: "record-write-base",
      variantKeyDigest: "record-write-failure"
    )

    do {
      try await store.put(record)
      XCTFail("Expected metadata persistence failure")
    } catch {
      // Expected.
    }
    let retainedRecord = await store.record(for: record.variantKeyDigest)
    XCTAssertNil(retainedRecord)
  }

  func testRecordLookupRejectsPreviousNamespaceGeneration() async throws {
    let store = try await RepresentationRecordStore.open(root: makeTemporaryDirectory())
    let record = makeRepresentationRecord(
      namespace: "account-generation",
      baseKeyDigest: "generation-bound-base",
      variantKeyDigest: "generation-bound-record",
      expiresAt: Date().addingTimeInterval(3600),
      disposition: .privateNamespace
    )
    try await store.put(record)

    let current = await store.records(
      for: record.baseKeyDigest,
      namespace: "account-generation",
      namespaceGeneration: 0
    ).first
    let revoked = await store.records(
      for: record.baseKeyDigest,
      namespace: "account-generation",
      namespaceGeneration: 1
    ).first
    XCTAssertNotNil(current)
    XCTAssertNil(revoked)
  }

  func testUnknownRecordSchemaFailsWithoutRewritingFile() async throws {
    let root = try makeTemporaryDirectory()
    let record = makeRepresentationRecord(
      recordSchemaVersion: 999,
      namespace: "public:tests",
      baseKeyDigest: "future-base",
      variantKeyDigest: "future-record"
    )
    let fileURL = root.appendingPathComponent("representation-records.json")
    let original = try JSONEncoder().encode(
      FutureRecordManifest(schemaVersion: 999, records: [record.variantKeyDigest: record])
    )
    try original.write(to: fileURL, options: [.atomic])

    do {
      _ = try await RepresentationRecordStore.open(root: root)
      XCTFail("Expected unknown schema rejection")
    } catch let error as AkashicError {
      XCTAssertEqual(error, .invalidManifest)
    }
    XCTAssertEqual(try Data(contentsOf: fileURL), original)
  }

  func testCommitRepairsCorruptExistingBlobInsteadOfTrustingFileExistence() async throws {
    let root = try makeTemporaryDirectory()
    let store = try await OriginalEncodedStore.open(root: root, softLimitBytes: 1024 * 1024)
    let data = Data("expected-content".utf8)
    let contentID = ContentID(data: data).description
    let first = try await store.commit(data: data, contentID: contentID, namespace: "public:tests")
    let firstURL = root.appendingPathComponent("blobs/\(first.physicalID.description)")
    try Data("corrupt".utf8).write(to: firstURL, options: [.atomic])

    let repaired = try await store.commit(
      data: data,
      contentID: contentID,
      namespace: "public:tests"
    )
    XCTAssertNotEqual(first.physicalID, repaired.physicalID)
    let repairedData = try await store.read(contentID: contentID, namespace: "public:tests")
    XCTAssertEqual(repairedData, data)
    XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
  }

  func testPersistentMetadataDoesNotContainPlaintextNamespace() async throws {
    let root = try makeTemporaryDirectory()
    let namespace = "account-sensitive-stable-id"
    let encodedRoot = root.appendingPathComponent("encoded")
    let recordsRoot = root.appendingPathComponent("records")
    let encoded = try await OriginalEncodedStore.open(root: encodedRoot)
    let records = try await RepresentationRecordStore.open(root: recordsRoot)
    let data = Data("private-image".utf8)
    let contentID = ContentID(data: data).description
    _ = try await encoded.commit(data: data, contentID: contentID, namespace: namespace)
    try await records.put(
      makeRepresentationRecord(
        namespace: namespace,
        baseKeyDigest: "private-base",
        variantKeyDigest: "private-variant",
        disposition: .privateNamespace,
        contentID: contentID,
        payloadLength: data.count
      )
    )

    let manifest = try String(
      contentsOf: encodedRoot.appendingPathComponent("manifest.json"),
      encoding: .utf8
    )
    let recordFile = try String(
      contentsOf: recordsRoot.appendingPathComponent("representation-records.json"),
      encoding: .utf8
    )
    XCTAssertFalse(manifest.contains(namespace))
    XCTAssertFalse(recordFile.contains(namespace))
    XCTAssertTrue(manifest.contains(StorageNamespaceFingerprint(namespace: namespace).value))
    XCTAssertTrue(recordFile.contains(StorageNamespaceFingerprint(namespace: namespace).value))
  }

  func testStoreRejectsMismatchedContentID() async throws {
    let store = try await OriginalEncodedStore.open(root: try makeTemporaryDirectory())
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
    let store = try await OriginalEncodedStore.open(
      root: try makeTemporaryDirectory(), softLimitBytes: 8)
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
    let store = try await OriginalEncodedStore.open(
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
    let records = try await RepresentationRecordStore.open(
      root: root.appendingPathComponent("records"))
    let pipeline = FoveaPipeline(
      transport: ThrowingTransport(error: TransportError.incompleteBody),
      encodedStore: try await OriginalEncodedStore.open(
        root: root.appendingPathComponent("encoded")),
      recordStore: records,
      decoder: ImageIOImageDecoder()
    )
    let request = try ImageRequest.publicImage(
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
      recordStore: InMemoryRecordStore(),
      decoder: ImageIOImageDecoder()
    )
    let request = try ImageRequest.publicImage(
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

  func records(
    for baseKeyDigest: String,
    namespace: String,
    namespaceGeneration: UInt64
  ) async -> [RepresentationRecord] {
    let fingerprint = StorageNamespaceFingerprint(namespace: namespace)
    return records.values.filter { record in
      record.baseKeyDigest == baseKeyDigest
        && record.securityNamespaceFingerprint == fingerprint
        && record.namespaceGeneration == namespaceGeneration
    }
  }
  func put(_ record: RepresentationRecord) async throws {
    records[record.variantKeyDigest] = record
  }
  func containsReference(
    to contentID: String,
    namespace: String,
    excludingVariantDigest: String?
  ) async -> Bool {
    let fingerprint = StorageNamespaceFingerprint(namespace: namespace)
    return records.values.contains { record in
      record.contentID == contentID
        && record.securityNamespaceFingerprint == fingerprint
        && record.variantKeyDigest != excludingVariantDigest
    }
  }
  func remove(
    _ variantDigest: String,
    namespace: String,
    namespaceGeneration: UInt64
  ) async throws {
    guard let record = records[variantDigest],
      record.securityNamespaceFingerprint == StorageNamespaceFingerprint(namespace: namespace),
      record.namespaceGeneration == namespaceGeneration
    else { return }
    records.removeValue(forKey: variantDigest)
  }
  func removeAll(namespace: String) async throws {
    records = records.filter {
      $0.value.securityNamespaceFingerprint != StorageNamespaceFingerprint(namespace: namespace)
    }
  }
}

private struct FutureRecordManifest: Encodable {
  let schemaVersion: UInt16
  let records: [String: RepresentationRecord]
}
