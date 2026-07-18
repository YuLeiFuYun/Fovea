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
}

public struct HeaderVariantFingerprint: Codable, Hashable, Sendable, CustomStringConvertible {
  public let sha256Hex: String

  public init(sha256Hex: String) throws {
    guard sha256Hex.utf8.count == 64,
      sha256Hex.utf8.allSatisfy({ byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      })
    else {
      throw HeaderVariantFingerprintError.invalidSHA256
    }
    self.sha256Hex = sha256Hex
  }

  public var description: String { sha256Hex }
}

public enum HeaderVariantFingerprintError: Error, Equatable, Sendable {
  case invalidSHA256
}
