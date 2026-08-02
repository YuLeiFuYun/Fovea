import AkashicCore
import AkashicDisk
import AkashicMemory
import Foundation
import FoveaCore
import FoveaPersistence
import FoveaStorage
import LRUCache
import PINCacheBridge

public enum CacheLabError: Error, Equatable, Sendable {
    case invalidConfiguration
    case unsupportedOperation
    case corruptValue
}

public protocol MemoryCacheContestant: Sendable {
    var name: String { get }
    func value(for key: String) async -> Data?
    func insert(_ value: Data, for key: String, cost: Int) async
    func removeValue(for key: String) async
    func removeAll() async
    func count() async -> Int
    func currentCost() async -> Int
}

public final class FoveaMemoryContestant: MemoryCacheContestant, @unchecked Sendable {
    public let name = "Fovea"
    private static let shardCount = 8
    private let cache: ShardedMemoryCache<String, Data>

    public init(costLimit: Int) {
        cache = ShardedMemoryCache(costLimit: costLimit, shardCount: Self.shardCount)
    }

    public func value(for key: String) async -> Data? {
        cache.value(for: key)
    }

    public func insert(_ value: Data, for key: String, cost: Int) async {
        cache.insert(value, for: key, cost: cost)
    }

    public func removeValue(for key: String) async {
        cache.remove(key)
    }

    public func removeAll() async {
        cache.removeAll()
    }

    public func count() async -> Int {
        cache.count
    }

    public func currentCost() async -> Int {
        cache.currentCost
    }
}

public final class LRUCacheContestant: MemoryCacheContestant, @unchecked Sendable {
    public let name = "LRUCache"
    private let cache: LRUCache<String, Data>

    public init(costLimit: Int) {
        cache = LRUCache(totalCostLimit: costLimit, clearsOnMemoryPressure: false)
    }

    public func value(for key: String) async -> Data? {
        cache.value(forKey: key)
    }

    public func insert(_ value: Data, for key: String, cost: Int) async {
        cache.setValue(value, forKey: key, cost: cost)
    }

    public func removeValue(for key: String) async {
        cache.removeValue(forKey: key)
    }

    public func removeAll() async {
        cache.removeAll()
    }

    public func count() async -> Int {
        cache.count
    }

    public func currentCost() async -> Int {
        cache.totalCost
    }
}

public final class PINMemoryContestant: MemoryCacheContestant, @unchecked Sendable {
    public let name = "PINMemoryCache"
    private let bridge: CacheLabPINMemoryBridge

    public init(costLimit: Int, root: URL) {
        bridge = CacheLabPINMemoryBridge(
            rootPath: root.path,
            costLimit: UInt(max(0, costLimit)),
        )
    }

    public func value(for key: String) async -> Data? {
        bridge.data(forKey: key)
    }

    public func insert(_ value: Data, for key: String, cost: Int) async {
        bridge.setData(value, forKey: key, cost: UInt(max(0, cost)))
    }

    public func removeValue(for key: String) async {
        bridge.removeData(forKey: key)
    }

    public func removeAll() async {
        bridge.removeAllData()
    }

    public func count() async -> Int {
        Int(bridge.count)
    }

    public func currentCost() async -> Int {
        Int(bridge.totalCost)
    }
}

public protocol DiskCacheContestant: Sendable {
    var name: String { get }
    var root: URL { get }
    func value(for key: String) async throws -> Data?
    func insert(_ value: Data, for key: String) async throws
    func removeValue(for key: String) async throws
    func removeAll() async throws
    /// 等待该 contestant 已产生的后台工作完成；不得在下一计时窗口继续消耗资源。
    func quiesce() async throws
    func fileURL(for key: String) async throws -> URL?
    func readExceptionCount() async -> Int
    func reopen() async throws -> any DiskCacheContestant
}

public final class FoveaDiskContestant: DiskCacheContestant, @unchecked Sendable {
    public let name = "Fovea"
    public let root: URL
    private let namespace = "public:cache-lab"
    private let softLimitBytes: Int
    private let stores: FoveaPersistentStores

    public static func open(root: URL, softLimitBytes: Int = 512 * 1024 * 1024) async throws
        -> FoveaDiskContestant
    {
        let stores = try await FoveaPersistentStores.open(
            root: root,
            encodedSoftTotalBytes: softLimitBytes,
            maximumEncodedBlobBytes: softLimitBytes,
        )
        return FoveaDiskContestant(
            root: root,
            softLimitBytes: softLimitBytes,
            stores: stores,
        )
    }

    private init(root: URL, softLimitBytes: Int, stores: FoveaPersistentStores) {
        self.root = root
        self.softLimitBytes = softLimitBytes
        self.stores = stores
    }

    public func value(for key: String) async throws -> Data? {
        do {
            return try await stores.encoded.read(contentID: key, namespace: namespace)
        } catch AkashicError.notFound {
            return nil
        }
    }

    public func insert(_ value: Data, for key: String) async throws {
        _ = try await stores.encoded.commit(data: value, contentID: key, namespace: namespace)
    }

    public func removeValue(for key: String) async throws {
        try await stores.encoded.remove(contentID: key, namespace: namespace)
    }

    public func removeAll() async throws {
        try await stores.encoded.removeAll(namespace: namespace)
    }

    public func quiesce() async throws {}
    public func fileURL(for key: String) async throws -> URL? {
        guard let physicalID = await stores.encoded.physicalID(
            contentID: key,
            namespace: namespace,
        ) else { return nil }
        return stores.generation.root
            .appendingPathComponent("encoded", isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(physicalID.rawValue.uuidString.lowercased(), isDirectory: false)
    }

    public func readExceptionCount() async -> Int {
        0
    }

    public func reopen() async throws -> any DiskCacheContestant {
        try await FoveaDiskContestant.open(root: root, softLimitBytes: softLimitBytes)
    }
}

public final class PINDiskContestant: DiskCacheContestant, @unchecked Sendable {
    public let name = "PINDiskCacheNative"
    public let root: URL
    private let cacheName: String
    private let bridge: CacheLabPINDiskBridge

    public init(root: URL, cacheName: String = "FoveaCacheLabPIN") {
        self.root = root
        self.cacheName = cacheName
        bridge = CacheLabPINDiskBridge(rootPath: root.path, name: cacheName)
    }

    public func value(for key: String) async throws -> Data? {
        bridge.data(forKey: key)
    }

    public func insert(_ value: Data, for key: String) async throws {
        bridge.setData(value, forKey: key)
    }

    public func removeValue(for key: String) async throws {
        bridge.drainPendingOperations()
        bridge.removeData(forKey: key)
        bridge.drainPendingOperations()
    }

    public func removeAll() async throws {
        bridge.removeAllData()
    }

    public func quiesce() async throws {
        bridge.drainPendingOperations()
    }

    public func fileURL(for key: String) async throws -> URL? {
        bridge.fileURL(forKey: key)
    }

    public func readExceptionCount() async -> Int {
        Int(bridge.readExceptionCount)
    }

    public func reopen() async throws -> any DiskCacheContestant {
        try await quiesce()
        return PINDiskContestant(root: root, cacheName: cacheName)
    }
}

public func cacheContentID(for data: Data) -> String {
    ContentID(data: data).description
}
