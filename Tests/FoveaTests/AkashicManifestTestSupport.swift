import CryptoKit
import Darwin
import Foundation

/// 测试层对 Akashic 清单记录的物理视图；仅用于构造损坏与故障注入夹具。
struct AkashicManifestRecordFixture {
    let url: URL
    let xattrName: String?
    var object: [String: Any]

    init(url: URL, xattrName: String? = nil, object: [String: Any]) {
        self.url = url
        self.xattrName = xattrName
        self.object = object
    }

    var isCompact: Bool { object["v"] != nil }

    var generation: UInt64? {
        (object[isCompact ? "g" : "generation"] as? NSNumber)?.uint64Value
    }

    var sequence: UInt64 {
        (object[isCompact ? "s" : "sequence"] as? NSNumber)?.uint64Value ?? 0
    }

    var fileManifestKey: String? {
        carrierIdentity?.key
    }

    var carrierGeneration: UInt64? {
        carrierIdentity?.generation
    }

    private var carrierIdentity: (generation: UInt64?, key: String)? {
        if let xattrName {
            let prefix = "dev.akashic.manifest-entry-v1.g"
            guard xattrName.hasPrefix(prefix) else { return nil }
            let body = String(xattrName.dropFirst(prefix.count))
            let parts = body.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2,
                parts[0].count == 16,
                parts[1].count == 64,
                parts[0].allSatisfy(akashicIsLowercaseHex),
                parts[1].allSatisfy(akashicIsLowercaseHex),
                let generation = UInt64(String(parts[0]), radix: 16),
                generation > 0
            else { return nil }
            return (generation, String(parts[1]))
        }

        let name = url.lastPathComponent
        let prefix = ".manifest-entry-"
        let suffix = ".json"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        let body = String(name[start..<end])
        if body.count == 64, body.allSatisfy(akashicIsLowercaseHex) {
            return (nil, body)
        }
        let bytes = Array(body.utf8)
        guard bytes.count == 82,
            bytes[0] == 103,
            bytes[17] == 45
        else { return nil }
        let generationString = String(decoding: bytes[1..<17], as: UTF8.self)
        let key = String(decoding: bytes[18..<82], as: UTF8.self)
        guard generationString.allSatisfy(akashicIsLowercaseHex),
            key.allSatisfy(akashicIsLowercaseHex),
            let generation = UInt64(generationString, radix: 16),
            generation > 0
        else { return nil }
        return (generation, key)
    }

    func retargetedCarrier(forManifestKey key: String) throws -> (url: URL, xattrName: String?) {
        guard key.count == 64, key.allSatisfy(akashicIsLowercaseHex),
            let identity = carrierIdentity
        else { throw AkashicManifestFixtureError.invalidFixture }
        if xattrName != nil {
            guard let generation = identity.generation else {
                throw AkashicManifestFixtureError.invalidFixture
            }
            return (
                url,
                "dev.akashic.manifest-entry-v1.g\(String(format: "%016llx", generation)).\(key)"
            )
        }
        if let generation = identity.generation {
            return (
                url.deletingLastPathComponent().appendingPathComponent(
                    ".manifest-entry-g\(String(format: "%016llx", generation))-\(key).json"
                ),
                nil
            )
        }
        return (
            url.deletingLastPathComponent().appendingPathComponent(".manifest-entry-\(key).json"),
            nil
        )
    }

    func embeddedManifestKey() throws -> String? {
        if isCompact {
            guard let value = object["k"] else { return nil }
            guard let encoded = value as? String,
                let bytes = Data(base64Encoded: encoded),
                bytes.count == 32
            else { throw AkashicManifestFixtureError.invalidFixture }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        guard let value = object["key"] else { return nil }
        guard let key = value as? String else {
            throw AkashicManifestFixtureError.invalidFixture
        }
        return key
    }

    mutating func setEmbeddedManifestKey(_ key: String) throws {
        if isCompact {
            guard let bytes = akashicHexData(key), bytes.count == 32 else {
                throw AkashicManifestFixtureError.invalidFixture
            }
            object["k"] = bytes.base64EncodedString()
        } else {
            object["key"] = key
        }
    }

    func entryObject() throws -> [String: Any]? {
        let field = isCompact ? "e" : "entry"
        guard let value = object[field], !(value is NSNull) else { return nil }
        guard let entry = value as? [String: Any] else {
            throw AkashicManifestFixtureError.invalidFixture
        }
        return entry
    }

    mutating func setEntryObject(_ entry: [String: Any]) {
        object[isCompact ? "e" : "entry"] = entry
    }

    func entryPartitionBytes(_ entry: [String: Any]) throws -> Data {
        if isCompact {
            guard let value = entry["p"] as? String,
                let bytes = Data(base64Encoded: value),
                bytes.count == 32
            else { throw AkashicManifestFixtureError.invalidFixture }
            return bytes
        }
        let partition = try akashicJSONDictionary(entry["partition"])
        guard let value = partition["value"] as? String,
            let bytes = Data(base64Encoded: value),
            bytes.count == 32
        else { throw AkashicManifestFixtureError.invalidFixture }
        return bytes
    }

    func entryPhysicalID(_ entry: [String: Any]) throws -> Any {
        let field = isCompact ? "u" : "physicalID"
        guard let value = entry[field] else {
            throw AkashicManifestFixtureError.invalidFixture
        }
        return value
    }

    func setEntryByteCount(_ value: Int, in entry: inout [String: Any]) {
        entry[isCompact ? "n" : "byteCount"] = value
    }

    func setEntryDigestBytes(
        _ bytes: Data,
        byteCount: Int,
        in entry: inout [String: Any]
    ) {
        if isCompact {
            entry["h"] = bytes.base64EncodedString()
            entry["n"] = byteCount
        } else {
            let digestHex = bytes.map { String(format: "%02x", $0) }.joined()
            entry["digest"] = ["canonical": "sha256:\(digestHex):\(byteCount)"]
            entry["byteCount"] = byteCount
        }
    }

    func setEntryPhysicalID(_ value: Any, in entry: inout [String: Any]) {
        entry[isCompact ? "u" : "physicalID"] = value
    }

    func normalizedEntryObject() throws -> [String: Any]? {
        guard let entry = try entryObject() else { return nil }
        guard isCompact else { return entry }
        guard let physicalID = entry["u"] as? String,
            let partitionValue = entry["p"] as? String,
            let partitionBytes = Data(base64Encoded: partitionValue),
            partitionBytes.count == 32,
            let digestValue = entry["h"] as? String,
            let digestBytes = Data(base64Encoded: digestValue),
            digestBytes.count == 32,
            let byteCount = (entry["n"] as? NSNumber)?.intValue,
            let lastAccess = (entry["t"] as? NSNumber)?.doubleValue
        else { throw AkashicManifestFixtureError.invalidFixture }
        let digestHex = digestBytes.map { String(format: "%02x", $0) }.joined()
        return [
            "physicalID": physicalID,
            "partition": ["value": partitionBytes.base64EncodedString()],
            "digest": ["canonical": "sha256:\(digestHex):\(byteCount)"],
            "byteCount": byteCount,
            "lastAccess": lastAccess,
        ]
    }
}

enum AkashicManifestFixtureError: Error {
    case invalidFixture
}

/// 返回所有当前可见的 manifest 增量载体：sidecar 记录与 payload xattr。
func akashicManifestRecordFixtures(root: URL) throws -> [AkashicManifestRecordFixture] {
    let blobs = root.appendingPathComponent("blobs", isDirectory: true)
    guard FileManager.default.fileExists(atPath: blobs.path) else { return [] }
    let children = try FileManager.default.contentsOfDirectory(
        at: blobs,
        includingPropertiesForKeys: nil
    )
    var fixtures = try children.filter {
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

    for url in children where !url.lastPathComponent.hasPrefix(".") {
        for name in try akashicExtendedAttributeNames(at: url)
        where name.hasPrefix("dev.akashic.manifest-entry-") {
            let data = try akashicExtendedAttributeData(name, at: url)
            fixtures.append(
                try AkashicManifestRecordFixture(
                    url: url,
                    xattrName: name,
                    object: akashicJSONDictionary(
                        JSONSerialization.jsonObject(with: data)
                    )
                )
            )
        }
    }

    return fixtures.sorted { lhs, rhs in
        if lhs.sequence == rhs.sequence {
            let lhsCarrier = lhs.url.lastPathComponent + (lhs.xattrName ?? "")
            let rhsCarrier = rhs.url.lastPathComponent + (rhs.xattrName ?? "")
            return lhsCarrier < rhsCarrier
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
            try akashicManifestFixtureData($0)
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
    var entries = try akashicManifestSnapshotEntries(snapshot)
    guard let generation = (snapshot["generation"] as? NSNumber)?.uint64Value else {
        return entries
    }

    for fixture in try akashicManifestRecordFixtures(root: root) {
        if let carrierGeneration = fixture.carrierGeneration {
            if carrierGeneration < generation { continue }
            guard carrierGeneration == generation else {
                throw AkashicManifestFixtureError.invalidFixture
            }
        }
        guard let recordGeneration = fixture.generation else {
            throw AkashicManifestFixtureError.invalidFixture
        }
        if recordGeneration < generation { continue }
        guard recordGeneration == generation,
            let key = fixture.fileManifestKey
        else { throw AkashicManifestFixtureError.invalidFixture }
        if let embeddedKey = try fixture.embeddedManifestKey(), embeddedKey != key {
            throw AkashicManifestFixtureError.invalidFixture
        }
        if let entry = try fixture.normalizedEntryObject() {
            entries[key] = entry
        } else {
            entries.removeValue(forKey: key)
        }
    }
    return entries
}

/// 返回下一次单 key tombstone 发布会使用的可阻断目标。
func akashicSingleEntryMetadataURL(root: URL) throws -> URL {
    let snapshot = root.appendingPathComponent("manifest.json")
    guard FileManager.default.fileExists(atPath: snapshot.path) else {
        throw AkashicManifestFixtureError.invalidFixture
    }
    let object = try akashicJSONDictionary(
        JSONSerialization.jsonObject(with: Data(contentsOf: snapshot))
    )
    let schema = (object["schemaVersion"] as? NSNumber)?.intValue ?? 0
    if schema >= 3 {
        guard let generation = (object["generation"] as? NSNumber)?.uint64Value,
            generation > 0,
            let key = try akashicEffectiveManifestEntries(root: root).keys.singleElement
        else { throw AkashicManifestFixtureError.invalidFixture }
        return akashicManifestRecordURL(root: root, generation: generation, key: key)
    }
    let records = try akashicManifestRecordFixtures(root: root)
    return records.singleElement?.url ?? snapshot
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

func akashicManifestSnapshotEntries(_ snapshot: [String: Any]) throws -> [String: Any] {
    if let entries = snapshot["entries"] as? [String: Any] { return entries }
    guard let compactEntries = snapshot["e"] as? [[String: Any]] else {
        throw AkashicManifestFixtureError.invalidFixture
    }
    var result: [String: Any] = [:]
    for compact in compactEntries {
        let normalized = try akashicNormalizedCompactManifestEntry(compact)
        let partition = try akashicJSONDictionary(normalized["partition"])
        let digest = try akashicJSONDictionary(normalized["digest"])
        guard let partitionValue = partition["value"] as? String,
            let partitionBytes = Data(base64Encoded: partitionValue),
            let canonicalDigest = digest["canonical"] as? String
        else { throw AkashicManifestFixtureError.invalidFixture }
        let key = akashicManifestKeyFixture(
            partitionBytes: partitionBytes,
            canonicalDigest: canonicalDigest
        )
        guard result.updateValue(normalized, forKey: key) == nil else {
            throw AkashicManifestFixtureError.invalidFixture
        }
    }
    return result
}

private func akashicNormalizedCompactManifestEntry(
    _ entry: [String: Any]
) throws -> [String: Any] {
    guard let physicalID = entry["u"] as? String,
        UUID(uuidString: physicalID) != nil,
        let partitionValue = entry["p"] as? String,
        let partitionBytes = Data(base64Encoded: partitionValue),
        partitionBytes.count == 32,
        let digestValue = entry["h"] as? String,
        let digestBytes = Data(base64Encoded: digestValue),
        digestBytes.count == 32,
        let byteCountValue = entry["n"] as? NSNumber,
        byteCountValue.int64Value >= 0,
        byteCountValue.uint64Value <= UInt64(Int.max),
        let lastAccess = (entry["t"] as? NSNumber)?.doubleValue,
        lastAccess.isFinite
    else { throw AkashicManifestFixtureError.invalidFixture }
    let byteCount = Int(byteCountValue.uint64Value)
    let digestHex = digestBytes.map { String(format: "%02x", $0) }.joined()
    return [
        "physicalID": physicalID,
        "partition": ["value": partitionBytes.base64EncodedString()],
        "digest": ["canonical": "sha256:\(digestHex):\(byteCount)"],
        "byteCount": byteCount,
        "lastAccess": lastAccess,
    ]
}

private func akashicManifestKeyFixture(
    partitionBytes: Data,
    canonicalDigest: String
) -> String {
    var material = Data("akashic-file-blob-key-v1\u{0}".utf8)
    material.append(partitionBytes)
    material.append(0)
    material.append(Data(canonicalDigest.utf8))
    return SHA256.hash(data: material)
        .map { String(format: "%02x", $0) }
        .joined()
}

func resealAkashicDirectoryHeadSnapshotFixture(_ snapshot: inout [String: Any]) throws {
    guard (snapshot["schemaVersion"] as? NSNumber)?.intValue == 4,
        let generation = (snapshot["generation"] as? NSNumber)?.uint64Value,
        generation > 0,
        snapshot["d"] as? String == "directory-head-v2",
        let compactEntries = snapshot["e"] as? [[String: Any]],
        let entryCount = UInt32(exactly: compactEntries.count)
    else { throw AkashicManifestFixtureError.invalidFixture }

    var transcript = Data("akashic-directory-head-snapshot-v2\u{0}".utf8)
    akashicAppendBigEndian(UInt16(4), to: &transcript)
    akashicAppendBigEndian(generation, to: &transcript)
    akashicAppendLengthPrefixed(Data("directory-head-v2".utf8), to: &transcript)
    akashicAppendBigEndian(entryCount, to: &transcript)

    for entry in compactEntries {
        guard let physicalIDValue = entry["u"] as? String,
            let physicalID = UUID(uuidString: physicalIDValue),
            let partitionValue = entry["p"] as? String,
            let partition = Data(base64Encoded: partitionValue),
            let digestValue = entry["h"] as? String,
            let digest = Data(base64Encoded: digestValue),
            let byteCountValue = entry["n"] as? NSNumber,
            byteCountValue.int64Value >= 0,
            let lastAccess = (entry["t"] as? NSNumber)?.doubleValue,
            lastAccess.isFinite
        else { throw AkashicManifestFixtureError.invalidFixture }
        akashicAppendLengthPrefixed(
            Data(physicalID.uuidString.lowercased().utf8),
            to: &transcript
        )
        akashicAppendLengthPrefixed(partition, to: &transcript)
        akashicAppendLengthPrefixed(digest, to: &transcript)
        akashicAppendBigEndian(byteCountValue.uint64Value, to: &transcript)
        akashicAppendBigEndian(lastAccess.bitPattern, to: &transcript)
    }
    snapshot["x"] = Data(SHA256.hash(data: transcript)).base64EncodedString()
}

private func akashicAppendLengthPrefixed(_ value: Data, to data: inout Data) {
    akashicAppendBigEndian(UInt32(value.count), to: &data)
    data.append(value)
}

private func akashicAppendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

func akashicManifestRecordURL(root: URL, key: String) -> URL {
    root.appendingPathComponent("blobs", isDirectory: true)
        .appendingPathComponent(".manifest-entry-\(key).json")
}

func akashicManifestRecordURL(root: URL, generation: UInt64, key: String) -> URL {
    root.appendingPathComponent("blobs", isDirectory: true)
        .appendingPathComponent(
            ".manifest-entry-g\(String(format: "%016llx", generation))-\(key).json"
        )
}

private func akashicIsLowercaseHex(_ character: Character) -> Bool {
    switch character {
    case "0"..."9", "a"..."f": true
    default: false
    }
}

func akashicHexData(_ value: String) -> Data? {
    let bytes = Array(value.utf8)
    guard bytes.count.isMultiple(of: 2) else { return nil }
    var result = Data(capacity: bytes.count / 2)
    for offset in stride(from: 0, to: bytes.count, by: 2) {
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: byte - 48
            case 97...102: byte - 87
            default: nil
            }
        }
        guard let high = nibble(bytes[offset]), let low = nibble(bytes[offset + 1]) else {
            return nil
        }
        result.append((high << 4) | low)
    }
    return result
}

func akashicJSONDictionary(_ value: Any?) throws -> [String: Any] {
    guard let value = value as? [String: Any] else {
        throw AkashicManifestFixtureError.invalidFixture
    }
    return value
}

func akashicManifestFixtureData(_ fixture: AkashicManifestRecordFixture) throws -> Data {
    if let xattrName = fixture.xattrName {
        return try akashicExtendedAttributeData(xattrName, at: fixture.url)
    }
    return try Data(contentsOf: fixture.url)
}

func akashicManifestFixtureData(
    at url: URL,
    xattrName: String?
) throws -> Data {
    if let xattrName {
        return try akashicExtendedAttributeData(xattrName, at: url)
    }
    return try Data(contentsOf: url)
}

func removeAkashicManifestFixture(
    at url: URL,
    xattrName: String?
) throws {
    guard let xattrName else {
        try FileManager.default.removeItem(at: url)
        return
    }
    let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { _ = Darwin.close(descriptor) }
    let result = xattrName.withCString { Darwin.fremovexattr(descriptor, $0, 0) }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard Darwin.fsync(descriptor) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// 写入测试夹具后恢复 Akashic 接受的私有文件权限，确保测试命中目标语义而非权限门。
func writeAkashicManifestFixture(
    _ data: Data,
    to url: URL,
    xattrName: String? = nil
) throws {
    if let xattrName {
        let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }
        let result = xattrName.withCString { pointer in
            data.withUnsafeBytes { bytes in
                Darwin.fsetxattr(
                    descriptor,
                    pointer,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                )
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return
    }
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: url.path
    )
}

private func akashicExtendedAttributeNames(at url: URL) throws -> [String] {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { _ = Darwin.close(descriptor) }
    let required = Darwin.flistxattr(descriptor, nil, 0, 0)
    guard required >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard required > 0 else { return [] }
    guard required <= 64 * 1_024 else { throw AkashicManifestFixtureError.invalidFixture }
    var buffer = [CChar](repeating: 0, count: required)
    let actual = buffer.withUnsafeMutableBufferPointer { pointer in
        Darwin.flistxattr(descriptor, pointer.baseAddress, pointer.count, 0)
    }
    guard actual == required else { throw AkashicManifestFixtureError.invalidFixture }
    var names: [String] = []
    var start = 0
    for index in 0..<actual where buffer[index] == 0 {
        if index > start {
            let bytes = buffer[start..<index].map { UInt8(bitPattern: $0) }
            names.append(String(decoding: bytes, as: UTF8.self))
        }
        start = index + 1
    }
    return names
}

private func akashicExtendedAttributeData(_ name: String, at url: URL) throws -> Data {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { _ = Darwin.close(descriptor) }
    let required = name.withCString { pointer in
        Darwin.fgetxattr(descriptor, pointer, nil, 0, 0, 0)
    }
    guard required >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard required <= 16 * 1_024 else { throw AkashicManifestFixtureError.invalidFixture }
    var data = Data(count: required)
    let actual = try data.withUnsafeMutableBytes { bytes -> Int in
        let result = name.withCString { pointer in
            Darwin.fgetxattr(
                descriptor,
                pointer,
                bytes.baseAddress,
                bytes.count,
                0,
                0
            )
        }
        guard result >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return result
    }
    guard actual == required else { throw AkashicManifestFixtureError.invalidFixture }
    return data
}
