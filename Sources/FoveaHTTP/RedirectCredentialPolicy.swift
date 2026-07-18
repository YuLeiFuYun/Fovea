import Foundation

public enum RedirectCredentialPolicy {
  public static let sensitiveHeaderNames: Set<String> = [
    "authorization",
    "proxy-authorization",
    "cookie",
    "x-api-key",
  ]

  public static func sanitizedRedirectRequest(
    original: URLRequest?,
    proposed: URLRequest
  ) -> URLRequest {
    guard let originalURL = original?.url,
      let proposedURL = proposed.url,
      !sameOrigin(originalURL, proposedURL)
    else {
      return proposed
    }

    var sanitized = proposed
    for header in sensitiveHeaderNames {
      sanitized.setValue(nil, forHTTPHeaderField: header)
    }
    return sanitized
  }

  public static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
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

final class RedirectCredentialDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(
      RedirectCredentialPolicy.sanitizedRedirectRequest(
        original: task.currentRequest ?? task.originalRequest,
        proposed: request
      )
    )
  }
}
