import AkashicCore
import AkashicMemory
import Foundation
import FoveaStorage

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

    private let root: URL
    private let index: FoveaCompactSieveCache<ScopedTransportVerifiedHandoffKey, IndexedEntry>
    private let stateLock = NSLock()
    private var isInvalidated = false
    private var inFlightPreparationCount = 0
    private var inFlightPreparationBytes = 0
    private let executor = DispatchWorkExecutor(
        label: "dev.fovea.transport-handoff-io",
        qos: .utility,
        concurrent: true
    )

    init(costLimit: Int) {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fovea-transport-handoff", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        self.index = FoveaCompactSieveCache(costLimit: max(1, costLimit))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
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
        try withStateLock {
            guard !isInvalidated else { throw CancellationError() }
            inFlightPreparationCount += 1
            inFlightPreparationBytes += preparationBytes
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
            try Self.prepareRoot(root)
            let bodyURL = Self.bodyURL(for: key, root: root)
            try FoveaManagedFileSecurity.prepareDirectory(bodyURL.deletingLastPathComponent())

            let temporaryBody = bodyURL.deletingLastPathComponent().appendingPathComponent(
                ".\(UUID().uuidString.lowercased()).body.tmp"
            )
            defer { try? FileManager.default.removeItem(at: temporaryBody) }

            switch payload {
            case .memory(let data):
                try data.write(to: temporaryBody)
            case .stagedFile(let lease):
                try lease.cloneContents(to: temporaryBody)
            }
            try FoveaManagedFileSecurity.securePublishedFile(temporaryBody)

            try self.withStateLock {
                guard !self.isInvalidated else { throw CancellationError() }
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
                index.removeAll { $0.namespace == namespace }
                let fingerprint = StorageNamespaceFingerprint(namespace: namespace.value).value
                try? FileManager.default.removeItem(
                    at: root.appendingPathComponent(fingerprint, isDirectory: true)
                )
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
                    let summary = index.removeAllAndReport()
                    try? FileManager.default.removeItem(at: root)
                    return summary
                }
            }) ?? MemoryCacheRemovalSummary(itemCount: 0, costBytes: 0)
    }

    func removeAllAndReport() async -> MemoryCacheRemovalSummary {
        let root = self.root
        let index = self.index
        return
            (try? await executor.run {
                self.withStateLock {
                    let summary = index.removeAllAndReport()
                    try? FileManager.default.removeItem(at: root)
                    return summary
                }
            }) ?? MemoryCacheRemovalSummary(itemCount: 0, costBytes: 0)
    }

    @inline(__always)
    private func withStateLock<T>(_ operation: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try operation()
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
