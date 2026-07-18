import AkashicCore
import Foundation

public protocol OriginalEncodedStoring: Sendable {
  func read(contentID: String, namespace: String) async throws -> Data

  @discardableResult
  func commit(data: Data, contentID: String, namespace: String) async throws -> StoredBlob

  func physicalID(contentID: String, namespace: String) async -> PhysicalBlobID?
  func remove(contentID: String, namespace: String) async throws
  func removeAll(namespace: String) async throws
}

extension OriginalEncodedStore: OriginalEncodedStoring {}
