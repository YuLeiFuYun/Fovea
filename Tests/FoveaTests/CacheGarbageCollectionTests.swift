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

  func testGarbageCollectionRetainsBlobUntilLastVaryReferenceIsRemovedCachePt019() async throws {
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
      values: ["accept-language": .plain("en")]
    )
    let french = HTTPVarySelection(
      fieldNames: ["accept-language"],
      values: ["accept-language": .plain("fr")]
    )
    try await records.put(
      makeRepresentationRecord(
        namespace: "public:tests",
        baseKeyDigest: "base",
        variantKeyDigest: "variant-en",
        vary: english,
        contentID: contentID.description,
        payloadLength: data.count
      )
    )
    try await records.put(
      makeRepresentationRecord(
        namespace: "public:tests",
        baseKeyDigest: "base",
        variantKeyDigest: "variant-fr",
        vary: french,
        contentID: contentID.description,
        payloadLength: data.count
      )
    )
    let pipeline = FoveaPipeline(
      transport: FakeHTTPTransport(stubs: []),
      encodedStore: encoded,
      recordStore: records,
      decoder: ImageIOImageDecoder()
    )

    try await records.remove(
      "variant-en",
      namespace: "public:tests",
      namespaceGeneration: 0
    )
    let first = try await pipeline.garbageCollectCaches()
    XCTAssertEqual(first.removedBlobCount, 0)
    XCTAssertNotNil(
      await encoded.physicalID(
        contentID: contentID.description,
        namespace: "public:tests"
      )
    )

    try await records.remove(
      "variant-fr",
      namespace: "public:tests",
      namespaceGeneration: 0
    )
    let second = try await pipeline.garbageCollectCaches()
    XCTAssertEqual(second.removedBlobCount, 1)
    XCTAssertEqual(second.removedByteCount, data.count)
    XCTAssertNil(
      await encoded.physicalID(
        contentID: contentID.description,
        namespace: "public:tests"
      )
    )
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
    XCTAssertFalse(await completion.isFinished)

    await barrierStore.releaseCommit()
    _ = try await imageTask.value
    let result = try await garbageTask.value
    XCTAssertEqual(result.removedBlobCount, 0)
    XCTAssertTrue(await completion.isFinished)

    let candidates = await records.records(
      for: request.fetchBaseKey.digestHex,
      namespace: request.namespace.value,
      namespaceGeneration: 0
    )
    let record = try XCTUnwrap(candidates.first)
    XCTAssertNotNil(
      await baseStore.physicalID(
        contentID: record.contentID,
        namespace: request.namespace.value
      )
    )
  }
}

private actor CompletionFlag {
  private(set) var isFinished = false

  func markFinished() {
    isFinished = true
  }
}
