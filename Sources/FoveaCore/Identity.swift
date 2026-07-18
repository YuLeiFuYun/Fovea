import CryptoKit
import Foundation

public struct LogicalSourceID: Hashable, Sendable, Codable {
  public let value: String
  public init(_ value: String) { self.value = value }
  init(normalizedHTTPURL: URL) { self.value = normalizedHTTPURL.absoluteString }
}

public struct SecurityNamespaceID: Hashable, Sendable, Codable {
  public let value: String
  public init(_ value: String) { self.value = value }
  public static func publicNamespace(appID: String) -> Self { .init("public:\(appID)") }
}

public struct NamespaceGeneration: Hashable, Sendable, Codable {
  public let value: UInt64
  public init(_ value: UInt64) { self.value = value }
}

public struct AuthorizationContextID: Hashable, Sendable, Codable {
  public let value: String
  public init(_ value: String) { self.value = value }
  public static let `public` = AuthorizationContextID("public")
}

public struct CredentialGeneration: Hashable, Sendable, Codable {
  public let value: UInt64
  public init(_ value: UInt64) { self.value = value }
}

public struct FetchBaseKey: Hashable, Sendable, Codable {
  public let schemaVersion: UInt16
  public let source: LogicalSourceID
  public let namespace: SecurityNamespaceID
  public let authorizationContext: AuthorizationContextID
  public let method: String

  public init(
    schemaVersion: UInt16 = 1,
    source: LogicalSourceID,
    namespace: SecurityNamespaceID,
    authorizationContext: AuthorizationContextID = .public,
    method: String = "GET"
  ) {
    self.schemaVersion = schemaVersion
    self.source = source
    self.namespace = namespace
    self.authorizationContext = authorizationContext
    self.method = method.uppercased()
  }

  public var canonicalBytes: Data {
    var encoder = CanonicalEncoder()
    encoder.append(schemaVersion)
    encoder.append(source.value)
    encoder.append(namespace.value)
    encoder.append(authorizationContext.value)
    encoder.append(method)
    return encoder.data
  }

  public var digestHex: String { canonicalBytes.sha256Hex }
}

public struct FetchVariantKey: Hashable, Sendable, Codable {
  public let schemaVersion: UInt16
  public let baseDigest: String
  public let requestVariants: [String: String]

  public init(
    schemaVersion: UInt16 = 2,
    base: FetchBaseKey,
    requestVariants: [String: String] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.baseDigest = base.digestHex
    self.requestVariants = Dictionary(
      uniqueKeysWithValues: requestVariants.map { ($0.key.lowercased(), $0.value) }
    )
  }

  public var canonicalBytes: Data {
    var encoder = CanonicalEncoder()
    encoder.append(schemaVersion)
    encoder.append(baseDigest)
    encoder.append(UInt32(requestVariants.count))
    for (key, value) in requestVariants.sorted(by: { $0.key < $1.key }) {
      encoder.append(key)
      encoder.append(value)
    }
    return encoder.data
  }

  public var digestHex: String { canonicalBytes.sha256Hex }
}

public struct FetchExecutionKey: Hashable, Sendable, Codable {
  public let schemaVersion: UInt16
  public let baseDigest: String
  public let selectedVariantDigest: String?
  public let resolvedLocator: String
  public let requestHeaderFingerprint: String
  public let credentialGeneration: CredentialGeneration?
  public let revalidationFingerprint: String
  public let transportPolicyFingerprint: String

  public init(
    schemaVersion: UInt16 = 2,
    base: FetchBaseKey,
    selectedVariant: FetchVariantKey? = nil,
    resolvedLocator: String,
    requestHeaderFingerprint: String,
    credentialGeneration: CredentialGeneration? = nil,
    revalidationFingerprint: String = "unconditional",
    transportPolicyFingerprint: String = "phase0b-default"
  ) {
    self.schemaVersion = schemaVersion
    self.baseDigest = base.digestHex
    self.selectedVariantDigest = selectedVariant?.digestHex
    self.resolvedLocator = resolvedLocator
    self.requestHeaderFingerprint = requestHeaderFingerprint
    self.credentialGeneration = credentialGeneration
    self.revalidationFingerprint = revalidationFingerprint
    self.transportPolicyFingerprint = transportPolicyFingerprint
  }

  public var canonicalBytes: Data {
    var encoder = CanonicalEncoder()
    encoder.append(schemaVersion)
    encoder.append(baseDigest)
    encoder.appendOptional(selectedVariantDigest)
    encoder.append(resolvedLocator)
    encoder.append(requestHeaderFingerprint)
    encoder.appendOptional(credentialGeneration?.value)
    encoder.append(revalidationFingerprint)
    encoder.append(transportPolicyFingerprint)
    return encoder.data
  }

  public var digestHex: String { canonicalBytes.sha256Hex }
}

public enum ContentIDError: Error, Equatable, Sendable {
  case invalidDigest
  case invalidByteCount
}

public struct ContentID: Hashable, Sendable, Codable, CustomStringConvertible {
  public let digestHex: String
  public let byteCount: Int

  public init(data: Data) {
    self.digestHex = data.sha256Hex
    self.byteCount = data.count
  }

  public init(digestHex: String, byteCount: Int) throws {
    guard byteCount >= 0 else { throw ContentIDError.invalidByteCount }
    guard digestHex.utf8.count == 64,
      digestHex.utf8.allSatisfy({ byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      })
    else {
      throw ContentIDError.invalidDigest
    }
    self.digestHex = digestHex
    self.byteCount = byteCount
  }

  public var description: String { "sha256:\(digestHex):\(byteCount)" }

  private enum CodingKeys: String, CodingKey {
    case digestHex
    case byteCount
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      digestHex: container.decode(String.self, forKey: .digestHex),
      byteCount: container.decode(Int.self, forKey: .byteCount)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(digestHex, forKey: .digestHex)
    try container.encode(byteCount, forKey: .byteCount)
  }
}

public struct DecodeKey: Hashable, Sendable, Codable {
  public let contentID: ContentID
  public let targetWidth: Int
  public let targetHeight: Int
  public let decoderVersion: UInt16
}

public struct RenderKey: Hashable, Sendable, Codable {
  public let decodeKey: DecodeKey
  public let renderVersion: UInt16
}

private struct CanonicalEncoder {
  fileprivate var data = Data()

  mutating func append(_ value: UInt16) {
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
  }

  mutating func append(_ value: UInt32) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
  }

  mutating func append(_ value: UInt64) {
    for shift in stride(from: 56, through: 0, by: -8) {
      data.append(UInt8((value >> UInt64(shift)) & 0xff))
    }
  }

  mutating func append(_ value: String) {
    let bytes = Data(value.utf8)
    append(UInt32(bytes.count))
    data.append(bytes)
  }

  mutating func appendOptional(_ value: String?) {
    if let value {
      data.append(1)
      append(value)
    } else {
      data.append(0)
    }
  }

  mutating func appendOptional(_ value: UInt64?) {
    if let value {
      data.append(1)
      append(value)
    } else {
      data.append(0)
    }
  }
}

extension Data {
  var sha256Hex: String {
    SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
  }
}
