import CryptoKit
import Foundation

/// 声明 HTTP 传输是否可复用，以及复用所依赖的组合身份。

public struct TransportReusePolicy: Hashable, Sendable {
    private enum Scope: Hashable, Sendable {
        case taskLocal
        case reusable(contextDigest: String)
    }

    private static let maximumContextIdentifierBytes = 1_024

    private let scope: Scope

    private init(scope: Scope) {
        self.scope = scope
    }

    /// 阻止独立组合的请求跨边界复用传输。
    public static let taskLocal = TransportReusePolicy(scope: .taskLocal)

    /// 从非空组合上下文标识创建可复用传输身份。
    public static func reusable(contextIdentifier: String) -> TransportReusePolicy {
        let normalized = contextIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = normalized.utf8
        guard !bytes.isEmpty, bytes.count <= maximumContextIdentifierBytes,
            normalized.unicodeScalars.allSatisfy({ scalar in
                scalar.value >= 0x20 && scalar.value != 0x7f
            })
        else { return .taskLocal }

        let material = Data("transport-context-v2\u{0}\(normalized)".utf8)
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return TransportReusePolicy(scope: .reusable(contextDigest: digest))
    }

    /// 该传输是否可由多个请求共享。
    public var allowsCrossRequestReuse: Bool {
        if case .reusable = scope { return true }
        return false
    }

    package var executionFingerprint: String {
        switch scope {
        case .taskLocal:
            return "transport-task-local-v1"
        case .reusable(let contextDigest):
            return "transport-context-v2:\(contextDigest)"
        }
    }
}

/// 请求执行期间可动态更新的传输层优先级。

public enum TransportPriority: Int, CaseIterable, Codable, Hashable, Sendable, Comparable {
    /// 紧迫性最低的后台传输工作。
    case background = 0
    /// 低优先级工作。
    case low = 1
    /// 默认传输优先级。
    case normal = 2
    /// 高优先级工作。
    case high = 3
    /// 由直接用户交互触发、对延迟敏感的工作。
    case userInitiated = 4

    /// 按传输紧迫性从低到高排序。
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    package var urlSessionTaskValue: Float {
        switch self {
        case .background: URLSessionTask.lowPriority * 0.5
        case .low: URLSessionTask.lowPriority
        case .normal: URLSessionTask.defaultPriority
        case .high: 0.75
        case .userInitiated: URLSessionTask.highPriority
        }
    }
}

package actor TransportPriorityController {
    private var priority: TransportPriority
    private var continuations: [UUID: AsyncStream<TransportPriority>.Continuation] = [:]
    private var isFinished = false

    package init(priority: TransportPriority) {
        self.priority = priority
    }

    package func updates() -> AsyncStream<TransportPriority> {
        let identifier = UUID()
        let stream = AsyncStream<TransportPriority>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        guard !isFinished else {
            stream.continuation.finish()
            return stream.stream
        }
        continuations[identifier] = stream.continuation
        stream.continuation.yield(priority)
        stream.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(identifier) }
        }
        return stream.stream
    }

    package func update(_ newPriority: TransportPriority) {
        guard !isFinished, newPriority != priority else { return }
        priority = newPriority
        for continuation in continuations.values { continuation.yield(newPriority) }
    }

    package func finish() {
        guard !isFinished else { return }
        isFinished = true
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll(keepingCapacity: false)
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }
}

/// 仅供当前在途订阅者观察的临时传输事件。
/// 事件不具有 ContentID、缓存身份或持久化权限。
package enum TransportProgressEvent: Sendable {
    case response(TransportResponseHead)
    case data(Data, cumulativeByteCount: Int)
    case complete(digestHex: String, byteCount: Int)
}

package typealias TransportProgressObserver =
    @Sendable (TransportProgressEvent) -> Void

/// transport 完成时的响应体交付策略。
///
/// 公开请求始终使用 `.materialized`；`.deferredFileIfStaged` 仅供包内取消 handoff，
/// 使已落入安全临时文件的响应不必在后台路径建立映射。
package enum TransportBodyDelivery: Sendable {
    case materialized
    case deferredFileIfStaged
}

/// 带凭证元数据和动态优先级控制的有界 HTTP 请求。

public struct TransportRequest: Sendable {
    private static let maximumSupportedResponseBytes = 1024 * 1024 * 1024

    /// 完成管线验证与凭证准备后的 URL 请求。
    public let request: URLRequest
    /// 响应正文的字节硬上限。
    public let maximumBytes: Int
    /// 响应暂存从内存切换到磁盘前的字节阈值。
    public let memoryThreshold: Int
    /// 额外视为凭证的请求头名称。
    public let credentialHeaderNames: Set<String>
    /// URLSession 任务的初始优先级。
    public let priority: TransportPriority
    package let bodyDelivery: TransportBodyDelivery
    package let priorityController: TransportPriorityController?
    package let progressObserver: TransportProgressObserver?

    /// 创建有界、任务局部的传输请求。
    public init(
        request: URLRequest,
        maximumBytes: Int,
        memoryThreshold: Int = 1024 * 1024,
        credentialHeaderNames: Set<String> = [],
        priority: TransportPriority = .normal
    ) throws {
        try Self.validateLimits(maximumBytes: maximumBytes, memoryThreshold: memoryThreshold)
        self.request = request
        self.maximumBytes = maximumBytes
        self.memoryThreshold = memoryThreshold
        self.credentialHeaderNames = try Self.normalizedCredentialHeaderNames(credentialHeaderNames)
        self.priority = priority
        self.bodyDelivery = .materialized
        self.priorityController = nil
        self.progressObserver = nil
    }

    package init(
        request: URLRequest,
        maximumBytes: Int,
        memoryThreshold: Int,
        credentialHeaderNames: Set<String>,
        priority: TransportPriority,
        bodyDelivery: TransportBodyDelivery = .materialized,
        priorityController: TransportPriorityController,
        progressObserver: TransportProgressObserver? = nil
    ) throws {
        try Self.validateLimits(maximumBytes: maximumBytes, memoryThreshold: memoryThreshold)
        self.request = request
        self.maximumBytes = maximumBytes
        self.memoryThreshold = memoryThreshold
        self.credentialHeaderNames = try Self.normalizedCredentialHeaderNames(credentialHeaderNames)
        self.priority = priority
        self.bodyDelivery = bodyDelivery
        self.priorityController = priorityController
        self.progressObserver = progressObserver
    }

    private static func validateLimits(maximumBytes: Int, memoryThreshold: Int) throws {
        guard (1...Self.maximumSupportedResponseBytes).contains(maximumBytes),
            memoryThreshold >= 0
        else {
            throw TransportError.invalidRequestLimits
        }
    }

    private static func normalizedCredentialHeaderNames(
        _ names: Set<String>
    ) throws -> Set<String> {
        guard names.count <= HTTPMetadataLimits.maximumHeaderCount else {
            throw TransportError.invalidCredentialHeaderMetadata
        }
        var totalBytes = 0
        var result: Set<String> = []
        for name in names {
            let normalized = name.lowercased()
            guard HTTPMetadataLimits.isValidFieldName(normalized) else {
                throw TransportError.invalidCredentialHeaderMetadata
            }
            let next = totalBytes.addingReportingOverflow(normalized.utf8.count)
            guard !next.overflow, next.partialValue <= HTTPMetadataLimits.maximumHeaderBytes,
                result.insert(normalized).inserted
            else {
                throw TransportError.invalidCredentialHeaderMetadata
            }
            totalBytes = next.partialValue
        }
        return result
    }
}

/// 归一化的 HTTP 状态、响应头与最终响应 URL。

public struct TransportResponseHead: Sendable {
    /// HTTP 响应状态码。
    public let statusCode: Int
    /// 名称已归一化为小写的响应头。
    public let headers: [String: String]
    /// 经过获准重定向后的最终响应 URL。
    public let url: URL?

    /// 创建有界响应头，并确定性归一化重复字段名。
    public init(statusCode: Int, headers: [String: String], url: URL?) throws {
        guard 100...599 ~= statusCode else { throw TransportError.invalidResponseStatus }
        if let url {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                components.user == nil, components.password == nil,
                HTTPURLSecurityPolicy.permits(url),
                url.absoluteString.utf8.count <= HTTPMetadataLimits.maximumURLBytes
            else {
                throw TransportError.invalidResponseURL
            }
        }
        self.statusCode = statusCode
        self.headers = try HTTPMetadataLimits.normalizedHeaders(headers)
        self.url = url
    }

    /// 按不区分大小写的字段名返回归一化响应头值。
    public func value(forHeader name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// URLSession 事务、重定向、路径标记与耗时的脱敏摘要。

/// 一次传输响应的字节暂存指标与可选网络指标。
public struct TransportMetrics: Sendable {
    /// 暂存层接收的编码响应字节。
    public let receivedBytes: Int
    /// 暂存是否超过纯内存阈值。
    public let spilledToDisk: Bool
    /// 传输能够采集时提供的脱敏 URLSession 指标。
    public let network: TransportNetworkMetrics?

    /// 创建字节暂存指标，并可附带 URLSession 网络细节。
    public init(
        receivedBytes: Int,
        spilledToDisk: Bool,
        network: TransportNetworkMetrics? = nil
    ) {
        self.receivedBytes = max(0, receivedBytes)
        self.spilledToDisk = spilledToDisk
        self.network = network
    }
}

package struct TransportBodyDigest: Sendable {
    package let hex: String
}

/// 已完整接收且摘要已验证的 transport 响应体存储。
package enum TransportBodyStorage: Sendable {
    case memory(Data)
    case stagedFile(TransportStagedFileLease)

    package var byteCount: Int {
        switch self {
        case .memory(let data): data.count
        case .stagedFile(let lease): lease.byteCount
        }
    }

    package var stagedFileLease: TransportStagedFileLease? {
        guard case .stagedFile(let lease) = self else { return nil }
        return lease
    }

    package func materializedData() throws -> Data {
        switch self {
        case .memory(let data): data
        case .stagedFile(let lease): try lease.mappedData()
        }
    }
}

/// 包含归一化元数据与编码字节的已验证暂存响应。

public struct TransportResponse: Sendable {
    /// 归一化响应元数据。
    public let head: TransportResponseHead
    /// 受上限约束的编码响应字节。
    ///
    /// 内存响应直接返回；包内 deferred handoff 会映射暂存文件，因此读取可能失败。
    /// 调用方不能把文件生命周期或 I/O 错误压缩成不可恢复的进程终止。
    public var body: Data {
        get throws { try bodyStorage.materializedData() }
    }
    /// 编码正文的 SHA-256 摘要。
    public let digestHex: String
    /// 字节暂存与网络指标。
    public let metrics: TransportMetrics
    package let bodyStorage: TransportBodyStorage
    package var bodyByteCount: Int { bodyStorage.byteCount }
    package var stagedFileLease: TransportStagedFileLease? { bodyStorage.stagedFileLease }

    package func materializedBody() throws -> Data {
        try bodyStorage.materializedData()
    }

    /// 创建完整响应，并从实际字节派生内容身份。
    ///
    /// 自定义传输不能提供由调用方控制的摘要或字节数，从而确保
    /// 解码、渲染内存与持久化身份始终绑定到真正交付的正文。
    public init(head: TransportResponseHead, body: Data, metrics: TransportMetrics) {
        self.head = head
        self.bodyStorage = .memory(body)
        self.digestHex = Self.digestHex(for: body)
        self.metrics = TransportMetrics(
            receivedBytes: body.count,
            spilledToDisk: metrics.spilledToDisk,
            network: metrics.network
        )
    }

    /// 内置流式传输可以携带仅能在 FoveaHTTP 内部构造的摘要令牌，
    /// 既避免对正文进行第二次哈希，也不暴露可伪造的公共接口。
    init(
        head: TransportResponseHead,
        bodyStorage: TransportBodyStorage,
        verifiedDigest: TransportBodyDigest,
        metrics: TransportMetrics
    ) {
        self.head = head
        self.bodyStorage = bodyStorage
        self.digestHex = verifiedDigest.hex
        self.metrics = TransportMetrics(
            receivedBytes: bodyStorage.byteCount,
            spilledToDisk: metrics.spilledToDisk,
            network: metrics.network
        )
    }

    private static func digestHex(for body: Data) -> String {
        SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }

}

/// 有界 HTTP 传输层产生的稳定失败类型。

public enum TransportError: Error, Equatable, Sendable {
    case nonHTTPResponse
    case bodyTooLarge
    case invalidRequestLimits
    case invalidCredentialHeaderMetadata
    case invalidResponseStatus
    case invalidResponseURL
    case invalidResponseHeader
    case responseHeadersTooLarge
    case invalidContentLength
    case incompleteBody
    case insecureRedirect
    case destinationDisallowed
    case proxyMetricsUnavailable
    case proxyConnectionDisallowed
}

/// 执行有界 HTTP 请求，但不应用图像缓存语义。

/// 包内传输可选择承诺：所有 progress 事件来自与最终响应相同的暂存字节。
/// 外部自定义 transport 无法访问 package-only observer，因此默认不具备该能力。
package protocol TransportProgressObservationSupporting: HTTPTransporting {}

public protocol HTTPTransporting: Sendable {
    /// 管线组合身份使用的传输复用契约。
    nonisolated var reusePolicy: TransportReusePolicy { get }
    /// 执行一次有界传输请求。
    func execute(_ request: TransportRequest) async throws -> TransportResponse
}
