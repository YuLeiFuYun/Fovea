import AkashicCore
import Foundation

public enum HTTPVaryValue: Codable, Hashable, Sendable {
  case absent
  case field(String)
  case fingerprint(String)

  package var canonicalValue: String {
    switch self {
    case .absent: "a:"
    case .field(let value): "v:\(value)"
    case .fingerprint(let value): "f:\(value)"
    }
  }
}

public struct HTTPVarySelection: Codable, Hashable, Sendable {
  public let fieldNames: [String]
  public let values: [String: HTTPVaryValue]

  public init(fieldNames: [String], values: [String: HTTPVaryValue]) {
    let names = Array(Set(fieldNames.map { $0.lowercased() })).sorted()
    self.fieldNames = names
    self.values = Dictionary(
      uniqueKeysWithValues: names.compactMap { name in
        values[name].map { (name, $0) }
      })
  }

  package var canonicalRequestVariants: [String: String] {
    Dictionary(
      uniqueKeysWithValues: fieldNames.compactMap { name in
        values[name].map { (name, $0.canonicalValue) }
      })
  }

  private enum CodingKeys: String, CodingKey {
    case fieldNames
    case values
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let fieldNames = try container.decode([String].self, forKey: .fieldNames)
    let values = try container.decode([String: HTTPVaryValue].self, forKey: .values)
    let canonicalNames = Array(Set(fieldNames.map { $0.lowercased() })).sorted()
    guard fieldNames == canonicalNames,
      Set(values.keys) == Set(fieldNames),
      values.allSatisfy({ _, value in
        if case .fingerprint(let fingerprint) = value {
          return StoredContentIdentifier.isLowercaseSHA256(fingerprint)
        }
        return true
      })
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .fieldNames,
        in: container,
        debugDescription: "HTTP Vary selection is not canonical"
      )
    }
    self.fieldNames = fieldNames
    self.values = values
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(fieldNames, forKey: .fieldNames)
    try container.encode(values, forKey: .values)
  }
}

public struct HeaderVariantFingerprint: Codable, Hashable, Sendable, CustomStringConvertible {
  public let sha256Hex: String

  public init(sha256Hex: String) throws {
    guard StoredContentIdentifier.isLowercaseSHA256(sha256Hex) else {
      throw HeaderVariantFingerprintError.invalidSHA256
    }
    self.sha256Hex = sha256Hex
  }

  public var description: String { sha256Hex }

  private enum CodingKeys: String, CodingKey {
    case sha256Hex
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(sha256Hex: container.decode(String.self, forKey: .sha256Hex))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sha256Hex, forKey: .sha256Hex)
  }
}

public enum HeaderVariantFingerprintError: Error, Equatable, Sendable {
  case invalidSHA256
}
