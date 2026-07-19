import Foundation

/// 校验持久层使用的 `sha256:<digest>:<byte-count>` 规范字符串。
package enum StoredContentIdentifier {
  package static func byteCount(
    in value: String,
    expectedByteCount: Int? = nil
  ) -> Int? {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3,
      parts[0] == "sha256",
      parts[1].utf8.count == 64,
      parts[1].utf8.allSatisfy(Self.isLowercaseHex),
      let byteCount = parseCanonicalNonnegativeInteger(parts[2]),
      expectedByteCount.map({ $0 == byteCount }) ?? true
    else { return nil }
    return byteCount
  }

  package static func isLowercaseSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy(Self.isLowercaseHex)
  }

  private static func parseCanonicalNonnegativeInteger(_ value: Substring) -> Int? {
    guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else {
      return nil
    }
    if value.count > 1, value.first == "0" { return nil }
    guard let parsed = Int(value), parsed >= 0, String(parsed) == value else { return nil }
    return parsed
  }

  private static func isLowercaseHex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...102).contains(byte)
  }
}
