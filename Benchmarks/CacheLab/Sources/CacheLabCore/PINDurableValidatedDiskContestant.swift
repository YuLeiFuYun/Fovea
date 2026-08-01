import AkashicCore
import Darwin
import Foundation
import PINCacheBridge

/// 为 PINDiskCache 墠加内容校验与耐久可见性证明的基准兼容层。
///
/// 该类型不修改 PINCache 源码，也不把这些语义归因于 PINCache 原生实现。写入顺序为：
/// 1. 使用 PINDiskCache 写入对象；
/// 2. `fsync` PIN 数据文件及其父目录；
/// 3. 通过 PIN API 回读并核对内容摘要；
/// 4. 在独立目录耐久发布 proof 文件。
///
/// 读取只有在 proof 存在、proof 与 key 一致且回读摘要匹配时才可见。进程在任一步骤中止时，
/// 未发布 proof 的 PIN 对象只会成为不可见残留，不会被本兼容层作为命中返回。
public final class PINDurableValidatedDiskContestant: DiskCacheContestant, @unchecked Sendable {
    public let name = "PINDiskCacheDurableValidated"
    public let root: URL

    private let cacheName: String
    private let bridge: CacheLabPINDiskBridge
    private let proofDirectory: URL
    private let lock = NSLock()

    public init(root: URL, cacheName: String = "FoveaCacheLabPINDurable") throws {
        self.root = root
        self.cacheName = cacheName
        bridge = CacheLabPINDiskBridge(rootPath: root.path, name: cacheName)
        proofDirectory = root.appendingPathComponent(
            ".fovea-durable-validation-v1", isDirectory: true)
        try DurableValidationFiles.ensureDirectory(proofDirectory)
    }

    public func value(for key: String) async throws -> Data? {
        lock.withLock {
            let proofURL = proofURL(for: key)
            guard let proofData = try? Data(contentsOf: proofURL),
                let proof = try? JSONDecoder().decode(ValidationProof.self, from: proofData),
                proof.schemaVersion == 1,
                proof.contentID == key,
                let dataURL = bridge.fileURL(forKey: key),
                dataURL.lastPathComponent == proof.dataFileName,
                let serialized = try? Data(contentsOf: dataURL),
                cacheContentID(for: serialized) == proof.serializedContentID,
                let value = bridge.data(forKey: key),
                cacheContentID(for: value) == key
            else {
                return nil
            }
            return value
        }
    }

    public func insert(_ value: Data, for key: String) async throws {
        try lock.withLock {
            guard cacheContentID(for: value) == key else { throw CacheLabError.corruptValue }
            bridge.setData(value, forKey: key)
            guard let dataURL = bridge.fileURL(forKey: key) else {
                bridge.removeData(forKey: key)
                throw CacheLabError.unsupportedOperation
            }
            do {
                try DurableValidationFiles.synchronizeFileAndParent(dataURL)
                let serialized = try Data(contentsOf: dataURL)
                guard let loaded = bridge.data(forKey: key),
                    loaded == value,
                    cacheContentID(for: loaded) == key
                else {
                    throw CacheLabError.corruptValue
                }
                let proof = ValidationProof(
                    schemaVersion: 1,
                    contentID: key,
                    dataFileName: dataURL.lastPathComponent,
                    serializedContentID: cacheContentID(for: serialized)
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                try DurableValidationFiles.writeReplacing(
                    encoder.encode(proof),
                    to: proofURL(for: key)
                )
            } catch {
                bridge.removeData(forKey: key)
                try? DurableValidationFiles.removeIfPresent(proofURL(for: key))
                throw error
            }
        }
    }

    public func removeValue(for key: String) async throws {
        try lock.withLock {
            try DurableValidationFiles.removeIfPresent(proofURL(for: key))
            bridge.removeData(forKey: key)
        }
    }

    public func removeAll() async throws {
        try lock.withLock {
            try DurableValidationFiles.replaceDirectory(proofDirectory)
            bridge.removeAllData()
        }
    }

    public func fileURL(for key: String) async throws -> URL? {
        lock.withLock { bridge.fileURL(forKey: key) }
    }

    public func readExceptionCount() async -> Int {
        lock.withLock { Int(bridge.readExceptionCount) }
    }

    public func reopen() async throws -> any DiskCacheContestant {
        try PINDurableValidatedDiskContestant(root: root, cacheName: cacheName)
    }

    private func proofURL(for key: String) -> URL {
        proofDirectory.appendingPathComponent("\(key).proof", isDirectory: false)
    }
}

private struct ValidationProof: Codable, Sendable {
    let schemaVersion: Int
    let contentID: String
    let dataFileName: String
    let serializedContentID: String
}

private enum DurableValidationFiles {
    static func ensureDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            let parent = directory.deletingLastPathComponent()
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try synchronizeDirectory(parent)
        }
        try synchronizeDirectory(directory)
    }

    static func replaceDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        let parent = directory.deletingLastPathComponent()
        if manager.fileExists(atPath: directory.path) {
            try manager.removeItem(at: directory)
            try synchronizeDirectory(parent)
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try synchronizeDirectory(parent)
        try synchronizeDirectory(directory)
    }

    static func synchronizeFileAndParent(_ file: URL) throws {
        try synchronizeFile(file)
        try synchronizeDirectory(file.deletingLastPathComponent())
    }

    static func writeReplacing(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try ensureDirectory(directory)
        let temporary = directory.appendingPathComponent(
            ".proof-tmp-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posixError() }
        var isOpen = true
        do {
            try writeAll(data, descriptor: descriptor)
            guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
            guard Darwin.close(descriptor) == 0 else { throw posixError() }
            isOpen = false
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw posixError()
            }
            try synchronizeDirectory(directory)
        } catch {
            if isOpen { _ = Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func removeIfPresent(_ file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
        try synchronizeDirectory(file.deletingLastPathComponent())
    }

    private static func synchronizeFile(_ file: URL) throws {
        let descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    bytes.count - written
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard result > 0 else { throw POSIXError(.EIO) }
                written += result
            }
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
