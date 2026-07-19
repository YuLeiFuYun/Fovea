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
  case fingerprintForNonCredentialHeader(String)
}

public struct ImageRequest: Sendable {
  public let url: URL
  public let logicalSource: LogicalSourceID
  public let target: TargetPixels
  public let contentMode: ImageContentMode
  public let geometryPolicyFingerprint: String
  public let renderCacheAdmission: RenderCacheAdmission
  public let namespace: SecurityNamespaceID
  public let authorizationContext: AuthorizationContextID
  public let credentialGeneration: CredentialGeneration?
  public let priority: ImageRequestPriority
  public let headers: [String: String]
  public let credentialHeaderNames: Set<String>
  public let headerVariantFingerprints: [String: HeaderVariantFingerprint]

  public init(
    url: URL,
    logicalSource: LogicalSourceID? = nil,
    target: TargetPixels,
    contentMode: ImageContentMode = .fit,
    geometryPolicyFingerprint: String = "exact-v1",
    renderCacheAdmission: RenderCacheAdmission = .stable,
    namespace: SecurityNamespaceID,
    authorizationContext: AuthorizationContextID = .public,
    credentialGeneration: CredentialGeneration? = nil,
    priority: ImageRequestPriority = .normal,
    headers: [String: String] = [:],
    credentialHeaderNames: Set<String> = [],
    headerVariantFingerprints: [String: HeaderVariantFingerprint] = [:]
  ) throws {
    let normalizedURL = try Self.normalizedHTTPURL(url)
    let normalizedHeaders = try Self.normalizedHeaders(headers)
    let normalizedCredentialNames = try Self.normalizedHeaderNames(credentialHeaderNames)
    let normalizedFingerprints = try Self.normalizedFingerprints(headerVariantFingerprints)
    let sensitiveNames = CredentialHeaderPolicy.sensitiveHeaderNames.union(
      normalizedCredentialNames)
    for name in normalizedFingerprints.keys where !sensitiveNames.contains(name) {
      throw ImageRequestError.fingerprintForNonCredentialHeader(name)
    }

    self.url = normalizedURL
    self.logicalSource = logicalSource ?? LogicalSourceID(normalizedHTTPURL: normalizedURL)
    self.target = target
    self.contentMode = contentMode
    self.geometryPolicyFingerprint = geometryPolicyFingerprint
    self.renderCacheAdmission = renderCacheAdmission
    self.namespace = namespace
    self.authorizationContext = authorizationContext
    self.credentialGeneration = credentialGeneration
    self.priority = priority
    self.headers = normalizedHeaders
    self.credentialHeaderNames = normalizedCredentialNames
    self.headerVariantFingerprints = normalizedFingerprints
  }

  public init(
    url: URL,
    logicalSource: LogicalSourceID? = nil,
    resolvedTarget: ResolvedImageTarget,
    namespace: SecurityNamespaceID,
    authorizationContext: AuthorizationContextID = .public,
    credentialGeneration: CredentialGeneration? = nil,
    priority: ImageRequestPriority = .normal,
    headers: [String: String] = [:],
    credentialHeaderNames: Set<String> = [],
    headerVariantFingerprints: [String: HeaderVariantFingerprint] = [:]
  ) throws {
    try self.init(
      url: url,
      logicalSource: logicalSource,
      target: resolvedTarget.pixels,
      contentMode: resolvedTarget.contentMode,
      geometryPolicyFingerprint: resolvedTarget.geometryPolicyFingerprint,
      renderCacheAdmission: resolvedTarget.cacheAdmission,
      namespace: namespace,
      authorizationContext: authorizationContext,
      credentialGeneration: credentialGeneration,
      priority: priority,
      headers: headers,
      credentialHeaderNames: credentialHeaderNames,
      headerVariantFingerprints: headerVariantFingerprints
    )
  }

  public static func publicImage(
    url: URL,
    logicalSource: LogicalSourceID? = nil,
    target: TargetPixels,
    appID: String,
    priority: ImageRequestPriority = .normal
  ) throws -> Self {
    try ImageRequest(
      url: url,
      logicalSource: logicalSource,
      target: target,
      namespace: .publicNamespace(appID: appID),
      priority: priority
    )
  }

  public static func publicImage(
    url: URL,
    logicalSource: LogicalSourceID? = nil,
    resolvedTarget: ResolvedImageTarget,
    appID: String,
    priority: ImageRequestPriority = .normal
  ) throws -> Self {
    try ImageRequest(
      url: url,
      logicalSource: logicalSource,
      resolvedTarget: resolvedTarget,
      namespace: .publicNamespace(appID: appID),
      priority: priority
    )
  }

  public var fetchBaseKey: FetchBaseKey {
    FetchBaseKey(
      source: logicalSource,
      namespace: namespace,
      authorizationContext: authorizationContext
    )
  }

  public var fetchVariantKey: FetchVariantKey {
    FetchVariantKey(base: fetchBaseKey)
  }

  package func fetchVariantKey(for selection: HTTPVarySelection) -> FetchVariantKey {
    FetchVariantKey(
      base: fetchBaseKey,
      requestVariants: selection.canonicalRequestVariants
    )
  }

  public var fetchExecutionKey: FetchExecutionKey {
    fetchExecutionKey(
      selectedVariant: nil,
      revalidationFingerprint: "unconditional",
      transportPolicyFingerprint: "request-default-v1"
    )
  }

  package func fetchExecutionKey(
    selectedVariant: FetchVariantKey?,
    revalidationFingerprint: String,
    transportPolicyFingerprint: String = "request-default-v1"
  ) -> FetchExecutionKey {
    FetchExecutionKey(
      base: fetchBaseKey,
      selectedVariant: selectedVariant,
      resolvedLocator: url.absoluteString,
      requestHeaderFingerprint: exactRequestHeaderFingerprint,
      credentialGeneration: credentialGeneration,
      revalidationFingerprint: revalidationFingerprint,
      transportPolicyFingerprint:
        "\(credentialExecutionFingerprint)|\(transportPolicyFingerprint)"
    )
  }

  public var displayIdentity: String {
    [
      fetchExecutionKey.digestHex,
      "\(target.width)x\(target.height)",
      contentMode.rawValue,
      geometryPolicyFingerprint,
      renderCacheAdmission.rawValue,
    ].joined(separator: "|")
  }

  public var containsCredentialHeaders: Bool {
    CredentialHeaderPolicy.containsSensitiveHeader(
      headers,
      additionalSensitiveNames: credentialHeaderNames
    )
  }

  package func varySelection(fieldNames: [String]) -> HTTPVarySelection? {
    HTTPCachePolicy.varySelection(
      fieldNames: fieldNames,
      requestHeaders: headers,
      additionalSensitiveNames: credentialHeaderNames,
      sensitiveFingerprints: headerVariantFingerprints
    )
  }

  private var exactRequestHeaderFingerprint: String {
    let sensitiveNames = CredentialHeaderPolicy.sensitiveNamesPresent(
      in: headers,
      additionalSensitiveNames: credentialHeaderNames
    )
    var material = Data("fovea-exact-request-headers-v1\u{0}".utf8)
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
      material.append(contentsOf: name.utf8)
      material.append(0)
      if sensitiveNames.contains(name) {
        let fingerprint = headerVariantFingerprints[name]?.sha256Hex ?? "credential-generation"
        material.append(contentsOf: fingerprint.utf8)
      } else {
        material.append(contentsOf: value.utf8)
      }
      material.append(0)
    }
    return material.sha256Hex
  }

  private var credentialExecutionFingerprint: String {
    let names = CredentialHeaderPolicy.sensitiveNamesPresent(
      in: headers,
      additionalSensitiveNames: credentialHeaderNames
    ).sorted()
    var material = Data("fovea-credential-header-set-v2\u{0}".utf8)
    for name in names {
      material.append(contentsOf: name.utf8)
      material.append(0)
    }
    return material.sha256Hex
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

  private static func normalizedFingerprints(
    _ fingerprints: [String: HeaderVariantFingerprint]
  ) throws -> [String: HeaderVariantFingerprint] {
    var result: [String: HeaderVariantFingerprint] = [:]
    for (name, fingerprint) in fingerprints {
      let normalized = name.lowercased()
      guard isValidHeaderName(normalized) else {
        throw ImageRequestError.invalidHeaderName(name)
      }
      guard result[normalized] == nil else {
        throw ImageRequestError.duplicateHeaderName(normalized)
      }
      result[normalized] = fingerprint
    }
    return result
  }

  private static func normalizedHeaderNames(_ names: Set<String>) throws -> Set<String> {
    var result: Set<String> = []
    for name in names {
      let normalized = name.lowercased()
      guard isValidHeaderName(normalized) else {
        throw ImageRequestError.invalidHeaderName(name)
      }
      result.insert(normalized)
    }
    return result
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

extension ImageRequest {
  package func replacingCredentials(
    _ refreshed: CredentialRefreshResult
  ) throws -> ImageRequest {
    var mergedHeaders = CredentialHeaderPolicy.removingSensitiveHeaders(
      from: headers,
      additionalSensitiveNames: credentialHeaderNames
    )
    for (name, value) in refreshed.headers {
      mergedHeaders[name] = value
    }
    let refreshedCredentialNames = refreshed.credentialHeaderNames
      .union(refreshed.headers.keys.map { $0.lowercased() })
    var fingerprints = headerVariantFingerprints
    for (name, fingerprint) in refreshed.headerVariantFingerprints {
      fingerprints[name.lowercased()] = fingerprint
    }
    return try ImageRequest(
      url: url,
      logicalSource: logicalSource,
      target: target,
      contentMode: contentMode,
      geometryPolicyFingerprint: geometryPolicyFingerprint,
      renderCacheAdmission: renderCacheAdmission,
      namespace: namespace,
      authorizationContext: authorizationContext,
      credentialGeneration: refreshed.credentialGeneration,
      priority: priority,
      headers: mergedHeaders,
      credentialHeaderNames: refreshedCredentialNames,
      headerVariantFingerprints: fingerprints
    )
  }
}
