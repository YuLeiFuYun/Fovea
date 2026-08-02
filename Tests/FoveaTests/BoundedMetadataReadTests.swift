import AkashicCore
import AkashicDisk
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import XCTest

final class BoundedMetadataReadTests: XCTestCase {
    func testOversizedStoreManifestsFailBeforeUnboundedRead_SEC_CASE_032() async throws {
        let oversizedBytes: UInt64 = 65 * 1024 * 1024

        let originalRoot = try makeTemporaryDirectory("oversized-original-manifest")
        let originalManifest = originalRoot.appendingPathComponent("manifest.json")
        try createSparseFile(at: originalManifest, byteCount: oversizedBytes)
        do {
            _ = try await AkashicOriginalEncodedStore.open(root: originalRoot)
            XCTFail("超限 OriginalEncoded manifest 必须失败关闭")
        } catch let error as AkashicError {
            XCTAssertEqual(error, .storageUnavailable)
        }
        XCTAssertEqual(try fileSize(originalManifest), oversizedBytes)

        let recordRoot = try makeTemporaryDirectory("oversized-record-manifest")
        let recordManifest = recordRoot.appendingPathComponent("representation-records.json")
        try createSparseFile(at: recordManifest, byteCount: oversizedBytes)
        do {
            _ = try await RepresentationRecordStore.open(root: recordRoot)
            XCTFail("超限 representation manifest 必须失败关闭")
        } catch let error as AkashicError {
            XCTAssertEqual(error, .storageUnavailable)
        }
        XCTAssertEqual(try fileSize(recordManifest), oversizedBytes)
    }

    func testOversizedBlobIsRejectedBeforeAllocationAndQuarantined_SEC_CASE_032() async throws {
        let root = try makeTemporaryDirectory("oversized-blob-read")
        let store = try await AkashicOriginalEncodedStore.open(
            root: root, softLimitBytes: 1024 * 1024)
        let payload = Data("small-original".utf8)
        let contentID = ContentID(data: payload).description
        let stored = try await store.commit(
            data: payload,
            contentID: contentID,
            namespace: "public:bounded-read"
        )
        let blob = root.appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(stored.physicalID.foveaStorageFileName)
        try createSparseFile(at: blob, byteCount: 512 * 1024 * 1024)

        do {
            _ = try await store.read(contentID: contentID, namespace: "public:bounded-read")
            XCTFail("超出记录长度的 blob 不得进入 Data 分配")
        } catch let error as AkashicError {
            XCTAssertEqual(error, .integrityMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path))
        let retained = await store.physicalID(
            contentID: contentID,
            namespace: "public:bounded-read"
        )
        XCTAssertNil(retained)
    }
}

private func createSparseFile(at url: URL, byteCount: UInt64) throws {
    try? FileManager.default.removeItem(at: url)
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: byteCount)
}

private func fileSize(_ url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.size] as? NSNumber).uint64Value
}
