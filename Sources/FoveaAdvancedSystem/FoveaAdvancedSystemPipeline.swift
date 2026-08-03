import AkashicCore
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import FoveaStorage
import FoveaSystem
import ImageCraftCore
import ImageCraftImageIO

/// 高级持久化组合入口的稳定 provider 身份与兼容域。
public struct FoveaPersistentStoreProviderDescriptor: Hashable, Sendable {
    /// provider 的稳定实现标识。
    public let identifier: String
    /// 改变 bundle 行为或持久语义时递增的实现版本。
    public let implementationVersion: UInt32
    /// generation 布局和跨 store 事务语义的兼容指纹。
    public let compatibilityFingerprint: String

    /// 创建当前 qualified bundle contract 的 provider descriptor。
    public init(
        identifier: String,
        implementationVersion: UInt32,
        compatibilityFingerprint: String
    ) throws {
        _ = try FoveaPersistentStoreProviderIdentity(
            identifier: identifier,
            implementationVersion: implementationVersion,
            compatibilityFingerprint: compatibilityFingerprint
        )
        self.identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        self.implementationVersion = implementationVersion
        self.compatibilityFingerprint = compatibilityFingerprint.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    /// 绑定 provider 实现、bundle contract 和兼容域的稳定指纹。
    public var cacheFingerprint: String {
        "\(identifier)#impl=\(implementationVersion)#contract=\(FoveaPersistentStoreProviderIdentity.currentContractVersion)#compat=\(compatibilityFingerprint)"
    }

    package var identity: FoveaPersistentStoreProviderIdentity {
        get throws {
            try FoveaPersistentStoreProviderIdentity(
                identifier: identifier,
                implementationVersion: implementationVersion,
                compatibilityFingerprint: compatibilityFingerprint
            )
        }
    }
}

/// namespace generation 持久化的闭包值；授权与撤销语义仍由 FoveaCore 拥有。
public struct FoveaNamespaceGenerationPersistence: Sendable {
    package let loadOperation: @Sendable (Int) async throws -> [StorageNamespaceFingerprint: UInt64]
    package let persistOperation:
        @Sendable (UInt64, StorageNamespaceFingerprint) async throws -> Void

    /// 用有界读取和单调写入闭包创建持久化能力。
    public init(
        load: @escaping @Sendable (Int) async throws -> [StorageNamespaceFingerprint: UInt64],
        persist: @escaping @Sendable (UInt64, StorageNamespaceFingerprint) async throws -> Void
    ) {
        self.loadOperation = load
        self.persistOperation = persist
    }
}

/// provider 一次返回的不可拆分持久化 bundle。
public struct FoveaQualifiedPersistentStoreBundle: Sendable {
    package let descriptor: FoveaPersistentStoreProviderDescriptor
    package let generation: StoreGenerationDescriptor
    package let encoded: any OriginalEncodedMaintaining & AnyObject
    package let records: any RepresentationRecordMaintaining
    package let namespaceGenerations: FoveaNamespaceGenerationPersistence
    private let lifetimeAnchor: any Sendable

    /// 绑定同一 generation 下的 encoded、records、namespace persistence 与 lifetime。
    public init(
        descriptor: FoveaPersistentStoreProviderDescriptor,
        generation: StoreGenerationDescriptor,
        encoded: any OriginalEncodedMaintaining & AnyObject,
        records: any RepresentationRecordMaintaining,
        namespaceGenerations: FoveaNamespaceGenerationPersistence,
        lifetimeAnchor: any Sendable
    ) throws {
        guard generation.compatibilityFingerprint == descriptor.compatibilityFingerprint else {
            throw AkashicError.invalidIdentity
        }
        self.descriptor = descriptor
        self.generation = generation
        self.encoded = encoded
        self.records = records
        self.namespaceGenerations = namespaceGenerations
        self.lifetimeAnchor = lifetimeAnchor
    }

    package func internalBundle() throws -> FoveaPersistentStoreBundle {
        try FoveaPersistentStoreBundle(
            providerIdentity: descriptor.identity,
            generation: generation,
            encoded: encoded,
            records: records,
            namespaceGenerations: NamespaceGenerationPersistenceAdapter(
                base: namespaceGenerations
            ),
            lifetimeAnchor: self
        )
    }
}

/// 原子提供一整套持久化能力，而不是分别注册三个全局 store hook。
public protocol FoveaPersistentStoreBundleProviding: Sendable {
    /// provider 声明的稳定实现与兼容身份。
    nonisolated var descriptor: FoveaPersistentStoreProviderDescriptor { get }

    /// 打开一个共享 generation、writer lifetime 和 namespace 持久化语义的 bundle。
    func open(
        root: URL,
        encodedSoftTotalBytes: Int,
        maximumEncodedBlobBytes: Int,
        maximumTrackedNamespaces: Int
    ) async throws -> FoveaQualifiedPersistentStoreBundle
}

private actor NamespaceGenerationPersistenceAdapter: NamespaceGenerationPersisting {
    private let base: FoveaNamespaceGenerationPersistence

    init(base: FoveaNamespaceGenerationPersistence) {
        self.base = base
    }

    func load(
        maximumCount: Int
    ) async throws -> [StorageNamespaceFingerprint: UInt64] {
        try await base.loadOperation(maximumCount)
    }

    func persist(
        _ generation: UInt64,
        for namespace: StorageNamespaceFingerprint
    ) async throws {
        try await base.persistOperation(generation, namespace)
    }
}

extension FoveaSystemPipeline {
    /// 使用一个不可变、完整的持久化 provider bundle 组合高级系统管线。
    public static func open(
        cacheRoot: URL,
        persistentStoreProvider: any FoveaPersistentStoreBundleProviding,
        configuration: PipelineConfiguration = PipelineConfiguration(),
        diagnostics: any DiagnosticsSink = NullDiagnosticsSink(),
        profileAccessPolicy: ProfileAccessPolicy = .publicOnly,
        transportPolicy: URLSessionTransportPolicy = .secureDefault,
        encodedSoftTotalBytes: Int = 128 * 1024 * 1024,
        maximumEncodedBlobBytes: Int = 64 * 1024 * 1024,
        automaticallyPurgesMemoryOnPressure: Bool = true,
        sessionConfiguration: URLSessionConfiguration? = nil,
        stagingDirectory: URL? = nil,
        transportReusePolicy: TransportReusePolicy? = nil,
        codec: any ImageCodec = ImageIOImageDecoder(),
        transformer: any ImageTransforming = IdentityImageTransformer(),
        renderedImageCache: (any RenderedImageCaching)? = nil
    ) async throws -> FoveaSystemPipeline {
        guard
            cacheRoot.isFileURL,
            encodedSoftTotalBytes > 0,
            maximumEncodedBlobBytes > 0,
            maximumEncodedBlobBytes <= encodedSoftTotalBytes,
            (1...1_000_000).contains(configuration.maximumTrackedNamespaces)
        else {
            throw AkashicError.invalidIdentity
        }
        let stores = try await persistentStoreProvider.open(
            root: cacheRoot,
            encodedSoftTotalBytes: encodedSoftTotalBytes,
            maximumEncodedBlobBytes: maximumEncodedBlobBytes,
            maximumTrackedNamespaces: configuration.maximumTrackedNamespaces
        )
        guard stores.descriptor == persistentStoreProvider.descriptor else {
            throw AkashicError.invalidIdentity
        }
        return try await openQualified(
            stores: stores.internalBundle(),
            configuration: configuration,
            diagnostics: diagnostics,
            profileAccessPolicy: profileAccessPolicy,
            transportPolicy: transportPolicy,
            automaticallyPurgesMemoryOnPressure: automaticallyPurgesMemoryOnPressure,
            sessionConfiguration: sessionConfiguration,
            stagingDirectory: stagingDirectory,
            transportReusePolicy: transportReusePolicy,
            codec: codec,
            transformer: transformer,
            renderedImageCache: renderedImageCache
        )
    }
}
