import AkashicCore
import AkashicDisk
import Foundation
import FoveaCore
import FoveaPersistence
import FoveaStorage
import XCTest

final class FilesystemLinkDefenseTests: XCTestCase {
    func testManagedDirectoryRejectsSymbolicLink_SEC_CASE_031() throws {
        let root = try makeTemporaryDirectory("managed-directory-symlink")
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try FoveaManagedFileSecurity.prepareDirectory(link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testWriterLockRejectsSymbolicLink_SEC_CASE_031() async throws {
        let writerRoot = try makeTemporaryDirectory("writer-lock-symlink")
        let generation = try await StoreGenerationDirectory.open(
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
        let writerRoot = try makeTemporaryDirectory("akashic-writer-hard-link")
        let writerTarget = writerRoot.deletingLastPathComponent()
            .appendingPathComponent("hard-linked-writer-\(UUID().uuidString).lock")
        let writerSentinel = Data("writer-sentinel".utf8)
        try writerSentinel.write(to: writerTarget)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: writerTarget.path
        )
        try FileManager.default.linkItem(
            at: writerTarget,
            to: writerRoot.appendingPathComponent(".akashic-writer.lock")
        )

        do {
            _ = try await FileBlobStore.open(root: writerRoot)
            XCTFail("Akashic writer lock 硬链接必须失败关闭")
        } catch {
            // 关键约束是不得锁定或修改外部 inode。
        }
        XCTAssertEqual(try Data(contentsOf: writerTarget), writerSentinel)

        let manifestRoot = try makeTemporaryDirectory("manifest-hard-link")
        let manifestTarget = manifestRoot.deletingLastPathComponent()
            .appendingPathComponent("hard-linked-manifest-\(UUID().uuidString).json")
        let manifestSentinel = Data(#"{"entries":{},"schemaVersion":1}"#.utf8)
        try manifestSentinel.write(to: manifestTarget)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: manifestTarget.path
        )
        try FileManager.default.linkItem(
            at: manifestTarget,
            to: manifestRoot.appendingPathComponent("manifest.json")
        )

        do {
            _ = try await FileBlobStore.open(root: manifestRoot)
            XCTFail("manifest 硬链接必须失败关闭")
        } catch {
            // 关键约束是不得读取、改写或收紧外部 inode。
        }
        XCTAssertEqual(try Data(contentsOf: manifestTarget), manifestSentinel)
    }

    func testSymlinkTimestampCannotProtectCorruptBlobFromTrimming_SEC_CASE_031() async throws {
        let root = try makeTemporaryDirectory("trim-symlink-timestamp")
        let store = try await AkashicOriginalEncodedStore.open(
            root: root,
            limits: OriginalEncodedStoreLimits(
                softTotalBytes: 16,
                maximumBlobBytes: 8
            )
        )
        let namespace = "public:trim-link-defense"
        let first = Data("aaaaaaaa".utf8)
        let second = Data("bbbbbbbb".utf8)
        let third = Data("cccccccc".utf8)
        let firstID = ContentID(data: first).description
        let secondID = ContentID(data: second).description
        let thirdID = ContentID(data: third).description

        let firstBlob = try await store.commit(
            data: first,
            contentID: firstID,
            namespace: namespace
        )
        _ = try await store.commit(
            data: second,
            contentID: secondID,
            namespace: namespace
        )

        let firstURL = root.appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(firstBlob.physicalID.foveaStorageFileName)
        let external = root.deletingLastPathComponent()
            .appendingPathComponent("external-trim-target-\(UUID().uuidString)")
        let sentinel = Data("external-sentinel".utf8)
        try sentinel.write(to: external)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(24 * 60 * 60)],
            ofItemAtPath: external.path
        )
        try FileManager.default.removeItem(at: firstURL)
        try FileManager.default.createSymbolicLink(at: firstURL, withDestinationURL: external)

        _ = try await store.commit(
            data: third,
            contentID: thirdID,
            namespace: namespace
        )

        let retainedFirst = await store.physicalID(contentID: firstID, namespace: namespace)
        let retainedSecond = try await store.read(contentID: secondID, namespace: namespace)
        XCTAssertNil(retainedFirst)
        XCTAssertEqual(retainedSecond, second)
        XCTAssertEqual(try Data(contentsOf: external), sentinel)
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
            _ = try await AkashicOriginalEncodedStore.open(root: manifestRoot)
            XCTFail("manifest 符号链接必须失败关闭")
        } catch {
            // 失败类型不是公开协议；关键约束是不得跟随或改写目标。
        }
        XCTAssertEqual(try Data(contentsOf: externalManifest), sentinel)

        let blobRoot = try makeTemporaryDirectory("blob-symlink")
        let store = try await AkashicOriginalEncodedStore.open(root: blobRoot)
        let payload = Data("same-bytes-as-external-target".utf8)
        let contentID = ContentID(data: payload).description
        let stored = try await store.commit(
            data: payload,
            contentID: contentID,
            namespace: "public:link-defense"
        )
        let blobURL = blobRoot.appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(stored.physicalID.foveaStorageFileName)
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
