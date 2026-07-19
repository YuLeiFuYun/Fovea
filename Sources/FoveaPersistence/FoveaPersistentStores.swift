import AkashicDisk
import Foundation
import FoveaHTTP

public struct FoveaPersistentStores: Sendable {
  public static let currentCompatibilityFingerprint =
    "fovea-store-v1:original-\(OriginalEncodedStore.currentSchemaVersion):representation-\(RepresentationRecord.currentSchemaVersion)"

  public let generation: StoreGenerationHandle
  public let encoded: OriginalEncodedStore
  public let records: RepresentationRecordStore

  public static func open(
    root: URL,
    compatibilityFingerprint: String = currentCompatibilityFingerprint,
    encodedSoftLimitBytes: Int = 128 * 1024 * 1024
  ) async throws -> FoveaPersistentStores {
    let generation = try StoreGenerationDirectory.open(
      root: root,
      compatibilityFingerprint: compatibilityFingerprint
    )
    let encoded = try await OriginalEncodedStore.open(
      root: generation.root.appendingPathComponent("encoded", isDirectory: true),
      softLimitBytes: encodedSoftLimitBytes
    )
    let records = try await RepresentationRecordStore.open(
      root: generation.root.appendingPathComponent("records", isDirectory: true)
    )
    return FoveaPersistentStores(
      generation: generation,
      encoded: encoded,
      records: records
    )
  }
}
