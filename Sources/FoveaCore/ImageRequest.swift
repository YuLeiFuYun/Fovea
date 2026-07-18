import Foundation
import FoveaHTTP
import ImageCraftCore

public enum ImageRequestError: Error, Equatable, Sendable {
  case duplicateHeaderName(String)
  case invalidHeaderName(String)
  case invalidHeaderValue(String)
  case unsupportedURLScheme(String?)
  case missingURLHost
  case embeddedURLCredentials
  case invalidURL
}

public struct ImageRequest: Sendable {
  public let url: URL
  public let logicalSource: LogicalSourceID
  public let target: TargetPixels
  public let namespace: SecurityNamespaceID
  public let authorizationContext: AuthorizationContextID
  public let credentialGeneration: CredentialGeneration?
  public let headers: [String: String]

  public init(
    url: URL,
    logicalSource: LogicalSourceID? = nil,
    target: TargetPixels,
    namespace: SecurityNamespaceID,
    authorizationContext: AuthorizationContextID = .public,
    credentialGeneration: CredentialGeneration? = nil,
    headers: [String: String] = [:]
  ) throws {
    let normalizedURL = try Self.normalizedHTTPURL(url)
    self.url = normalizedURL
    self.logicalSource = logicalSource ?? LogicalSourceID(normalizedHTTPURL: normalizedURL)
    self.target = target
    self.namespace = namespace
    self.authorizationContext = authorizationContext
    self.credentialGeneration = credentialGeneration
    self.headers = try Self.normalizedHeaders(headers)
  }

  public static func publicImage(
    url: URL,
    logicalSource: LogicalSourceID? = nil,
    target: TargetPixels,
    appID: String
  ) throws -> Self {
    try ImageRequest(
      url: url,
      logicalSource: logicalSource,
      target: target,
      namespace: .publicNamespace(appID: appID)
    )
  }

  public var fetchVariantKey: FetchVariantKey {
    FetchVariantKey(
      source: logicalSource,
      namespace: namespace,
      authorizationContext: authorizationContext,
      requestVariants: stableRequestVariants
    )
  }

  public var fetchExecutionKey: FetchExecutionKey {
    fetchExecutionKey(revalidationFingerprint: "unconditional")
  }

  public func fetchExecutionKey(revalidationFingerprint: String) -> FetchExecutionKey {
    FetchExecutionKey(
      variant: fetchVariantKey,
      resolvedLocator: url.absoluteString,
      credentialGeneration: credentialGeneration,
      revalidationFingerprint: revalidationFingerprint
    )
  }

  public var displayIdentity: String {
    "\(fetchExecutionKey.digestHex)|\(target.width)x\(target.height)"
  }

  public var containsCredentialHeaders: Bool {
    CredentialHeaderPolicy.containsSensitiveHeader(headers)
  }

  private var stableRequestVariants: [String: String] {
    CredentialHeaderPolicy.removingSensitiveHeaders(from: headers)
  }

  private static func normalizedHTTPURL(_ url: URL) throws -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw ImageRequestError.invalidURL
    }
    let scheme = components.scheme?.lowercased()
    guard scheme == "http" || scheme == "https" else {
      throw ImageRequestError.unsupportedURLScheme(components.scheme)
    }
    guard let host = components.host, !host.isEmpty else {
      throw ImageRequestError.missingURLHost
    }
    guard components.user == nil, components.password == nil else {
      throw ImageRequestError.embeddedURLCredentials
    }

    components.scheme = scheme
    components.host = host.lowercased()
    if (scheme == "http" && components.port == 80)
      || (scheme == "https" && components.port == 443)
    {
      components.port = nil
    }
    components.fragment = nil
    if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
    guard let normalized = components.url else { throw ImageRequestError.invalidURL }
    return normalized
  }

  private static func normalizedHeaders(_ headers: [String: String]) throws -> [String: String] {
    var result: [String: String] = [:]
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
      let normalized = name.lowercased()
      guard isValidHeaderName(normalized) else {
        throw ImageRequestError.invalidHeaderName(name)
      }
      guard
        !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 })
      else {
        throw ImageRequestError.invalidHeaderValue(name)
      }
      guard result[normalized] == nil else {
        throw ImageRequestError.duplicateHeaderName(normalized)
      }
      result[normalized] = value
    }
    return result
  }

  private static func isValidHeaderName(_ name: String) -> Bool {
    guard !name.isEmpty else { return false }
    let allowedPunctuation = Set("!#$%&'*+-.^_`|~".unicodeScalars.map(\.value))
    return name.unicodeScalars.allSatisfy { scalar in
      let value = scalar.value
      return (48...57).contains(value)
        || (65...90).contains(value)
        || (97...122).contains(value)
        || allowedPunctuation.contains(value)
    }
  }
}
