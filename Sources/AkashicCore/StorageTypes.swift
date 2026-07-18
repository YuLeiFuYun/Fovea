import Foundation

public struct PhysicalBlobID: Hashable, Sendable, Codable, CustomStringConvertible {
  public let rawValue: UUID
  public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
  public var description: String { rawValue.uuidString.lowercased() }
}

public struct StoreGenerationID: Hashable, Sendable, Codable {
  public let rawValue: UUID
  public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
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
