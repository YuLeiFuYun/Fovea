import CryptoKit
import Foundation

/// 从 URL 派生精确 HTTP origin 时的验证失败。

public enum HTTPOriginError: Error, Equatable, Sendable {
    case invalidURL
    case unsupportedScheme
    case missingHost
    case invalidHost
    case invalidPort
}

/// 精确的 HTTP origin：scheme、规范化 host 与有效端口。
///
/// 不支持通配符、后缀匹配或隐式子域继承，避免把安全边界建立在易误解的字符串规则上。
public struct HTTPOrigin: Hashable, Sendable, CustomStringConvertible {
    public let scheme: String
    public let host: String
    public let port: Int

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw HTTPOriginError.invalidURL
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else {
            throw HTTPOriginError.unsupportedScheme
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw HTTPOriginError.missingHost
        }
        guard host.utf8.count <= 253,
            !host.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw HTTPOriginError.invalidHost
        }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65_535).contains(port) else { throw HTTPOriginError.invalidPort }
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    public var description: String { "\(scheme)://\(host):\(port)" }
}

/// 构造 HTTP 目的地策略时的失败。

public enum HTTPDestinationPolicyError: Error, Equatable, Sendable {
    case tooManyOrigins
}

/// 初始请求与重定向共享的精确目的地策略。
public struct HTTPDestinationPolicy: Hashable, Sendable {
    private enum Rule: Hashable, Sendable {
        case secureDefault
        case allowlisted(Set<HTTPOrigin>)
    }

    private static let maximumOriginCount = 256
    private let rule: Rule

    /// 允许 HTTPS 与严格 loopback HTTP；这是普通图片加载的默认边界。
    public static let secureDefault = HTTPDestinationPolicy(rule: .secureDefault)

    /// 只允许给定精确 origin。空集合表示拒绝全部目的地。
    public static func allowOnly(_ origins: Set<HTTPOrigin>) throws -> HTTPDestinationPolicy {
        guard origins.count <= maximumOriginCount else {
            throw HTTPDestinationPolicyError.tooManyOrigins
        }
        return HTTPDestinationPolicy(rule: .allowlisted(origins))
    }

    public func permits(_ url: URL) -> Bool {
        guard HTTPURLSecurityPolicy.permits(url), let origin = try? HTTPOrigin(url: url) else {
            return false
        }
        switch rule {
        case .secureDefault:
            return true
        case .allowlisted(let origins):
            return origins.contains(origin)
        }
    }

    package var executionFingerprint: String {
        switch rule {
        case .secureDefault:
            return "destination-secure-default-v1"
        case .allowlisted(let origins):
            var material = Data("destination-origins-v1\u{0}".utf8)
            for origin in origins.map(\.description).sorted() {
                material.append(contentsOf: origin.utf8)
                material.append(0)
            }
            let digest = SHA256.hash(data: material)
                .map { String(format: "%02x", $0) }
                .joined()
            return "destination-origins-v1:\(digest)"
        }
    }
}
