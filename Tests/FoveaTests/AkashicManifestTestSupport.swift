import Foundation

/// 测试层对 Akashic 清单记录的物理视图；仅用于构造损坏与故障注入夹具。
struct AkashicManifestRecordFixture {
    let url: URL
    var object: [String: Any]

    var sequence: UInt64 {
        (object["sequence"] as? NSNumber)?.uint64Value ?? 0
    }
}

enum AkashicManifestFixtureError: Error {
    case invalidFixture
}

/// 返回 schema 2 单 key 增量记录；schema 1 存储返回空数组。
func akashicManifestRecordFixtures(root: URL) throws -> [AkashicManifestRecordFixture] {
    let blobs = root.appendingPathComponent("blobs", isDirectory: true)
    guard FileManager.default.fileExists(atPath: blobs.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
        at: blobs,
        includingPropertiesForKeys: nil
    )
    .filter {
        $0.lastPathComponent.hasPrefix(".manifest-entry-")
            && $0.pathExtension == "json"
    }
    .map { url in
        try AkashicManifestRecordFixture(
            url: url,
            object: akashicJSONDictionary(
                JSONSerialization.jsonObject(with: Data(contentsOf: url))
            )
        )
    }
    .sorted { lhs, rhs in
        if lhs.sequence == rhs.sequence {
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }
        return lhs.sequence < rhs.sequence
    }
}

/// 只返回正文 blob，不把 schema 2 隐藏增量记录或临时文件计作 payload。
func akashicBlobPayloadURLs(root: URL) throws -> [URL] {
    let blobs = root.appendingPathComponent("blobs", isDirectory: true)
    guard FileManager.default.fileExists(atPath: blobs.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
        at: blobs,
        includingPropertiesForKeys: nil
    )
    .filter { !$0.lastPathComponent.hasPrefix(".") }
}

/// 返回检查点与所有增量记录的原始数据，用于敏感信息泄漏断言。
func akashicManifestMetadataData(root: URL) throws -> [Data] {
    var result: [Data] = []
    let snapshot = root.appendingPathComponent("manifest.json")
    if FileManager.default.fileExists(atPath: snapshot.path) {
        try result.append(Data(contentsOf: snapshot))
    }
    try result.append(
        contentsOf: akashicManifestRecordFixtures(root: root).map {
            try Data(contentsOf: $0.url)
        }
    )
    return result
}

/// 将 schema 1 快照或 schema 2「检查点 + 同 generation 增量记录」折叠为有效 entries。
func akashicEffectiveManifestEntries(root: URL) throws -> [String: Any] {
    let snapshotURL = root.appendingPathComponent("manifest.json")
    guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return [:] }
    let snapshot = try akashicJSONDictionary(
        JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL))
    )
    var entries = try akashicJSONDictionary(snapshot["entries"])
    guard let generation = (snapshot["generation"] as? NSNumber)?.uint64Value else {
        return entries
    }

    for fixture in try akashicManifestRecordFixtures(root: root) {
        guard (fixture.object["generation"] as? NSNumber)?.uint64Value == generation,
            let key = fixture.object["key"] as? String
        else {
            throw AkashicManifestFixtureError.invalidFixture
        }
        if fixture.object["entry"] == nil || fixture.object["entry"] is NSNull {
            entries.removeValue(forKey: key)
        } else if let entry = fixture.object["entry"] as? [String: Any] {
            entries[key] = entry
        } else {
            throw AkashicManifestFixtureError.invalidFixture
        }
    }
    return entries
}

/// 返回单 key 元数据发布所使用的可阻断目标：schema 2 为增量记录，schema 1 为快照。
func akashicSingleEntryMetadataURL(root: URL) throws -> URL {
    let records = try akashicManifestRecordFixtures(root: root)
    if let record = records.singleElement {
        return record.url
    }
    let snapshot = root.appendingPathComponent("manifest.json")
    guard FileManager.default.fileExists(atPath: snapshot.path) else {
        throw AkashicManifestFixtureError.invalidFixture
    }
    return snapshot
}

/// 返回当前清单 schema；尚未发布任何元数据时返回 nil。
func akashicManifestSchemaVersion(root: URL) throws -> Int? {
    let snapshot = root.appendingPathComponent("manifest.json")
    guard FileManager.default.fileExists(atPath: snapshot.path) else { return nil }
    let object = try akashicJSONDictionary(
        JSONSerialization.jsonObject(with: Data(contentsOf: snapshot))
    )
    return (object["schemaVersion"] as? NSNumber)?.intValue
}

func akashicManifestRecordURL(root: URL, key: String) -> URL {
    root.appendingPathComponent("blobs", isDirectory: true)
        .appendingPathComponent(".manifest-entry-\(key).json")
}

func akashicJSONDictionary(_ value: Any?) throws -> [String: Any] {
    guard let value = value as? [String: Any] else {
        throw AkashicManifestFixtureError.invalidFixture
    }
    return value
}

/// 写入测试夹具后恢复 Akashic 接受的私有文件权限，确保测试命中目标语义而非权限门。
func writeAkashicManifestFixture(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: url.path
    )
}
