import AkashicCore
import AkashicMemory
import Dispatch
import Foundation
import FoveaStorage

/// 将临时根目录回收移出任意业务任务的析构栈。
///
/// Store 的异步 I/O 闭包强持有 store，本 lease 只会在全部已提交工作释放后析构；
/// 串行清理队列避免 Foundation 递归删除参与调用方任务的错误传播或取消时序。
private final class TransportVerifiedHandoffRootLease: Sendable {
    private static let cleanupQueue = DispatchQueue(
        label: "dev.fovea.transport-handoff-root-cleanup",
        qos: .utility
    )

    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fovea-transport-handoff", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    }

    deinit {
        let root = self.root
        Self.cleanupQueue.async {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// 非耐久、按正文字节严格有界的 transport-verified handoff 存储。
///
/// 大型编码正文位于私有临时目录；堆内只保留连续 SIEVE 槽中的最小充分元数据。
/// 正文准备可并行执行；正文发布、索引变更和驱逐删除在极短临界区内线性化，
/// 同时不占用 Swift 协作式执行器。该层没有 manifest、fsync 或跨进程恢复语义。
final class TransportVerifiedHandoffDiskStore: @unchecked Sendable {
    private struct IndexedEntry: Sendable {
        let byteCount: Int
        let metadata: TransportVerifiedEncodedHandoffMetadata
    }

    private let rootLease: TransportVerifiedHandoffRootLease
    private var root: URL { rootLease.root }
    private let index: FoveaCompactSieveCache<ScopedTransportVerifiedHandoffKey, IndexedEntry>
    private let stateLock = NSLock()
    private let directoryPreparationLock = NSLock()
    private var isInvalidated = false
    private var publicationEpoch: UInt64 = 0
    private var inFlightPreparationCount = 0
    private var inFlightPreparationBytes = 0
    private let executor = DispatchWorkExecutor(
        label: "dev.fovea.transport-handoff-io",
        qos: .utility,
        concurrent: true
    )
    private let preparationCheckpoint: (@Sendable () -> Void)?

    init(
        costLimit: Int,
        preparationCheckpoint: (@Sendable () -> Void)? = nil
    ) {
        self.rootLease = TransportVerifiedHandoffRootLease()
        self.index = FoveaCompactSieveCache(costLimit: max(1, costLimit))
        self.preparationCheckpoint = preparationCheckpoint
    }

    var count: Int { index.count }
    var currentCost: Int { index.currentCost }

    func snapshot() -> (
        itemCount: Int,
        costBytes: Int,
        inFlightPreparationCount: Int,
        inFlightPreparationBytes: Int
    ) {
        withStateLock {
            (
                index.count,
                index.currentCost,
                inFlightPreparationCount,
                inFlightPreparationBytes
            )
        }
    }

    func insert(
        payload: TransportVerifiedEncodedHandoffPayload,
        metadata: TransportVerifiedEncodedHandoffMetadata,
        for key: ScopedTransportVerifiedHandoffKey
    ) async throws {
        let preparationBytes = metadata.contentID.byteCount
        let admittedEpoch = try withStateLock {
            guard !isInvalidated else { throw CancellationError() }
            inFlightPreparationCount += 1
            inFlightPreparationBytes += preparationBytes
            return publicationEpoch
        }
        defer {
            withStateLock {
                inFlightPreparationCount -= 1
                inFlightPreparationBytes -= preparationBytes
            }
        }

        let root = self.root
        let index = self.index
        try await executor.run {
            try self.withStateLock {
                guard !self.isInvalidated else { throw CancellationError() }
            }
            let bodyURL = Self.bodyURL(for: key, root: root)
            let temporaryBody = bodyURL.deletingLastPathComponent().appendingPathComponent(
                ".\(UUID().uuidString.lowercased()).body.tmp"
            )
            defer { try? FileManager.default.removeItem(at: temporaryBody) }

            do {
                try self.prepareDirectories(for: bodyURL, root: root)
                self.preparationCheckpoint?()
                switch payload {
                case .memory(let data):
                    try data.write(to: temporaryBody)
                case .stagedFile(let lease):
                    try lease.cloneContents(to: temporaryBody)
                }
                try FoveaManagedFileSecurity.securePublishedFile(temporaryBody)
            } catch {
                let superseded = self.withStateLock {
                    self.isInvalidated || self.publicationEpoch != admittedEpoch
                }
                if superseded { throw CancellationError() }
                throw error
            }

            try self.withStateLock {
                guard !self.isInvalidated,
                    self.publicationEpoch == admittedEpoch
                else { throw CancellationError() }
                do {
                    try? FileManager.default.removeItem(at: bodyURL)
                    try FileManager.default.moveItem(at: temporaryBody, to: bodyURL)
                    try FoveaManagedFileSecurity.securePublishedFile(bodyURL)
                } catch {
                    index.remove(key)
                    try? FileManager.default.removeItem(at: bodyURL)
                    throw error
                }

                let byteCount = metadata.contentID.byteCount
                let evicted = index.insertReportingEvictions(
                    IndexedEntry(byteCount: byteCount, metadata: metadata),
                    for: key,
                    cost: byteCount
                )
                for victim in evicted where victim != key {
                    try? FileManager.default.removeItem(
                        at: Self.bodyURL(for: victim, root: root)
                    )
                }
            }
        }
    }

    /// 精确身份只读查询；不映射正文，也不改变 SIEVE 访问状态。
    func contains(_ key: ScopedTransportVerifiedHandoffKey) -> Bool {
        withStateLock {
            !isInvalidated && index.contains(key)
        }
    }

    func entry(
        for key: ScopedTransportVerifiedHandoffKey
    ) async throws -> TransportVerifiedEncodedHandoffEntry? {
        let root = self.root
        let index = self.index
        return try await executor.run {
            try self.withStateLock {
                guard !self.isInvalidated,
                    let indexed = index.value(for: key)
                else { return nil }
                let bodyURL = Self.bodyURL(for: key, root: root)
                do {
                    try FoveaManagedFileSecurity.validateRegularFile(bodyURL)
                    let body = try Data(contentsOf: bodyURL, options: .mappedIfSafe)
                    guard body.count == indexed.byteCount,
                        indexed.metadata.contentID.byteCount == indexed.byteCount
                    else {
                        throw AkashicError.integrityMismatch
                    }
                    return TransportVerifiedEncodedHandoffEntry(
                        payload: .memory(body),
                        metadata: indexed.metadata
                    )
                } catch {
                    index.remove(key)
                    try? FileManager.default.removeItem(at: bodyURL)
                    throw error
                }
            }
        }
    }

    func remove(_ key: ScopedTransportVerifiedHandoffKey) async {
        let root = self.root
        let index = self.index
        try? await executor.run {
            self.withStateLock {
                index.remove(key)
                try? FileManager.default.removeItem(at: Self.bodyURL(for: key, root: root))
            }
        }
    }

    func removeAll(namespace: SecurityNamespaceID) async {
        let root = self.root
        let index = self.index
        try? await executor.run {
            self.withStateLock {
                self.advancePublicationEpoch()
                let victims = index.removeAllReportingKeys { $0.namespace == namespace }
                for key in victims {
                    try? FileManager.default.removeItem(at: Self.bodyURL(for: key, root: root))
                }
            }
        }
    }

    func invalidateAndRemoveAll() async -> MemoryCacheRemovalSummary {
        let root = self.root
        let index = self.index
        return
            (try? await executor.run {
                self.withStateLock {
                    self.isInvalidated = true
                    self.advancePublicationEpoch()
                    let removal = index.removeAllAndReportKeys()
                    for key in removal.keys {
                        try? FileManager.default.removeItem(at: Self.bodyURL(for: key, root: root))
                    }
                    return removal.summary
                }
            }) ?? MemoryCacheRemovalSummary(itemCount: 0, costBytes: 0)
    }

    func removeAllAndReport() async -> MemoryCacheRemovalSummary {
        let root = self.root
        let index = self.index
        return
            (try? await executor.run {
                self.withStateLock {
                    self.advancePublicationEpoch()
                    let removal = index.removeAllAndReportKeys()
                    for key in removal.keys {
                        try? FileManager.default.removeItem(at: Self.bodyURL(for: key, root: root))
                    }
                    return removal.summary
                }
            }) ?? MemoryCacheRemovalSummary(itemCount: 0, costBytes: 0)
    }

    private func advancePublicationEpoch() {
        let (next, overflow) = publicationEpoch.addingReportingOverflow(1)
        if overflow {
            isInvalidated = true
        } else {
            publicationEpoch = next
        }
    }

    @inline(__always)
    private func withStateLock<T>(_ operation: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try operation()
    }

    private func prepareDirectories(for bodyURL: URL, root: URL) throws {
        directoryPreparationLock.lock()
        defer { directoryPreparationLock.unlock() }
        try Self.prepareRoot(root)
        try FoveaManagedFileSecurity.prepareDirectory(bodyURL.deletingLastPathComponent())
    }

    private static func prepareRoot(_ root: URL) throws {
        try FoveaManagedFileSecurity.prepareDirectory(root)
    }

    private static func bodyURL(
        for key: ScopedTransportVerifiedHandoffKey,
        root: URL
    ) -> URL {
        let namespace = StorageNamespaceFingerprint(namespace: key.namespace.value).value
        return
            root
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent(String(key.generation.value), isDirectory: true)
            .appendingPathComponent("\(key.executionDigest).body")
    }
}
