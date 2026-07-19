import AkashicCore
import AkashicDisk
import Foundation
import FoveaCore
import FoveaPersistence
import XCTest

final class FilesystemLinkDefenseTests: XCTestCase {
  func testManagedDirectoryRejectsSymbolicLink_SEC_CASE_031() throws {
    let root = try makeTemporaryDirectory("managed-directory-symlink")
    let target = root.appendingPathComponent("target", isDirectory: true)
    let link = root.appendingPathComponent("managed", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    XCTAssertThrowsError(try StorageDirectorySecurity.prepareDirectory(link))
    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
  }

  func testGenerationAndWriterLocksRejectSymbolicLinks_SEC_CASE_031() async throws {
    let generationRoot = try makeTemporaryDirectory("generation-lock-symlink")
    let generationTarget = generationRoot.appendingPathComponent("generation-target")
    try Data("sentinel".utf8).write(to: generationTarget)
    try FileManager.default.createSymbolicLink(
      at: generationRoot.appendingPathComponent(".store-generation.lock"),
      withDestinationURL: generationTarget
    )

    XCTAssertThrowsError(
      try StoreGenerationDirectory.open(
        root: generationRoot,
        compatibilityFingerprint: "link-defense-v1"
      )
    )
    XCTAssertEqual(try Data(contentsOf: generationTarget), Data("sentinel".utf8))

    let writerRoot = try makeTemporaryDirectory("writer-lock-symlink")
    let generation = try StoreGenerationDirectory.open(
      root: writerRoot,
      compatibilityFingerprint: FoveaPersistentStores.currentCompatibilityFingerprint
    )
    let writerTarget = writerRoot.appendingPathComponent("writer-target")
    try Data("writer-sentinel".utf8).write(to: writerTarget)
    try FileManager.default.createSymbolicLink(
      at: generation.root.appendingPathComponent(".fovea-writer.lock"),
      withDestinationURL: writerTarget
    )

    do {
      _ = try await FoveaPersistentStores.open(root: writerRoot)
      XCTFail("writer lock 符号链接必须失败关闭")
    } catch {
      // 任意稳定的文件系统拒绝错误均满足该安全契约。
    }
    XCTAssertEqual(try Data(contentsOf: writerTarget), Data("writer-sentinel".utf8))
  }

  func testLockAndManifestHardLinksAreRejected_SEC_CASE_031() async throws {
    let lockRoot = try makeTemporaryDirectory("generation-lock-hard-link")
    let lockTarget = lockRoot.appendingPathComponent("lock-target")
    let lockSentinel = Data("hard-link-sentinel".utf8)
    try lockSentinel.write(to: lockTarget)
    try FileManager.default.linkItem(
      at: lockTarget,
      to: lockRoot.appendingPathComponent(".store-generation.lock")
    )

    XCTAssertThrowsError(
      try StoreGenerationDirectory.open(
        root: lockRoot,
        compatibilityFingerprint: "hard-link-defense-v1"
      )
    )
    XCTAssertEqual(try Data(contentsOf: lockTarget), lockSentinel)

    let manifestRoot = try makeTemporaryDirectory("manifest-hard-link")
    let manifestTarget = manifestRoot.deletingLastPathComponent()
      .appendingPathComponent("hard-linked-manifest-\(UUID().uuidString).json")
    let manifestSentinel = Data(#"{"entries":{},"schemaVersion":4}"#.utf8)
    try manifestSentinel.write(to: manifestTarget)
    try FileManager.default.linkItem(
      at: manifestTarget,
      to: manifestRoot.appendingPathComponent("manifest.json")
    )

    do {
      _ = try await OriginalEncodedStore.open(root: manifestRoot)
      XCTFail("manifest 硬链接必须失败关闭")
    } catch {
      // 关键约束是不得读取、改写或收紧外部 inode。
    }
    XCTAssertEqual(try Data(contentsOf: manifestTarget), manifestSentinel)
  }

  func testManifestAndBlobSymlinksAreNeverFollowed_SEC_CASE_031() async throws {
    let manifestRoot = try makeTemporaryDirectory("manifest-symlink")
    let externalManifest = manifestRoot.deletingLastPathComponent()
      .appendingPathComponent("external-manifest-\(UUID().uuidString).json")
    let sentinel = Data("external-manifest".utf8)
    try sentinel.write(to: externalManifest)
    try FileManager.default.createSymbolicLink(
      at: manifestRoot.appendingPathComponent("manifest.json"),
      withDestinationURL: externalManifest
    )

    do {
      _ = try await OriginalEncodedStore.open(root: manifestRoot)
      XCTFail("manifest 符号链接必须失败关闭")
    } catch {
      // 失败类型不是公开协议；关键约束是不得跟随或改写目标。
    }
    XCTAssertEqual(try Data(contentsOf: externalManifest), sentinel)

    let blobRoot = try makeTemporaryDirectory("blob-symlink")
    let store = try await OriginalEncodedStore.open(root: blobRoot)
    let payload = Data("same-bytes-as-external-target".utf8)
    let contentID = ContentID(data: payload).description
    let stored = try await store.commit(
      data: payload,
      contentID: contentID,
      namespace: "public:link-defense"
    )
    let blobURL = blobRoot.appendingPathComponent("blobs", isDirectory: true)
      .appendingPathComponent(stored.physicalID.description)
    let externalBlob = blobRoot.deletingLastPathComponent()
      .appendingPathComponent("external-blob-\(UUID().uuidString)")
    try payload.write(to: externalBlob)
    try FileManager.default.removeItem(at: blobURL)
    try FileManager.default.createSymbolicLink(at: blobURL, withDestinationURL: externalBlob)

    do {
      _ = try await store.read(contentID: contentID, namespace: "public:link-defense")
      XCTFail("blob 符号链接不得被当作有效缓存内容读取")
    } catch let error as AkashicError {
      XCTAssertEqual(error, .integrityMismatch)
    }
    XCTAssertEqual(try Data(contentsOf: externalBlob), payload)
    let retainedPhysicalID = await store.physicalID(
      contentID: contentID,
      namespace: "public:link-defense"
    )
    XCTAssertNil(retainedPhysicalID)
  }
}
