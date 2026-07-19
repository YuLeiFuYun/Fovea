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
  public let wasCreated: Bool

  public init(physicalID: PhysicalBlobID, byteCount: Int, wasCreated: Bool) {
    self.physicalID = physicalID
    self.byteCount = byteCount
    self.wasCreated = wasCreated
  }
}

public enum AkashicError: Error, Equatable, Sendable {
  case notFound
  case integrityMismatch
  case invalidManifest
  case storageUnavailable
}

public struct StoredContentReference: Hashable, Sendable, Codable {
  public let namespaceFingerprint: StorageNamespaceFingerprint
  public let contentID: String

  public init(
    namespaceFingerprint: StorageNamespaceFingerprint,
    contentID: String
  ) {
    self.namespaceFingerprint = namespaceFingerprint
    self.contentID = contentID
  }
}

public struct GarbageCollectionResult: Hashable, Sendable, Codable {
  public let removedBlobCount: Int
  public let removedByteCount: Int

  public init(removedBlobCount: Int, removedByteCount: Int) {
    self.removedBlobCount = removedBlobCount
    self.removedByteCount = removedByteCount
  }
}

public protocol OriginalEncodedMaintaining: OriginalEncodedStoring {
  func garbageCollect(
    retaining references: Set<StoredContentReference>
  ) async throws -> GarbageCollectionResult
}
