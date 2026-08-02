import Foundation

package enum CredentialHeaderPolicy {
    package static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "api-key",
        "cookie",
        "set-cookie",
        "x-access-token",
        "x-amz-security-token",
        "x-api-key",
        "x-auth-token",
        "x-goog-api-key",
    ]

    private static let sensitiveNameComponents: Set<String> = [
        "auth",
        "authorization",
        "credential",
        "credentials",
        "csrf",
        "key",
        "password",
        "passwd",
        "secret",
        "session",
        "signature",
        "token",
        "xsrf",
    ]

    /// 在缓存身份与重定向前使用的保守凭证字段名分类。
    ///
    /// 调用方仍可显式声明任意额外名称；组件启发式会让
    /// `x-session-id`、`x-csrf-token`、`x-id-token` 等常见私有字段在集成方
    /// 忘记列出时仍然失败关闭。
    package static func isSensitiveHeaderName(
        _ name: String,
        additionalSensitiveNames: Set<String> = []
    ) -> Bool {
        let normalized = name.lowercased()
        if sensitiveHeaderNames.contains(normalized)
            || additionalSensitiveNames.contains(where: { $0.lowercased() == normalized })
        {
            return true
        }
        let components = normalized.split(separator: "-").map(String.init)
        return components.contains(where: sensitiveNameComponents.contains)
    }

    package static func sensitiveNamesPresent(
        in headers: [String: String],
        additionalSensitiveNames: Set<String> = []
    ) -> Set<String> {
        Set(
            headers.keys
                .map { $0.lowercased() }
                .filter {
                    isSensitiveHeaderName(
                        $0,
                        additionalSensitiveNames: additionalSensitiveNames
                    )
                }
        )
    }

    package static func containsSensitiveHeader(
        _ headers: [String: String],
        additionalSensitiveNames: Set<String> = []
    ) -> Bool {
        !sensitiveNamesPresent(
            in: headers,
            additionalSensitiveNames: additionalSensitiveNames
        ).isEmpty
    }

    package static func removingSensitiveHeaders(
        from headers: [String: String],
        additionalSensitiveNames: Set<String> = []
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            let normalized = name.lowercased()
            guard
                !isSensitiveHeaderName(
                    normalized,
                    additionalSensitiveNames: additionalSensitiveNames
                ), result[normalized] == nil
            else { continue }
            result[normalized] = value
        }
        return result
    }

    package static func sanitizedRedirectRequest(
        original: URLRequest?,
        proposed: URLRequest,
        additionalSensitiveNames: Set<String> = []
    ) -> URLRequest {
        guard let originalURL = original?.url,
            let proposedURL = proposed.url,
            !sameOrigin(originalURL, proposedURL)
        else {
            return proposed
        }

        var sanitized = proposed
        let candidateNames = Set(
            sensitiveHeaderNames
                .union(additionalSensitiveNames.map { $0.lowercased() })
                .union((proposed.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        )
        for header in candidateNames
        where isSensitiveHeaderName(
            header,
            additionalSensitiveNames: additionalSensitiveNames
        ) {
            sanitized.setValue(nil, forHTTPHeaderField: header)
        }
        return sanitized
    }

    package static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
            let rhsScheme = rhs.scheme?.lowercased(),
            let lhsHost = lhs.host?.lowercased(),
            let rhsHost = rhs.host?.lowercased()
        else {
            return false
        }
        return lhsScheme == rhsScheme
            && lhsHost == rhsHost
            && effectivePort(lhs, scheme: lhsScheme) == effectivePort(rhs, scheme: rhsScheme)
    }

    private static func effectivePort(_ url: URL, scheme: String) -> Int? {
        if let port = url.port { return port }
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}
