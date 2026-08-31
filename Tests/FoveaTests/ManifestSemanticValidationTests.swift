import AkashicCore
import AkashicDisk
import CryptoKit
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import XCTest

final class ManifestSemanticValidationTests: XCTestCase {
    func testOriginalManifestSemanticCorruptionFailsClosedWithoutRewrite_SEC_CASE_030()
        async throws
    {
        for mutation in OriginalManifestMutation.allCases {
            let root = try makeTemporaryDirectory("original-manifest-\(mutation.rawValue)")
            var store: AkashicOriginalEncodedStore? = try await AkashicOriginalEncodedStore.open(
                root: root
            )
            for label in ["first", "second"] {
                let data = Data(label.utf8)
                let activeStore = try XCTUnwrap(store)
                _ = try await activeStore.commit(
                    data: data,
                    contentID: ContentID(data: data).description,
                    namespace: "public:manifest-tests"
                )
            }
            if try akashicManifestSchemaVersion(root: root) == 4 {
                try await forceAkashicManifestSnapshotCheckpoint(try XCTUnwrap(store))
            }
            store = nil
            await Task.yield()

            let recordFixtures = try akashicManifestRecordFixtures(root: root)
            let writes: [OriginalManifestMutationWrite]
            if recordFixtures.isEmpty {
                let snapshotURL = root.appendingPathComponent("manifest.json")
                writes = try [
                    OriginalManifestMutationWrite(
                        url: snapshotURL,
                        xattrName: nil,
                        data: mutation.applyToSnapshot(
                            Data(contentsOf: snapshotURL)
                        )
                    )
                ]
            } else {
                writes = try mutation.apply(to: recordFixtures)
            }
            for write in writes {
                try writeAkashicManifestFixture(
                    write.data,
                    to: write.url,
                    xattrName: write.xattrName
                )
            }

            do {
                _ = try await reopenAkashicOriginalEncodedStore(root: root)
                XCTFail("同 schema 的语义损坏必须失败关闭: \(mutation.rawValue)")
            } catch let error as AkashicError {
                XCTAssertEqual(error, .invalidManifest)
            }
            for write in writes {
                XCTAssertEqual(
                    try akashicManifestFixtureData(
                        at: write.url,
                        xattrName: write.xattrName
                    ),
                    write.data
                )
            }
        }
    }

    func testOriginalManifestEntryAboveRuntimeLimitIsReconciled_SEC_CASE_030() async throws {
        let root = try makeTemporaryDirectory("original-manifest-over-budget")
        let namespace = "public:manifest-budget"
        var store: AkashicOriginalEncodedStore? = try await reopenAkashicOriginalEncodedStore(
            root: root,
            limits: OriginalEncodedStoreLimits(softTotalBytes: 32, maximumBlobBytes: 32)
        )
        let payload = Data("small".utf8)
        do {
            let activeStore = try XCTUnwrap(store)
            _ = try await activeStore.commit(
                data: payload,
                contentID: ContentID(data: payload).description,
                namespace: namespace
            )
        }
        if try akashicManifestSchemaVersion(root: root) == 4 {
            try await forceAkashicManifestSnapshotCheckpoint(try XCTUnwrap(store))
        }
        store = nil
        await Task.yield()

        let oversizedDigest = "sha256:\(String(repeating: "0", count: 64)):33"
        let corruptedURL: URL
        let corruptedXattrName: String?
        let corrupted: Data
        let recordFixtures = try akashicManifestRecordFixtures(root: root)
        if var fixture = recordFixtures.singleElement {
            var entry = try XCTUnwrap(try fixture.entryObject())
            let partitionBytes = try fixture.entryPartitionBytes(entry)
            fixture.setEntryDigestBytes(Data(repeating: 0, count: 32), byteCount: 33, in: &entry)
            let newKey = manifestKey(partitionBytes: partitionBytes, digest: oversizedDigest)
            try fixture.setEmbeddedManifestKey(newKey)
            fixture.setEntryObject(entry)
            corrupted = try JSONSerialization.data(
                withJSONObject: fixture.object,
                options: [.sortedKeys]
            )
            let target = try fixture.retargetedCarrier(forManifestKey: newKey)
            corruptedURL = target.url
            corruptedXattrName = target.xattrName
            try removeAkashicManifestFixture(at: fixture.url, xattrName: fixture.xattrName)
            try writeAkashicManifestFixture(
                corrupted,
                to: corruptedURL,
                xattrName: corruptedXattrName
            )
        } else {
            corruptedURL = root.appendingPathComponent("manifest.json")
            corruptedXattrName = nil
            var manifest = try jsonObject(Data(contentsOf: corruptedURL))
            if var compact = manifest["e"] as? [[String: Any]] {
                guard compact.count == 1 else { throw ManifestFixtureError.invalidFixture }
                var entry = compact[0]
                guard let partitionValue = entry["p"] as? String,
                    let partitionBytes = Data(base64Encoded: partitionValue),
                    partitionBytes.count == 32
                else { throw ManifestFixtureError.invalidFixture }
                entry["n"] = 33
                entry["h"] = Data(repeating: 0, count: 32).base64EncodedString()
                compact[0] = entry
                manifest["e"] = compact
                if (manifest["schemaVersion"] as? NSNumber)?.intValue == 4 {
                    try resealAkashicDirectoryHeadSnapshotFixture(&manifest)
                }
            } else {
                var entries = try dictionary(manifest["entries"])
                let oldKey = try XCTUnwrap(entries.keys.first)
                var entry = try dictionary(entries.removeValue(forKey: oldKey))
                let partition = try dictionary(entry["partition"])
                let partitionValue = try XCTUnwrap(partition["value"] as? String)
                let partitionBytes = try XCTUnwrap(Data(base64Encoded: partitionValue))
                XCTAssertEqual(partitionBytes.count, 32)
                entry["byteCount"] = 33
                entry["digest"] = ["canonical": oversizedDigest]
                let newKey = manifestKey(partitionBytes: partitionBytes, digest: oversizedDigest)
                entries[newKey] = entry
                manifest["entries"] = entries
            }
            corrupted = try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.sortedKeys]
            )
            try writeAkashicManifestFixture(corrupted, to: corruptedURL)
        }

        let reconciledStore = try await reopenAkashicOriginalEncodedStore(
            root: root,
            limits: OriginalEncodedStoreLimits(softTotalBytes: 32, maximumBlobBytes: 32)
        )
        _ = reconciledStore

        XCTAssertNotEqual(
            try? akashicManifestFixtureData(
                at: corruptedURL,
                xattrName: corruptedXattrName
            ),
            Optional(corrupted)
        )
        XCTAssertTrue(try akashicEffectiveManifestEntries(root: root).isEmpty)
        XCTAssertTrue(try akashicBlobPayloadURLs(root: root).isEmpty)
    }

    func testRepresentationManifestSemanticCorruptionFailsClosedWithoutRewrite_SEC_CASE_030()
        async throws
    {
        for mutation in RepresentationManifestMutation.allCases {
            let root = try makeTemporaryDirectory("record-manifest-\(mutation.rawValue)")
            let store = try await RepresentationRecordStore.open(root: root)
            let record = makeRepresentationRecord(
                namespace: "public:manifest-tests",
                baseKeyDigest: "record-base",
                variantKeyDigest: "record-variant",
                requestTime: Date(timeIntervalSince1970: 10),
                responseTime: Date(timeIntervalSince1970: 11),
                contentID: "record-content",
                payloadLength: 14
            )
            try await store.put(record)
            let fileURL = root.appendingPathComponent("representation-records.json")
            let corrupted = try mutation.apply(to: Data(contentsOf: fileURL))
            try corrupted.write(to: fileURL, options: [.atomic])

            do {
                _ = try await RepresentationRecordStore.open(root: root)
                XCTFail("同 schema 的 record 语义损坏必须失败关闭: \(mutation.rawValue)")
            } catch let error as AkashicError {
                XCTAssertEqual(error, .invalidManifest)
            }
            XCTAssertEqual(try Data(contentsOf: fileURL), corrupted)
        }
    }

    func testOriginalStoreRejectsNoncanonicalRuntimeContentIDWithoutMutation_SEC_CASE_030()
        async throws
    {
        let root = try makeTemporaryDirectory("runtime-original-validation")
        let store = try await AkashicOriginalEncodedStore.open(root: root)
        let metadataBefore = try akashicManifestMetadataData(root: root)
        let data = Data("a".utf8)
        let canonical = ContentID(data: data).description
        let noncanonicalLength = canonical.replacingOccurrences(of: ":1", with: ":01")

        do {
            _ = try await store.commit(
                data: data,
                contentID: noncanonicalLength,
                namespace: "public:manifest-tests"
            )
            XCTFail("非规范内容标识不得进入 blob 索引或磁盘")
        } catch let error as AkashicError {
            XCTAssertEqual(error, .invalidIdentity)
        }

        let physicalID = await store.physicalID(
            contentID: noncanonicalLength,
            namespace: "public:manifest-tests"
        )
        XCTAssertNil(physicalID)
        XCTAssertEqual(try akashicManifestMetadataData(root: root), metadataBefore)
        XCTAssertTrue(try akashicEffectiveManifestEntries(root: root).isEmpty)
        XCTAssertTrue(try akashicManifestRecordFixtures(root: root).isEmpty)
        XCTAssertTrue(try akashicBlobPayloadURLs(root: root).isEmpty)
    }

    func testRecordStoreAcceptsFiniteWallClockRollback_HTTP_CONF_AGE_005() async throws {
        let root = try makeTemporaryDirectory("record-wall-clock-rollback")
        let store = try await RepresentationRecordStore.open(root: root)
        let record = makeRepresentationRecord(
            namespace: "public:clock-rollback",
            baseKeyDigest: "clock-base",
            variantKeyDigest: "clock-variant",
            requestTime: Date(timeIntervalSince1970: 100),
            responseTime: Date(timeIntervalSince1970: 99),
            contentID: "clock-content",
            payloadLength: 13
        )

        try await store.put(record)
        let reopened = try await RepresentationRecordStore.open(root: root)
        let records = await reopened.records(
            for: record.baseKeyDigest,
            namespace: "public:clock-rollback",
            namespaceGeneration: 0
        )
        XCTAssertEqual(records, [record])
    }

    func testRecordStoreRejectsInvalidRuntimeRecordWithoutMutation_SEC_CASE_030() async throws {
        let root = try makeTemporaryDirectory("runtime-record-validation")
        let store = try await RepresentationRecordStore.open(root: root)
        let invalid = RepresentationRecord(
            securityNamespace: "public:manifest-tests",
            namespaceGeneration: 0,
            baseKeyDigest: "not-a-digest",
            variantKeyDigest: "also-not-a-digest",
            statusCode: 200,
            requestTime: Date(timeIntervalSince1970: 10),
            responseTime: Date(timeIntervalSince1970: 11),
            responseDate: nil,
            expiresAt: nil,
            etag: nil,
            lastModified: nil,
            disposition: .reusable,
            contentID: "invalid",
            payloadLength: -1,
            contentType: "image/png"
        )

        do {
            try await store.put(invalid)
            XCTFail("运行期非法 record 不得进入内存索引或磁盘")
        } catch let error as AkashicError {
            XCTAssertEqual(error, .invalidManifest)
        }
        let retained = await store.record(for: invalid.variantKeyDigest)
        XCTAssertNil(retained)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("representation-records.json").path
            )
        )
    }
}

private func forceAkashicManifestSnapshotCheckpoint(
    _ store: AkashicOriginalEncodedStore
) async throws {
    let namespace = "public:manifest-checkpoint-\(UUID().uuidString)"
    let marker = Data("manifest-checkpoint".utf8)
    _ = try await store.commit(
        data: marker,
        contentID: ContentID(data: marker).description,
        namespace: namespace
    )
    try await store.removeAll(namespace: namespace)
}

private struct OriginalManifestMutationWrite {
    let url: URL
    let xattrName: String?
    let data: Data
}

private enum OriginalManifestMutation: String, CaseIterable {
    case mismatchedKey
    case negativeByteCount
    case duplicatePhysicalID

    func applyToSnapshot(_ data: Data) throws -> Data {
        var root = try jsonObject(data)
        if var compact = root["e"] as? [[String: Any]] {
            guard compact.count == 2,
                (root["schemaVersion"] as? NSNumber)?.intValue == 4
            else { throw ManifestFixtureError.invalidFixture }
            switch self {
            case .mismatchedKey:
                compact.reverse()
                root["e"] = compact
                try resealAkashicDirectoryHeadSnapshotFixture(&root)
            case .negativeByteCount:
                compact[0]["n"] = -1
                root["e"] = compact
            case .duplicatePhysicalID:
                guard let physicalID = compact[0]["u"] else {
                    throw ManifestFixtureError.invalidFixture
                }
                compact[1]["u"] = physicalID
                root["e"] = compact
                try resealAkashicDirectoryHeadSnapshotFixture(&root)
            }
            return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        }

        var entries = try dictionary(root["entries"])
        let keys = entries.keys.sorted()
        guard keys.count == 2 else { throw ManifestFixtureError.invalidFixture }

        switch self {
        case .mismatchedKey:
            let value = entries.removeValue(forKey: keys[0])
            entries[String(repeating: "0", count: 64)] = value
        case .negativeByteCount:
            var entry = try dictionary(entries[keys[0]])
            entry["byteCount"] = -1
            entries[keys[0]] = entry
        case .duplicatePhysicalID:
            let first = try dictionary(entries[keys[0]])
            var second = try dictionary(entries[keys[1]])
            second["physicalID"] = first["physicalID"]
            entries[keys[1]] = second
        }
        root["entries"] = entries
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    func apply(
        to fixtures: [AkashicManifestRecordFixture]
    ) throws -> [OriginalManifestMutationWrite] {
        guard fixtures.count == 2 else { throw ManifestFixtureError.invalidFixture }
        var first = fixtures[0]
        var second = fixtures[1]

        switch self {
        case .mismatchedKey:
            try first.setEmbeddedManifestKey(String(repeating: "0", count: 64))
            return try [write(for: first)]
        case .negativeByteCount:
            guard var entry = try first.entryObject() else {
                throw ManifestFixtureError.invalidFixture
            }
            first.setEntryByteCount(-1, in: &entry)
            first.setEntryObject(entry)
            return try [write(for: first)]
        case .duplicatePhysicalID:
            guard let firstEntry = try first.entryObject(),
                var secondEntry = try second.entryObject()
            else { throw ManifestFixtureError.invalidFixture }
            let physicalID = try first.entryPhysicalID(firstEntry)
            second.setEntryPhysicalID(physicalID, in: &secondEntry)
            second.setEntryObject(secondEntry)
            return try [write(for: second)]
        }
    }

    private func write(
        for fixture: AkashicManifestRecordFixture
    ) throws -> OriginalManifestMutationWrite {
        try OriginalManifestMutationWrite(
            url: fixture.url,
            xattrName: fixture.xattrName,
            data: JSONSerialization.data(
                withJSONObject: fixture.object,
                options: [.sortedKeys]
            )
        )
    }
}

private enum RepresentationManifestMutation: String, CaseIterable {
    case mismatchedKey
    case payloadLengthMismatch
    case nonCanonicalDigest

    func apply(to data: Data) throws -> Data {
        var root = try jsonObject(data)
        var records = try dictionary(root["records"])
        guard let key = records.keys.first else { throw ManifestFixtureError.invalidFixture }
        var record = try dictionary(records[key])

        switch self {
        case .mismatchedKey:
            records.removeValue(forKey: key)
            records[String(repeating: "0", count: 64)] = record
        case .payloadLengthMismatch:
            record["payloadLength"] = 15
            records[key] = record
        case .nonCanonicalDigest:
            record["baseKeyDigest"] = String(repeating: "A", count: 64)
            records[key] = record
        }
        root["records"] = records
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}

private enum ManifestFixtureError: Error {
    case invalidFixture
}

private func manifestKey(partitionBytes: Data, digest: String) -> String {
    var keyMaterial = Data("akashic-file-blob-key-v1\u{0}".utf8)
    keyMaterial.append(partitionBytes)
    keyMaterial.append(0)
    keyMaterial.append(Data(digest.utf8))
    return SHA256.hash(data: keyMaterial)
        .map { String(format: "%02x", $0) }
        .joined()
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try dictionary(JSONSerialization.jsonObject(with: data))
}

private func dictionary(_ value: Any?) throws -> [String: Any] {
    guard let dictionary = value as? [String: Any] else {
        throw ManifestFixtureError.invalidFixture
    }
    return dictionary
}
