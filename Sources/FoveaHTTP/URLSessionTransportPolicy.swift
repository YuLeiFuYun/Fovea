import CryptoKit
import Foundation

/// 官方 URLSession transport 的有界会话策略。
///
/// 请求级 constrained/expensive/cellular 权限由 `ImageRequestNetworkPolicy` 控制；
/// 此类型只承载会话级连接等待、超时和每主机连接上限。
public struct URLSessionTransportPolicy: Codable, Hashable, Sendable {
  public let waitsForConnectivity: Bool
  public let requestTimeoutSeconds: Int
  public let resourceTimeoutSeconds: Int
  public let maximumConnectionsPerHost: Int

  public init(
    waitsForConnectivity: Bool = true,
    requestTimeoutSeconds: Int = 30,
    resourceTimeoutSeconds: Int = 120,
    maximumConnectionsPerHost: Int = 6
  ) {
    self.waitsForConnectivity = waitsForConnectivity
    self.requestTimeoutSeconds = max(1, requestTimeoutSeconds)
    self.resourceTimeoutSeconds = max(self.requestTimeoutSeconds, resourceTimeoutSeconds)
    self.maximumConnectionsPerHost = max(1, maximumConnectionsPerHost)
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
    ].joined(separator: "\u{0}")
    return SHA256.hash(data: Data(material.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
