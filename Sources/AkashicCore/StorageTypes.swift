import CryptoKit
import Foundation

public struct PhysicalBlobID: Hashable, Sendable, Codable, CustomStringConvertible {
  public let rawValue: UUID
  public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
  public var description: String { rawValue.uuidString.lowercased() }
}

public struct StorageNamespaceFingerprint: Hashable, Sendable, Codable, CustomStringConvertible {
  public let value: String

  public init(namespace: String) {
    let domainSeparated = Data("fovea-storage-namespace-v1\u{0}\(namespace)".utf8)
    self.value = SHA256.hash(data: domainSeparated)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  public var description: String { value }
}

public struct StoredBlob: Hashable, Sendable, Codable {
  public let physicalID: PhysicalBlobID
  public let byteCount: Int

  public init(physicalID: PhysicalBlobID, byteCount: Int) {
    self.physicalID = physicalID
    self.byteCount = byteCount
  }
}

public enum AkashicError: Error, Equatable, Sendable {
  case notFound
  case integrityMismatch
  case invalidManifest
  case storageUnavailable
}
