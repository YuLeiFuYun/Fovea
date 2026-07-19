import AkashicCore
import AkashicDisk
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class CacheGarbageCollectionTests: XCTestCase {
  func testBootstrapRemovesTemporaryAndOrphanBlobFilesCachePt013() async throws {
    let root = try makeTemporaryDirectory()
    let storeRoot = root.appendingPathComponent("encoded", isDirectory: true)
    let store = try await OriginalEncodedStore.open(root: storeRoot)
    let data = Data("retained".utf8)
    let contentID = ContentID(data: data)
    let stored = try await store.commit(
      data: data,
      contentID: contentID.description,
      namespace: "public:tests"
    )
    let blobs = storeRoot.appendingPathComponent("blobs", isDirectory: true)
    let orphan = blobs.appendingPathComponent(UUID().uuidString.lowercased())
    let temporary = blobs.appendingPathComponent(".tmp-stale")
    try Data("orphan".utf8).write(to: orphan)
    try Data("temporary".utf8).write(to: temporary)

    let reopened = try await OriginalEncodedStore.open(root: storeRoot)

    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    let retained = blobs.appendingPathComponent(stored.physicalID.description)
    XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
    let loaded = try await reopened.read(
      contentID: contentID.description,
      namespace: "public:tests"
    )
    XCTAssertEqual(loaded, data)
  }

  func testContentReferencesReflectPersistedRecordsAfterReopenCachePt020() async throws {
    let root = try makeTemporaryDirectory().appendingPathComponent("records")
    let store = try await RepresentationRecordStore.open(root: root)
    let first = makeRepresentationRecord(
      namespace: "private:alpha",
      baseKeyDigest: "base-a",
      variantKeyDigest: "variant-a",
      contentID: "content-a",
      payloadLength: 10
    )
    let duplicateContent = makeRepresentationRecord(
      namespace: "private:alpha",
      baseKeyDigest: "base-b",
      variantKeyDigest: "variant-b",
      contentID: "content-a",
      payloadLength: 10
    )
    let secondNamespace = makeRepresentationRecord(
      namespace: "private:beta",
      baseKeyDigest: "base-c",
      variantKeyDigest: "variant-c",
      contentID: "content-a",
      payloadLength: 10
    )
    try await store.put(first)
    try await store.put(duplicateContent)
    try await store.put(secondNamespace)

    let reopened = try await RepresentationRecordStore.open(root: root)
    let references = await reopened.contentReferences()

    XCTAssertEqual(
      references,
      [
        StoredContentReference(
          namespaceFingerprint: StorageNamespaceFingerprint(namespace: "private:alpha"),
          contentID: first.contentID
        ),
        StoredContentReference(
          namespaceFingerprint: StorageNamespaceFingerprint(namespace: "private:beta"),
          contentID: secondNamespace.contentID
        ),
      ]
    )
  }

  func testGarbageCollectionRetainsBlobUntilLastVaryReferenceIsRemovedCachePt020() async throws {
    let root = try makeTemporaryDirectory()
    let encoded = try await OriginalEncodedStore.open(root: root.appendingPathComponent("encoded"))
    let records = try await RepresentationRecordStore.open(
      root: root.appendingPathComponent("records")
    )
    let data = Data("shared-vary-content".utf8)
    let contentID = ContentID(data: data)
    _ = try await encoded.commit(
      data: data,
      contentID: contentID.description,
      namespace: "public:tests"
    )
    let english = HTTPVarySelection(
      fieldNames: ["accept-language"],
      values: ["accept-language": .field("en")]
    )
    let french = HTTPVarySelection(
      fieldNames: ["accept-language"],
      values: ["accept-language": .field("fr")]
    )
    let englishRecord = makeRepresentationRecord(
      namespace: "public:tests",
      baseKeyDigest: "base",
      variantKeyDigest: "variant-en",
      vary: english,
      contentID: contentID.description,
      payloadLength: data.count
    )
    let frenchRecord = makeRepresentationRecord(
      namespace: "public:tests",
      baseKeyDigest: "base",
      variantKeyDigest: "variant-fr",
      vary: french,
      contentID: contentID.description,
      payloadLength: data.count
    )
    try await records.put(englishRecord)
    try await records.put(frenchRecord)
    let pipeline = FoveaPipeline(
      transport: FakeHTTPTransport(stubs: []),
      encodedStore: encoded,
      recordStore: records,
      decoder: ImageIOImageDecoder()
    )

    try await records.remove(
      englishRecord.variantKeyDigest,
      namespace: "public:tests",
      namespaceGeneration: 0
    )
    let first = try await pipeline.garbageCollectCaches()
    XCTAssertEqual(first.removedBlobCount, 0)
    let retainedPhysicalID = await encoded.physicalID(
      contentID: contentID.description,
      namespace: "public:tests"
    )
    XCTAssertNotNil(retainedPhysicalID)

    try await records.remove(
      frenchRecord.variantKeyDigest,
      namespace: "public:tests",
      namespaceGeneration: 0
    )
    let second = try await pipeline.garbageCollectCaches()
    XCTAssertEqual(second.removedBlobCount, 1)
    XCTAssertEqual(second.removedByteCount, data.count)
    let removedPhysicalID = await encoded.physicalID(
      contentID: contentID.description,
      namespace: "public:tests"
    )
    XCTAssertNil(removedPhysicalID)
  }

  func testCancelledGarbageCollectionWaiterReturnsStructuredCancellation_RES_PT_002() async throws {
    let body = try makePNG()
    let root = try makeTemporaryDirectory()
    let baseStore = try await OriginalEncodedStore.open(
      root: root.appendingPathComponent("encoded")
    )
    let barrierStore = CommitBarrierEncodedStore(base: baseStore)
    let records = try await RepresentationRecordStore.open(
      root: root.appendingPathComponent("records")
    )
    let pipeline = FoveaPipeline(
      transport: FakeHTTPTransport(stubs: [
        .init(
          statusCode: 200,
          headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
          body: body
        )
      ]),
      encodedStore: barrierStore,
      recordStore: records,
      decoder: ImageIOImageDecoder()
    )
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/gc-cancel.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )
    let imageTask = Task { try await pipeline.image(for: request) }
    await barrierStore.waitUntilCommitStarts()
    let garbageTask = Task { try await pipeline.garbageCollectCaches() }
    try await Task.sleep(for: .milliseconds(20))

    garbageTask.cancel()
    do {
      _ = try await garbageTask.value
      XCTFail("取消的 GC 等待者不得继续执行")
    } catch let failure as PipelineFailure {
      XCTAssertEqual(failure.category, .cancelled)
      XCTAssertEqual(failure.stage, .persistence)
      XCTAssertEqual(failure.disposition, .cancelled)
    }

    await barrierStore.releaseCommit()
    _ = try await imageTask.value
  }

  func testGarbageCollectionRecoversBlobPublishedBeforeRecordAfterReopenCachePt013() async throws {
    let root = try makeTemporaryDirectory()
    let encodedRoot = root.appendingPathComponent("encoded")
    let recordsRoot = root.appendingPathComponent("records")
    let data = Data("published-before-record".utf8)
    let contentID = ContentID(data: data).description
    let namespace = "public:tests"
    let encoded = try await OriginalEncodedStore.open(root: encodedRoot)
    _ = try await encoded.commit(
      data: data,
      contentID: contentID,
      namespace: namespace
    )

    let reopenedEncoded = try await OriginalEncodedStore.open(root: encodedRoot)
    let reopenedRecords = try await RepresentationRecordStore.open(root: recordsRoot)
    let pipeline = FoveaPipeline(
      transport: FakeHTTPTransport(stubs: []),
      encodedStore: reopenedEncoded,
      recordStore: reopenedRecords,
      decoder: ImageIOImageDecoder()
    )

    let result = try await pipeline.garbageCollectCaches()

    XCTAssertEqual(result.removedBlobCount, 1)
    await assertThrowsErrorAsync {
      _ = try await reopenedEncoded.read(contentID: contentID, namespace: namespace)
    }
  }

  func testGarbageCollectionWaitsForCommitPublicationCachePt013() async throws {
    let body = try makePNG()
    let root = try makeTemporaryDirectory()
    let baseStore = try await OriginalEncodedStore.open(
      root: root.appendingPathComponent("encoded")
    )
    let barrierStore = CommitBarrierEncodedStore(base: baseStore)
    let records = try await RepresentationRecordStore.open(
      root: root.appendingPathComponent("records")
    )
    let transport = FakeHTTPTransport(stubs: [
      .init(
        statusCode: 200,
        headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
        body: body
      )
    ])
    let pipeline = FoveaPipeline(
      transport: transport,
      encodedStore: barrierStore,
      recordStore: records,
      decoder: ImageIOImageDecoder()
    )
    let request = try ImageRequest.publicImage(
      url: try XCTUnwrap(URL(string: "https://example.test/gc-commit-race.png")),
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests"
    )

    let imageTask = Task { try await pipeline.image(for: request) }
    await barrierStore.waitUntilCommitStarts()
    let completion = CompletionFlag()
    let garbageTask = Task {
      let result = try await pipeline.garbageCollectCaches()
      await completion.markFinished()
      return result
    }
    try await Task.sleep(for: .milliseconds(20))
    let finishedBeforeRelease = await completion.isFinished
    XCTAssertFalse(finishedBeforeRelease)

    await barrierStore.releaseCommit()
    _ = try await imageTask.value
    let result = try await garbageTask.value
    XCTAssertEqual(result.removedBlobCount, 0)
    let finishedAfterRelease = await completion.isFinished
    XCTAssertTrue(finishedAfterRelease)

    let candidates = await records.records(
      for: request.fetchBaseKey.digestHex,
      namespace: request.namespace.value,
      namespaceGeneration: 0
    )
    let record = try XCTUnwrap(candidates.first)
    let committedPhysicalID = await baseStore.physicalID(
      contentID: record.contentID,
      namespace: request.namespace.value
    )
    XCTAssertNotNil(committedPhysicalID)
  }
}

private actor CompletionFlag {
  private(set) var isFinished = false

  func markFinished() {
    isFinished = true
  }
}
