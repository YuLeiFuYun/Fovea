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

  package static func sensitiveNamesPresent(
    in headers: [String: String],
    additionalSensitiveNames: Set<String> = []
  ) -> Set<String> {
    let sensitive = sensitiveHeaderNames.union(additionalSensitiveNames.map { $0.lowercased() })
    return Set(headers.keys.map { $0.lowercased() }.filter(sensitive.contains))
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
    let sensitive = sensitiveHeaderNames.union(additionalSensitiveNames.map { $0.lowercased() })
    var result: [String: String] = [:]
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
      let normalized = name.lowercased()
      guard !sensitive.contains(normalized), result[normalized] == nil else { continue }
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
    let sensitive = sensitiveHeaderNames.union(additionalSensitiveNames.map { $0.lowercased() })
    for header in sensitive {
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
