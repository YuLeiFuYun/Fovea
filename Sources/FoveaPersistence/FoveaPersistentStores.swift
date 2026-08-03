import AkashicCore
import AkashicDisk
import Darwin
import Foundation
import FoveaHTTP
import FoveaStorage

/// 持久化组合失败，例如活动存储限制不兼容。

public enum FoveaPersistenceError: Error, Equatable, Sendable {
    /// 另一个进程当前拥有该代际的写入租约。
    case writerAlreadyActive
    /// 同一活动代际已用不同存储或命名空间限制打开。
    case incompatibleActiveConfiguration
}

/// 协同管理编码字节与表征记录的存储代际。

public struct FoveaPersistentStores: Sendable {
    private static let rootExecutor = FoveaBlockingIOExecutor(
        label: "dev.fovea.persistence.root-preparation"
    )

    public static let currentCompatibilityFingerprint =
        "fovea-store-v2:akashic-file-\(AkashicOriginalEncodedStore.currentSchemaVersion):partition-1:representation-\(RepresentationRecord.currentSchemaVersion):namespace-generation-\(NamespaceGenerationStore.currentSchemaVersion)"

    /// 官方 Akashic bundle 的稳定 provider 身份。
    package static let defaultProviderIdentity = FoveaPersistentStoreProviderIdentity(
        validatedIdentifier: "dev.fovea.persistence.akashic",
        implementationVersion: 1,
        compatibilityFingerprint: currentCompatibilityFingerprint
    )

    /// 当前活动持久化代际。
    public let generation: StoreGenerationHandle
    /// 该代际的原始编码字节存储。
    public let encoded: any OriginalEncodedMaintaining & AnyObject
    /// 该代际的 HTTP 表征记录存储能力。
    ///
    /// 具体清单 actor 保持为实现细节，使未来持久化引擎
    /// 可以在不扩大稳定公共 API 的情况下替换它。
    public let records: any RepresentationRecordMaintaining
    /// 活动存储代际的持久命名空间撤销代际。
    package let namespaceGenerations: NamespaceGenerationStore

    /// 打开或复用兼容代际，并将写入租约绑定到返回的存储。
    public static func open(
        root: URL,
        compatibilityFingerprint: String = currentCompatibilityFingerprint,
        encodedSoftTotalBytes: Int = 128 * 1024 * 1024,
        maximumEncodedBlobBytes: Int = 64 * 1024 * 1024,
        maximumTrackedNamespaces: Int = 4_096
    ) async throws -> FoveaPersistentStores {
        try await rootExecutor.run {
            try prepareManagedRoot(root)
        }
        let generation = try await StoreGenerationDirectory.open(
            root: root,
            compatibilityFingerprint: compatibilityFingerprint
        )
        let bundle = try await PersistentStoreRegistry.shared.bundle(
            generation: generation,
            encodedLimits: OriginalEncodedStoreLimits(
                softTotalBytes: encodedSoftTotalBytes,
                maximumBlobBytes: maximumEncodedBlobBytes
            ),
            maximumTrackedNamespaces: maximumTrackedNamespaces
        )
        return FoveaPersistentStores(
            generation: bundle.generation,
            encoded: bundle.encoded,
            records: bundle.records,
            namespaceGenerations: bundle.namespaceGenerations
        )
    }

    package func qualifiedBundle() throws -> FoveaPersistentStoreBundle {
        try FoveaPersistentStoreBundle(
            providerIdentity: Self.defaultProviderIdentity,
            generation: generation.descriptor,
            encoded: encoded,
            records: records,
            namespaceGenerations: namespaceGenerations,
            lifetimeAnchor: self
        )
    }

    package static func registryEntryCountForTesting() async -> Int {
        await PersistentStoreRegistry.shared.entryCountForTesting()
    }

    /// Fovea API 接受调用方创建的专用缓存根；在交给 Akashic 前先验证身份并收紧权限。
    /// 符号链接、非目录和非当前用户对象必须失败，不能通过 chmod 修复身份错误。
    private static func prepareManagedRoot(_ root: URL) throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        var status = stat()
        let result = root.path.withCString { Darwin.lstat($0, &status) }
        guard result == 0,
            status.st_mode & S_IFMT == S_IFDIR,
            status.st_uid == Darwin.geteuid()
        else {
            throw AkashicError.storageUnavailable
        }
        guard Darwin.chmod(root.path, S_IRWXU) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FoveaManagedFileSecurity.prepareDirectory(root)
    }
}

private final class PersistentStoreLifetime: Sendable {
    let writerLease: StoreWriterLease

    init(writerLease: StoreWriterLease) {
        self.writerLease = writerLease
    }
}

private struct PersistentStoreConfiguration: Equatable, Sendable {
    let encodedLimits: OriginalEncodedStoreLimits
    let maximumTrackedNamespaces: Int
}

private final class PersistentStoreBundle: Sendable {
    let generation: StoreGenerationHandle
    let encoded: AkashicOriginalEncodedStore
    let records: RepresentationRecordStore
    let configuration: PersistentStoreConfiguration
    let namespaceGenerations: NamespaceGenerationStore
    let lifetime: PersistentStoreLifetime

    init(
        generation: StoreGenerationHandle,
        encoded: AkashicOriginalEncodedStore,
        records: RepresentationRecordStore,
        configuration: PersistentStoreConfiguration,
        namespaceGenerations: NamespaceGenerationStore,
        lifetime: PersistentStoreLifetime
    ) {
        self.generation = generation
        self.encoded = encoded
        self.records = records
        self.configuration = configuration
        self.namespaceGenerations = namespaceGenerations
        self.lifetime = lifetime
    }
}

private final class WeakPersistentStoreBundle {
    let generation: StoreGenerationHandle
    let configuration: PersistentStoreConfiguration
    weak let encoded: AkashicOriginalEncodedStore?
    weak let records: RepresentationRecordStore?
    weak let namespaceGenerations: NamespaceGenerationStore?
    weak let lifetime: PersistentStoreLifetime?

    init(_ bundle: PersistentStoreBundle) {
        self.generation = bundle.generation
        self.configuration = bundle.configuration
        self.encoded = bundle.encoded
        self.records = bundle.records
        self.namespaceGenerations = bundle.namespaceGenerations
        self.lifetime = bundle.lifetime
    }

    var isAlive: Bool {
        encoded != nil && records != nil && namespaceGenerations != nil && lifetime != nil
    }

    func retainedBundle() -> PersistentStoreBundle? {
        guard let encoded, let records, let namespaceGenerations, let lifetime else { return nil }
        return PersistentStoreBundle(
            generation: generation,
            encoded: encoded,
            records: records,
            configuration: configuration,
            namespaceGenerations: namespaceGenerations,
            lifetime: lifetime
        )
    }
}

private actor PersistentStoreRegistry {
    static let shared = PersistentStoreRegistry()

    private nonisolated let ioExecutor = FoveaBlockingIOExecutor(
        label: "dev.fovea.persistence.store-registry"
    )

    private enum Entry {
        case opening(
            configuration: PersistentStoreConfiguration,
            task: Task<PersistentStoreBundle, any Error>
        )
        case ready(WeakPersistentStoreBundle)
    }

    private var entries: [String: Entry] = [:]

    func bundle(
        generation: StoreGenerationHandle,
        encodedLimits: OriginalEncodedStoreLimits,
        maximumTrackedNamespaces: Int
    ) async throws -> PersistentStoreBundle {
        pruneReleasedEntries()
        let configuration = PersistentStoreConfiguration(
            encodedLimits: encodedLimits,
            maximumTrackedNamespaces: min(1_000_000, max(1, maximumTrackedNamespaces))
        )
        let generationRoot = generation.root
        let key = try await ioExecutor.run {
            generationRoot.standardizedFileURL.resolvingSymlinksInPath().path
        }
        if let existing = entries[key] {
            switch existing {
            case .ready(let reference):
                if let bundle = reference.retainedBundle() {
                    guard reference.configuration == configuration else {
                        throw FoveaPersistenceError.incompatibleActiveConfiguration
                    }
                    return bundle
                }
                entries.removeValue(forKey: key)
            case .opening(let activeConfiguration, let task):
                guard activeConfiguration == configuration else {
                    throw FoveaPersistenceError.incompatibleActiveConfiguration
                }
                return try await task.value
            }
        }

        let ioExecutor = ioExecutor
        let task = Task<PersistentStoreBundle, any Error> {
            let writerLease = try await ioExecutor.run {
                try StoreWriterLease.acquire(root: generation.root)
            }
            let lifetime = PersistentStoreLifetime(writerLease: writerLease)
            let encoded = try await AkashicOriginalEncodedStore.open(
                root: generation.root.appendingPathComponent("encoded", isDirectory: true),
                limits: configuration.encodedLimits
            )
            let records = try await RepresentationRecordStore.open(
                root: generation.root.appendingPathComponent("records", isDirectory: true)
            )
            let namespaceGenerations = try await NamespaceGenerationStore.open(
                root: generation.root.appendingPathComponent(
                    "namespace-generations", isDirectory: true),
                maximumCount: configuration.maximumTrackedNamespaces
            )
            await encoded.retainLifetimeAnchor(lifetime)
            await records.retainLifetimeAnchor(lifetime)
            return PersistentStoreBundle(
                generation: generation,
                encoded: encoded,
                records: records,
                configuration: configuration,
                namespaceGenerations: namespaceGenerations,
                lifetime: lifetime
            )
        }
        entries[key] = .opening(configuration: configuration, task: task)

        do {
            let bundle = try await task.value
            entries[key] = .ready(WeakPersistentStoreBundle(bundle))
            return bundle
        } catch {
            entries.removeValue(forKey: key)
            throw error
        }
    }

    package func entryCountForTesting() -> Int {
        pruneReleasedEntries()
        return entries.count
    }

    private func pruneReleasedEntries() {
        entries = entries.filter { _, entry in
            switch entry {
            case .opening:
                return true
            case .ready(let reference):
                return reference.isAlive
            }
        }
    }

}

private final class StoreWriterLease: Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(root: URL) throws -> StoreWriterLease {
        let lockURL = root.appendingPathComponent(".fovea-writer.lock", isDirectory: false)
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posixError() }

        do {
            try FoveaManagedFileSecurity.validateOpenedPrivateRegularFile(descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let error = posixError()
            _ = Darwin.close(descriptor)
            throw error
        }
        guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            if code == EACCES || code == EAGAIN {
                throw FoveaPersistenceError.writerAlreadyActive
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return StoreWriterLease(descriptor: descriptor)
    }

    deinit {
        _ = Darwin.lockf(descriptor, F_ULOCK, 0)
        _ = Darwin.close(descriptor)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
