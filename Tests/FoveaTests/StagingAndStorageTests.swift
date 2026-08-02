import AkashicCore
import AkashicDisk
import CryptoKit
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import FoveaStorage
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class StagingAndStorageTests: XCTestCase {
  func testAccumulatorSpillsAndPreservesDigest_SEC_CASE_019() throws {
    let directory = try makeTemporaryDirectory()
    let accumulator = try BoundedStagingAccumulator(
      maximumBytes: 64,
      memoryThreshold: 4,
      stagingDirectory: directory
    )
    try accumulator.append(Data("hello".utf8))
    try accumulator.append(Data(" world".utf8))

    let stagedNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    let stagedName = try XCTUnwrap(stagedNames.singleElement)
    try assertSecureCacheItem(directory)
    try assertSecureCacheItem(directory.appendingPathComponent(stagedName))

    let result = try accumulator.finalize()
    let materialized = try result.materializedData()
    XCTAssertEqual(materialized, Data("hello world".utf8))
    XCTAssertTrue(result.metrics.spilledToDisk)
    let expected = SHA256.hash(data: materialized).map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(result.digestHex, expected)
  }

  func testMappedTransportBodySurvivesAccumulatorDestruction_HTTP_PT_005() throws {
    let directory = try makeTemporaryDirectory()
    let expected = Data(repeating: 0x5A, count: 16 * 1024)
    let retained: Data
    do {
      let accumulator = try BoundedStagingAccumulator(
        maximumBytes: expected.count,
        memoryThreshold: 0,
        stagingDirectory: directory
      )
      try accumulator.append(expected)
      let staged = try accumulator.finalize()
      XCTAssertTrue(staged.metrics.spilledToDisk)
      retained = try staged.materializedData()
    }

    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    XCTAssertEqual(retained, expected)
  }

  func testFinalizedMemoryBodyUsesValueSemanticsAndRejectsFurtherMutation_HTTP_PT_007()
    throws
  {
    let expected = Data(repeating: 0x41, count: 1024 * 1024)
    let accumulator = try BoundedStagingAccumulator(
      maximumBytes: expected.count + 1,
      memoryThreshold: expected.count + 1,
      stagingDirectory: makeTemporaryDirectory()
    )
    try accumulator.append(expected)

    let staged = try accumulator.finalize()
    var callerCopy = try staged.materializedData()
    callerCopy[callerCopy.startIndex] = 0x42

    XCTAssertEqual(try staged.materializedData(), expected)
    XCTAssertThrowsError(try accumulator.append(Data([0x43]))) { error in
      XCTAssertEqual(error as? TransportError, .incompleteBody)
    }
    XCTAssertThrowsError(try accumulator.finalize()) { error in
      XCTAssertEqual(error as? TransportError, .incompleteBody)
    }
  }

  func testStagedFileLeaseOutlivesTransportSessionAndDeletesOnRelease_HTTP_PT_006()
    async throws
  {
    let root = try makeTemporaryDirectory()
    let expected = Data(repeating: 0x6B, count: 16 * 1024)
    var sessionLease: StagingDirectoryLease? = try await StagingDirectoryLease.acquire(
      root: root
    )
    let sessionDirectory = try XCTUnwrap(sessionLease?.directory)
    var bodyLease: TransportStagedFileLease?
    var fileURL: URL?

    do {
      let accumulator = try BoundedStagingAccumulator(
        maximumBytes: expected.count,
        memoryThreshold: 0,
        stagingLease: XCTUnwrap(sessionLease)
      )
      try accumulator.append(expected)
      let staged = try accumulator.finalize(bodyDelivery: .deferredFileIfStaged)
      bodyLease = try XCTUnwrap(staged.stagedFileLease)
      fileURL = bodyLease?.fileURL
      XCTAssertEqual(try bodyLease?.mappedData(), expected)
    }

    sessionLease = nil
    let retainedFileURL = try XCTUnwrap(fileURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: retainedFileURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDirectory.path))
    XCTAssertEqual(try bodyLease?.mappedData(), expected)

    bodyLease = nil
    XCTAssertFalse(FileManager.default.fileExists(atPath: retainedFileURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
  }

  func testOriginalEncodedStageIsInvisibleUntilPublish_CACHE_PT_041() async throws {
    let store = try await AkashicOriginalEncodedStore.open(root: makeTemporaryDirectory())
    let data = Data("staged-original".utf8)
    let contentID = ContentID(data: data).description
    let stage = try await store.stage(
      data: data,
      contentID: contentID,
      namespace: "stage-invisible"
    )

    let unpublishedPhysicalID = await store.physicalID(
      contentID: contentID,
      namespace: "stage-invisible"
    )
    XCTAssertNil(unpublishedPhysicalID)
    do {
      _ = try await store.read(contentID: contentID, namespace: "stage-invisible")
      XCTFail("An unpublished stage must not be readable")
    } catch let error as AkashicError {
      XCTAssertEqual(error, .notFound)
    }

    let stored = try await store.publish(stage)
    XCTAssertTrue(stored.wasCreated)
    XCTAssertEqual(stored.byteCount, data.count)
    let publishedData = try await store.read(
      contentID: contentID,
      namespace: "stage-invisible"
    )
    XCTAssertEqual(publishedData, data)
  }

  func testOriginalEncodedDiscardRemovesUnpublishedStage_CACHE_PT_041() async throws {
    let store = try await AkashicOriginalEncodedStore.open(root: makeTemporaryDirectory())
    let data = Data("discarded-original".utf8)
    let contentID = ContentID(data: data).description
    let stage = try await store.stage(
      data: data,
      contentID: contentID,
      namespace: "stage-discard"
    )

    await store.discard(stage)
    await store.discard(stage)
    let discardedPhysicalID = await store.physicalID(
      contentID: contentID,
      namespace: "stage-discard"
    )
    XCTAssertNil(discardedPhysicalID)
    do {
      _ = try await store.publish(stage)
      XCTFail("A discarded stage must not be publishable")
    } catch let error as AkashicError {
      XCTAssertEqual(error, .transactionConflict)
    }
  }

  func testEquivalentOriginalStagesShareOnePhysicalBlob_CACHE_PT_042() async throws {
    let root = try makeTemporaryDirectory()
    let store = try await AkashicOriginalEncodedStore.open(root: root)
    let data = Data("shared-staged-original".utf8)
    let contentID = ContentID(data: data).description

    let firstStage = try await store.stage(
      data: data,
      contentID: contentID,
      namespace: "stage-shared"
    )
    let secondStage = try await store.stage(
      data: data,
      contentID: contentID,
      namespace: "stage-shared"
    )
    XCTAssertEqual(try akashicBlobPayloadURLs(root: root).count, 1)

    await store.discard(firstStage)
    XCTAssertEqual(try akashicBlobPayloadURLs(root: root).count, 1)
    let published = try await store.publish(secondStage)
    XCTAssertTrue(published.wasCreated)
    let publishedData = try await store.read(
      contentID: contentID,
      namespace: "stage-shared"
    )
    XCTAssertEqual(publishedData, data)
    XCTAssertEqual(try akashicBlobPayloadURLs(root: root).count, 1)

    let thirdStage = try await store.stage(
      data: data,
      contentID: contentID,
      namespace: "stage-shared"
    )
    let reused = try await store.publish(thirdStage)
    XCTAssertFalse(reused.wasCreated)
    XCTAssertEqual(reused.physicalID, published.physicalID)
    XCTAssertEqual(try akashicBlobPayloadURLs(root: root).count, 1)
  }

  func testGarbageCollectionDoesNotDeleteInFlightOriginalStage_CACHE_PT_041() async throws {
    let store = try await AkashicOriginalEncodedStore.open(root: makeTemporaryDirectory())
    let data = Data("gc-protected-stage".utf8)
    let contentID = ContentID(data: data).description
    let stage = try await store.stage(
      data: data,
      contentID: contentID,
      namespace: "stage-gc"
    )

    let result = try await store.garbageCollect(retaining: [])
    XCTAssertEqual(result.removedBlobCount, 0)
    _ = try await store.publish(stage)
    let publishedData = try await store.read(contentID: contentID, namespace: "stage-gc")
    XCTAssertEqual(publishedData, data)
  }

  func testEncodedStoreLimitsClampHostileBudgets() {
    let limits = OriginalEncodedStoreLimits(
      softTotalBytes: Int.max,
      maximumBlobBytes: Int.max
    )
    XCTAssertEqual(limits.softTotalBytes, 1024 * 1024 * 1024 * 1024)
    XCTAssertEqual(limits.maximumBlobBytes, 1024 * 1024 * 1024)
  }

  func testAccumulatorRejectsHardLimit() throws {
    let accumulator = try BoundedStagingAccumulator(
      maximumBytes: 4,
      memoryThreshold: 4,
      stagingDirectory: makeTemporaryDirectory()
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
      // 预期持久化失败。
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

  func testPreReleaseRecordSchemaFailsWithoutRewritingFile_CACHE_PT_018() async throws {
    let root = try makeTemporaryDirectory()
    let fileURL = root.appendingPathComponent("representation-records.json")
    let original = try JSONSerialization.data(
      withJSONObject: [
        "schemaVersion": 4,
        "records": [:],
      ],
      options: [.sortedKeys]
    )
    try original.write(to: fileURL, options: [.atomic])

    do {
      _ = try await RepresentationRecordStore.open(root: root)
      XCTFail("A pre-release record schema must not be interpreted by the current store")
    } catch let error as AkashicError {
      XCTAssertEqual(error, .invalidManifest)
    }
    XCTAssertEqual(try Data(contentsOf: fileURL), original)
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
    let store = try await AkashicOriginalEncodedStore.open(
      root: root, softLimitBytes: 1024 * 1024
    )
    let data = Data("expected-content".utf8)
    let contentID = ContentID(data: data).description
    let first = try await store.commit(
      data: data, contentID: contentID, namespace: "public:tests"
    )
    let firstURL = root.appendingPathComponent("blobs/\(first.physicalID.foveaStorageFileName)")
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
    let encoded = try await reopenAkashicOriginalEncodedStore(root: encodedRoot)
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

    let manifest = try akashicManifestMetadataData(root: encodedRoot)
      .map { String(decoding: $0, as: UTF8.self) }
      .joined(separator: "\n")
    let recordFile = try String(
      contentsOf: recordsRoot.appendingPathComponent("representation-records.json"),
      encoding: .utf8
    )
    XCTAssertFalse(manifest.contains(namespace))
    XCTAssertFalse(recordFile.contains(namespace))
    let entries = try akashicEffectiveManifestEntries(root: encodedRoot)
    let entry = try storageDictionary(XCTUnwrap(entries.values.first))
    let partition = try storageDictionary(entry["partition"])
    let partitionValue = try XCTUnwrap(partition["value"] as? String)
    XCTAssertEqual(Data(base64Encoded: partitionValue)?.count, 32)
    XCTAssertNotEqual(
      partitionValue,
      StorageNamespaceFingerprint(namespace: namespace).value
    )
    XCTAssertTrue(recordFile.contains(StorageNamespaceFingerprint(namespace: namespace).value))
  }

  func testRemoveDoesNotDeleteBlobWhenManifestPublicationFails_CACHE_PT_013() async throws {
    let root = try makeTemporaryDirectory()
    let store = try await AkashicOriginalEncodedStore.open(root: root)
    let data = Data("remove-transaction".utf8)
    let contentID = ContentID(data: data).description
    let stored = try await store.commit(
      data: data,
      contentID: contentID,
      namespace: "public:tests"
    )
    let blobURL = root.appendingPathComponent("blobs/\(stored.physicalID.foveaStorageFileName)")
    let metadataURL = try akashicSingleEntryMetadataURL(root: root)
    try FileManager.default.removeItem(at: metadataURL)
    try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: false)

    do {
      try await store.remove(contentID: contentID, namespace: "public:tests")
      XCTFail("元数据发布失败时删除操作必须失败")
    } catch {
      XCTAssertTrue(FileManager.default.fileExists(atPath: blobURL.path))
      let retainedPhysicalID = await store.physicalID(
        contentID: contentID,
        namespace: "public:tests"
      )
      XCTAssertEqual(retainedPhysicalID, stored.physicalID)
    }
  }

  func testRemoveAllDoesNotDeleteBlobsWhenManifestPublicationFails_CACHE_PT_013() async throws {
    let root = try makeTemporaryDirectory()
    let store = try await AkashicOriginalEncodedStore.open(root: root)
    let firstData = Data("namespace-first".utf8)
    let secondData = Data("namespace-second".utf8)
    let firstID = ContentID(data: firstData).description
    let secondID = ContentID(data: secondData).description
    let first = try await store.commit(
      data: firstData,
      contentID: firstID,
      namespace: "private:account"
    )
    let second = try await store.commit(
      data: secondData,
      contentID: secondID,
      namespace: "private:account"
    )
    let firstURL = root.appendingPathComponent("blobs/\(first.physicalID.foveaStorageFileName)")
    let secondURL = root.appendingPathComponent(
      "blobs/\(second.physicalID.foveaStorageFileName)"
    )
    let manifestURL = root.appendingPathComponent("manifest.json")
    try FileManager.default.removeItem(at: manifestURL)
    try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: false)

    do {
      try await store.removeAll(namespace: "private:account")
      XCTFail("元数据发布失败时命名空间清理必须失败")
    } catch {
      XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
      let retainedFirst = await store.physicalID(
        contentID: firstID,
        namespace: "private:account"
      )
      let retainedSecond = await store.physicalID(
        contentID: secondID,
        namespace: "private:account"
      )
      XCTAssertEqual(retainedFirst, first.physicalID)
      XCTAssertEqual(retainedSecond, second.physicalID)
    }
  }

  func testTransientBlobReadFailureDoesNotDeleteValidManifestEntry() async throws {
    let root = try makeTemporaryDirectory("blob-read-permission")
    let store = try await AkashicOriginalEncodedStore.open(root: root)
    let data = Data("permission-protected-content".utf8)
    let contentID = ContentID(data: data).description
    let stored = try await store.commit(
      data: data,
      contentID: contentID,
      namespace: "public:permission"
    )
    let blob = root.appendingPathComponent("blobs", isDirectory: true)
      .appendingPathComponent(stored.physicalID.foveaStorageFileName)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o000))],
      ofItemAtPath: blob.path
    )
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: blob.path
      )
    }

    do {
      _ = try await store.read(contentID: contentID, namespace: "public:permission")
      XCTFail("An unreadable blob must not be reported as a content mismatch")
    } catch let error as AkashicError {
      XCTAssertEqual(error, .storageUnavailable)
    }
    let retained = await store.physicalID(
      contentID: contentID,
      namespace: "public:permission"
    )
    XCTAssertEqual(retained, stored.physicalID)
  }

  func testStoreRejectsMismatchedContentID() async throws {
    let store = try await AkashicOriginalEncodedStore.open(root: makeTemporaryDirectory())
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
    let store = try await AkashicOriginalEncodedStore.open(
      root: makeTemporaryDirectory(), softLimitBytes: 8
    )
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
    let store = try await AkashicOriginalEncodedStore.open(
      root: makeTemporaryDirectory(),
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
      root: root.appendingPathComponent("records")
    )
    let pipeline = try FoveaPipeline(
      transport: ThrowingTransport(error: TransportError.incompleteBody),
      encodedStore: await AkashicOriginalEncodedStore.open(
        root: root.appendingPathComponent("encoded")
      ),
      recordStore: records,
      profileAccessPolicy: .unrestricted,
      decoder: ImageIOImageDecoder()
    )
    let request = try ImageRequest.publicImage(
      url: XCTUnwrap(URL(string: "https://example.com/incomplete.png")),
      target: TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    await assertThrowsErrorAsync { try await pipeline.image(for: request) }
    let record = await records.record(for: variantKey(for: request).digestHex)
    XCTAssertNil(record)
  }

  func testPersistentStoresApplySecurityAttributes_SEC_CASE_019() async throws {
    let root = try makeTemporaryDirectory()
    let encodedRoot = root.appendingPathComponent("encoded", isDirectory: true)
    let recordRoot = root.appendingPathComponent("records", isDirectory: true)
    let encoded = try await reopenAkashicOriginalEncodedStore(root: encodedRoot)
    let records = try await RepresentationRecordStore.open(root: recordRoot)
    let data = Data("secure-cache-content".utf8)
    let contentID = ContentID(data: data)
    let stored = try await encoded.commit(
      data: data,
      contentID: contentID.description,
      namespace: "public:tests"
    )
    try await records.put(
      makeRepresentationRecord(
        namespace: "public:tests",
        baseKeyDigest: "secure-base",
        variantKeyDigest: "secure-variant",
        contentID: contentID.description,
        payloadLength: data.count
      )
    )

    let urls = [
      encodedRoot,
      encodedRoot.appendingPathComponent("blobs", isDirectory: true),
      encodedRoot.appendingPathComponent("manifest.json"),
      encodedRoot.appendingPathComponent("blobs/\(stored.physicalID.foveaStorageFileName)"),
      recordRoot,
      recordRoot.appendingPathComponent("representation-records.json"),
    ]
    for url in urls {
      try assertSecureCacheItem(url)
    }
  }

  func testGarbageCollectionRetriesOrphanCleanupWithoutManifestVictims() async throws {
    let root = try makeTemporaryDirectory()
    let store = try await AkashicOriginalEncodedStore.open(root: root)
    let orphan = root.appendingPathComponent("blobs/orphaned-after-manifest-commit")
    try Data("orphan".utf8).write(to: orphan)
    XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))

    let result = try await store.garbageCollect(retaining: [])

    XCTAssertEqual(result.removedBlobCount, 1)
    XCTAssertEqual(result.removedByteCount, Data("orphan".utf8).count)
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
  }

  func testGarbageCollectionRejectsStoresWithoutMaintenanceCapability() async throws {
    let pipeline = FoveaPipeline(
      transport: FakeHTTPTransport(stubs: []),
      encodedStore: FailingEncodedStore(),
      recordStore: InMemoryRecordStore(),
      profileAccessPolicy: .unrestricted,
      decoder: ImageIOImageDecoder()
    )

    do {
      _ = try await pipeline.garbageCollectCaches()
      XCTFail("不支持维护协议的自定义存储不得伪装成可执行 GC")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .cacheWrite)
      XCTAssertEqual(failure.stage, .persistence)
      XCTAssertEqual(failure.disposition, .terminal)
      XCTAssertEqual(failure.reasonCode, "cache-maintenance-unavailable")
    }
  }

  func testCacheWriteFailureDoesNotOverrideFinal_ERR_PT_001() async throws {
    let body = try makePNG()
    let transport = FakeHTTPTransport(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
        body: body
      ),
    ])
    let pipeline = FoveaPipeline(
      transport: transport,
      encodedStore: FailingEncodedStore(),
      recordStore: InMemoryRecordStore(),
      profileAccessPolicy: .unrestricted,
      decoder: ImageIOImageDecoder()
    )
    let request = try ImageRequest.publicImage(
      url: XCTUnwrap(URL(string: "https://example.com/cache-failure.png")),
      target: TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    let image = try await pipeline.image(for: request)
    XCTAssertEqual(image.pixelWidth, 20)
    XCTAssertEqual(image.pixelHeight, 10)
  }

  func testReadAccessSurvivesReopenAndControlsLRUEviction() async throws {
    let root = try makeTemporaryDirectory()
    let limits = OriginalEncodedStoreLimits(softTotalBytes: 12, maximumBlobBytes: 6)
    let namespace = "public:tests"
    let first = Data("111111".utf8)
    let second = Data("222222".utf8)
    let third = Data("333333".utf8)
    let firstID = ContentID(data: first).description
    let secondID = ContentID(data: second).description
    let thirdID = ContentID(data: third).description

    var store: AkashicOriginalEncodedStore? = try await AkashicOriginalEncodedStore.open(
      root: root,
      limits: limits
    )
    let firstBlob: StoredBlob
    do {
      let activeStore = try XCTUnwrap(store)
      firstBlob = try await activeStore.commit(
        data: first, contentID: firstID, namespace: namespace
      )
      try await Task.sleep(for: .milliseconds(20))
      _ = try await activeStore.commit(
        data: second, contentID: secondID, namespace: namespace
      )
    }
    let firstBlobURL =
      root
        .appendingPathComponent("blobs", isDirectory: true)
        .appendingPathComponent(firstBlob.physicalID.foveaStorageFileName)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -10 * 60)],
      ofItemAtPath: firstBlobURL.path
    )
    do {
      let activeStore = try XCTUnwrap(store)
      _ = try await activeStore.read(contentID: firstID, namespace: namespace)
    }
    store = nil
    await Task.yield()

    let reopened = try await reopenAkashicOriginalEncodedStore(root: root, limits: limits)
    try await Task.sleep(for: .milliseconds(20))
    _ = try await reopened.commit(data: third, contentID: thirdID, namespace: namespace)

    let retainedFirst = try await reopened.read(contentID: firstID, namespace: namespace)
    let retainedThird = try await reopened.read(contentID: thirdID, namespace: namespace)
    XCTAssertEqual(retainedFirst, first)
    XCTAssertEqual(retainedThird, third)
    do {
      _ = try await reopened.read(contentID: secondID, namespace: namespace)
      XCTFail("重启后仍应按持久化访问时间淘汰真正最冷的条目")
    } catch let error as AkashicError {
      XCTAssertEqual(error, .notFound)
    }
  }

  func testRepeatedReadsWithinPersistenceBucketDoNotRewriteBlobMetadata() async throws {
    let root = try makeTemporaryDirectory()
    let namespace = "public:tests"
    let data = Data("bucket".utf8)
    let contentID = ContentID(data: data).description
    let store = try await AkashicOriginalEncodedStore.open(root: root)
    let blob = try await store.commit(data: data, contentID: contentID, namespace: namespace)
    let blobURL =
      root
        .appendingPathComponent("blobs", isDirectory: true)
        .appendingPathComponent(blob.physicalID.foveaStorageFileName)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -10 * 60)],
      ofItemAtPath: blobURL.path
    )

    _ = try await store.read(contentID: contentID, namespace: namespace)
    let firstPersistedAccess = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: blobURL.path)[.modificationDate] as? Date
    )
    try await Task.sleep(for: .milliseconds(20))
    _ = try await store.read(contentID: contentID, namespace: namespace)
    let secondPersistedAccess = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: blobURL.path)[.modificationDate] as? Date
    )

    XCTAssertEqual(secondPersistedAccess, firstPersistedAccess)
  }

  func testLowerTotalLimitTrimsImmediatelyOnReopen() async throws {
    let root = try makeTemporaryDirectory()
    let namespace = "public:tests"
    let first = Data("111111".utf8)
    let second = Data("222222".utf8)
    let firstID = ContentID(data: first).description
    let secondID = ContentID(data: second).description
    var initial: AkashicOriginalEncodedStore? = try await AkashicOriginalEncodedStore.open(
      root: root,
      limits: OriginalEncodedStoreLimits(softTotalBytes: 12, maximumBlobBytes: 6)
    )
    do {
      let activeStore = try XCTUnwrap(initial)
      _ = try await activeStore.commit(
        data: first, contentID: firstID, namespace: namespace
      )
      try await Task.sleep(for: .milliseconds(20))
      _ = try await activeStore.commit(
        data: second, contentID: secondID, namespace: namespace
      )
    }
    initial = nil
    await Task.yield()

    let tightened = try await reopenAkashicOriginalEncodedStore(
      root: root,
      limits: OriginalEncodedStoreLimits(softTotalBytes: 6, maximumBlobBytes: 6)
    )
    let retainedSecond = try await tightened.read(contentID: secondID, namespace: namespace)
    XCTAssertEqual(retainedSecond, second)
    do {
      _ = try await tightened.read(contentID: firstID, namespace: namespace)
      XCTFail("降低总预算后应在打开阶段立即淘汰最冷条目")
    } catch let error as AkashicError {
      XCTAssertEqual(error, .notFound)
    }
  }

  func testLowerRuntimeBlobLimitReconcilesEntriesWithoutInvalidatingManifest() async throws {
    let root = try makeTemporaryDirectory()
    let namespace = "public:tests"
    let data = Data("123456".utf8)
    let contentID = ContentID(data: data).description
    var initial: AkashicOriginalEncodedStore? = try await AkashicOriginalEncodedStore.open(
      root: root,
      limits: OriginalEncodedStoreLimits(softTotalBytes: 12, maximumBlobBytes: 6)
    )
    do {
      let activeStore = try XCTUnwrap(initial)
      _ = try await activeStore.commit(
        data: data, contentID: contentID, namespace: namespace
      )
    }
    initial = nil
    await Task.yield()

    let tightened = try await reopenAkashicOriginalEncodedStore(
      root: root,
      limits: OriginalEncodedStoreLimits(softTotalBytes: 12, maximumBlobBytes: 4)
    )
    do {
      _ = try await tightened.read(contentID: contentID, namespace: namespace)
      XCTFail("超过新单对象限制的旧条目应在启动时收敛为 miss")
    } catch let error as AkashicError {
      XCTAssertEqual(error, .notFound)
    }
  }
}

private func assertSecureCacheItem(
  _ url: URL,
  file: StaticString = #filePath,
  line: UInt = #line
) throws {
  let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isExcludedFromBackupKey])
  XCTAssertEqual(values.isExcludedFromBackup, true, file: file, line: line)

  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  let permissions = try XCTUnwrap(
    attributes[.posixPermissions] as? NSNumber,
    file: file,
    line: line
  )
  let expectedPermissions = values.isDirectory == true ? 0o700 : 0o600
  XCTAssertEqual(permissions.intValue & 0o777, expectedPermissions, file: file, line: line)

  #if os(iOS)
    let protection = attributes[.protectionKey] as? FileProtectionType
    #if targetEnvironment(simulator)
      // 模拟器不保证暴露数据保护属性；若可观测，仍不得弱于目标保护级别。
      XCTAssertTrue(
        protection == nil || protection == .completeUntilFirstUserAuthentication,
        file: file,
        line: line
      )
    #else
      XCTAssertEqual(
        protection,
        .completeUntilFirstUserAuthentication,
        file: file,
        line: line
      )
    #endif
  #endif
}

private struct ThrowingTransport: HTTPTransporting {
  nonisolated let reusePolicy = TransportReusePolicy.reusable(
    contextIdentifier: "tests-throwing-transport-v1"
  )

  let error: any Error & Sendable
  func execute(_: TransportRequest) async throws -> TransportResponse {
    throw error
  }
}

private actor FailingEncodedStore: OriginalEncodedStoring {
  func read(contentID _: String, namespace _: String) async throws -> Data {
    throw AkashicError.storageUnavailable
  }

  func commit(data _: Data, contentID _: String, namespace _: String) async throws -> StoredBlob {
    throw AkashicError.storageUnavailable
  }

  func physicalID(contentID _: String, namespace _: String) async -> PhysicalBlobID? {
    nil
  }

  func remove(contentID _: String, namespace _: String) async throws {}
  func removeAll(namespace _: String) async throws {}
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
          record.securityNamespaceFingerprint
          == StorageNamespaceFingerprint(namespace: namespace),
          record.namespaceGeneration == namespaceGeneration
    else { return }
    records.removeValue(forKey: variantDigest)
  }

  func removeAll(namespace: String) async throws {
    records = records.filter {
      $0.value.securityNamespaceFingerprint
        != StorageNamespaceFingerprint(namespace: namespace)
    }
  }
}

private struct FutureRecordManifest: Encodable {
  let schemaVersion: UInt16
  let records: [String: RepresentationRecord]
}

private enum StorageManifestFixtureError: Error {
  case invalidObject
}

private func storageJSONObject(_ data: Data) throws -> [String: Any] {
  try storageDictionary(JSONSerialization.jsonObject(with: data))
}

private func storageDictionary(_ value: Any?) throws -> [String: Any] {
  guard let value = value as? [String: Any] else {
    throw StorageManifestFixtureError.invalidObject
  }
  return value
}
