import CryptoKit
import Foundation

/// URLSession 代理信任策略。
///
/// `.system` 遵循系统代理、Private Relay 和设备管理策略。
/// `.requireNoProxyInTaskMetrics` 不尝试绕过系统路由；它要求 URLSession 提供事务指标，
/// 并在任何事务被标记为代理连接时拒绝接收该响应。需要连接前强制直连的宿主必须使用
/// 自定义 transport 或受管网络配置，不能把事后指标校验误解为网络隔离。
public enum URLSessionProxyPolicy: String, Hashable, Sendable {
    case system
    case requireNoProxyInTaskMetrics

    package func validate(_ metrics: TransportNetworkMetrics?) throws {
        guard self == .requireNoProxyInTaskMetrics else { return }
        guard let metrics else { throw TransportError.proxyMetricsUnavailable }
        guard metrics.proxyConnectionCount == 0 else {
            throw TransportError.proxyConnectionDisallowed
        }
    }
}

/// 官方 URLSession transport 的有界会话策略。
///
/// 请求级 constrained/expensive/cellular 权限由 `ImageRequestNetworkPolicy` 控制；
/// 此类型只承载会话级连接等待、超时、每主机连接上限和可验证的代理信任要求。
public struct URLSessionTransportPolicy: Hashable, Sendable {
    private static let maximumRequestTimeoutSeconds = 3_600
    private static let maximumResourceTimeoutSeconds = 86_400
    private static let maximumConnectionsPerHostLimit = 64

    public let waitsForConnectivity: Bool
    public let requestTimeoutSeconds: Int
    public let resourceTimeoutSeconds: Int
    public let maximumConnectionsPerHost: Int
    public let proxyPolicy: URLSessionProxyPolicy
    public let destinationPolicy: HTTPDestinationPolicy

    public init(
        waitsForConnectivity: Bool = true,
        requestTimeoutSeconds: Int = 30,
        resourceTimeoutSeconds: Int = 120,
        maximumConnectionsPerHost: Int = 6,
        proxyPolicy: URLSessionProxyPolicy = .system,
        destinationPolicy: HTTPDestinationPolicy = .secureDefault
    ) {
        self.waitsForConnectivity = waitsForConnectivity
        self.requestTimeoutSeconds = min(
            Self.maximumRequestTimeoutSeconds,
            max(1, requestTimeoutSeconds)
        )
        self.resourceTimeoutSeconds = min(
            Self.maximumResourceTimeoutSeconds,
            max(self.requestTimeoutSeconds, resourceTimeoutSeconds)
        )
        self.maximumConnectionsPerHost = min(
            Self.maximumConnectionsPerHostLimit,
            max(1, maximumConnectionsPerHost)
        )
        self.proxyPolicy = proxyPolicy
        self.destinationPolicy = destinationPolicy
    }

    public static let secureDefault = URLSessionTransportPolicy()

    package func apply(to configuration: URLSessionConfiguration) {
        configuration.waitsForConnectivity = waitsForConnectivity
        configuration.timeoutIntervalForRequest = TimeInterval(requestTimeoutSeconds)
        configuration.timeoutIntervalForResource = TimeInterval(resourceTimeoutSeconds)
        configuration.httpMaximumConnectionsPerHost = maximumConnectionsPerHost
    }

    package var fingerprint: String {
        let material = [
            "fovea-url-session-policy-v1",
            "waits:\(waitsForConnectivity)",
            "request:\(requestTimeoutSeconds)",
            "resource:\(resourceTimeoutSeconds)",
            "connections:\(maximumConnectionsPerHost)",
            "proxy:\(proxyPolicy.rawValue)",
            "destination:\(destinationPolicy.executionFingerprint)",
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
