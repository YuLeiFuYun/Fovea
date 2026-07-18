import AkashicCore
import Foundation

public enum CacheDisposition: String, Codable, Hashable, Sendable {
  case reusable
  case noStore
  case privateNamespace
}

public struct RepresentationRecord: Codable, Hashable, Sendable {
  public static let currentSchemaVersion: UInt16 = 5

  public let recordSchemaVersion: UInt16
  public let securityNamespaceFingerprint: StorageNamespaceFingerprint
  public let namespaceGeneration: UInt64
  public let baseKeyDigest: String
  public let variantKeyDigest: String
  public let vary: HTTPVarySelection
  public let statusCode: Int
  public let requestTime: Date
  public let responseTime: Date
  public let responseDate: Date?
  public let expiresAt: Date?
  public let etag: String?
  public let lastModified: String?
  public let disposition: CacheDisposition
  public let contentID: String
  public let payloadLength: Int
  public let contentType: String?

  public init(
    recordSchemaVersion: UInt16 = RepresentationRecord.currentSchemaVersion,
    securityNamespace: String,
    namespaceGeneration: UInt64,
    baseKeyDigest: String,
    variantKeyDigest: String,
    vary: HTTPVarySelection = HTTPVarySelection(fieldNames: [], values: [:]),
    statusCode: Int,
    requestTime: Date,
    responseTime: Date,
    responseDate: Date?,
    expiresAt: Date?,
    etag: String?,
    lastModified: String?,
    disposition: CacheDisposition,
    contentID: String,
    payloadLength: Int,
    contentType: String?
  ) {
    self.recordSchemaVersion = recordSchemaVersion
    self.securityNamespaceFingerprint = StorageNamespaceFingerprint(namespace: securityNamespace)
    self.namespaceGeneration = namespaceGeneration
    self.baseKeyDigest = baseKeyDigest
    self.variantKeyDigest = variantKeyDigest
    self.vary = vary
    self.statusCode = statusCode
    self.requestTime = requestTime
    self.responseTime = responseTime
    self.responseDate = responseDate
    self.expiresAt = expiresAt
    self.etag = etag
    self.lastModified = lastModified
    self.disposition = disposition
    self.contentID = contentID
    self.payloadLength = payloadLength
    self.contentType = contentType
  }

  public func isFresh(at date: Date) -> Bool {
    guard disposition != .noStore, let expiresAt else { return false }
    return date < expiresAt
  }

  package var recencyDate: Date { responseDate ?? responseTime }
}

public protocol RepresentationRecordStoring: Sendable {
  func records(
    for baseKeyDigest: String,
    namespace: String,
    namespaceGeneration: UInt64
  ) async -> [RepresentationRecord]
  func put(_ record: RepresentationRecord) async throws
  func containsReference(
    to contentID: String,
    namespace: String,
    excludingVariantDigest: String?
  ) async -> Bool
  func remove(
    _ variantDigest: String,
    namespace: String,
    namespaceGeneration: UInt64
  ) async throws
  func removeAll(namespace: String) async throws
}

public actor RepresentationRecordStore: RepresentationRecordStoring {
  private nonisolated let ioExecutor = BlockingIOExecutor(
    label: "dev.fovea.http.representation-records"
  )

  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    ioExecutor.asUnownedSerialExecutor()
  }

  private struct Manifest: Codable {
    let schemaVersion: UInt16
    var records: [String: RepresentationRecord]
  }

  private struct LegacyRecordV4: Codable {
    let recordSchemaVersion: UInt16
    let securityNamespaceFingerprint: StorageNamespaceFingerprint
    let namespaceGeneration: UInt64
    let variantKeyDigest: String
    let statusCode: Int
    let requestTime: Date
    let responseTime: Date
    let expiresAt: Date?
    let etag: String?
    let lastModified: String?
    let disposition: CacheDisposition
    let contentID: String
    let payloadLength: Int
    let contentType: String?
  }

  private let fileURL: URL
  private var recordsByVariant: [String: RepresentationRecord]

  private init(root: URL) {
    self.fileURL = root.appendingPathComponent("representation-records.json")
    self.recordsByVariant = [:]
  }

  public static func open(root: URL) async throws -> RepresentationRecordStore {
    let store = RepresentationRecordStore(root: root)
    try await store.bootstrap(root: root)
    return store
  }

  private func bootstrap(root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

    let data = try Data(contentsOf: fileURL)
    if let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
      guard manifest.schemaVersion == RepresentationRecord.currentSchemaVersion,
        manifest.records.values.allSatisfy({
          $0.recordSchemaVersion == RepresentationRecord.currentSchemaVersion
        })
      else {
        throw AkashicError.invalidManifest
      }
      recordsByVariant = manifest.records
      return
    }

    if let legacy = try? JSONDecoder().decode([String: LegacyRecordV4].self, from: data),
      legacy.values.allSatisfy({ $0.recordSchemaVersion == 4 })
    {
      // Pre-release schema 4 cannot be migrated safely because it did not persist the base key
      // or Vary request selection. Treat it as a stable miss and rewrite only on the next valid put.
      recordsByVariant = [:]
      return
    }

    throw AkashicError.invalidManifest
  }

  public func records(
    for baseKeyDigest: String,
    namespace: String,
    namespaceGeneration: UInt64
  ) -> [RepresentationRecord] {
    let fingerprint = StorageNamespaceFingerprint(namespace: namespace)
    return recordsByVariant.values.filter { record in
      record.baseKeyDigest == baseKeyDigest
        && record.securityNamespaceFingerprint == fingerprint
        && record.namespaceGeneration == namespaceGeneration
    }
  }

  /// Only for package tests and diagnostics. Product lookup must start from the base key.
  package func record(for variantDigest: String) -> RepresentationRecord? {
    recordsByVariant[variantDigest]
  }

  public func put(_ record: RepresentationRecord) throws {
    guard record.recordSchemaVersion == RepresentationRecord.currentSchemaVersion else {
      throw AkashicError.invalidManifest
    }
    var next = recordsByVariant
    next[record.variantKeyDigest] = record
    try persist(next)
    recordsByVariant = next
  }

  public func containsReference(
    to contentID: String,
    namespace: String,
    excludingVariantDigest: String? = nil
  ) -> Bool {
    let fingerprint = StorageNamespaceFingerprint(namespace: namespace)
    return recordsByVariant.values.contains { record in
      record.contentID == contentID
        && record.securityNamespaceFingerprint == fingerprint
        && record.variantKeyDigest != excludingVariantDigest
    }
  }

  public func remove(
    _ variantDigest: String,
    namespace: String,
    namespaceGeneration: UInt64
  ) throws {
    let fingerprint = StorageNamespaceFingerprint(namespace: namespace)
    guard let record = recordsByVariant[variantDigest],
      record.securityNamespaceFingerprint == fingerprint,
      record.namespaceGeneration == namespaceGeneration
    else { return }
    var next = recordsByVariant
    next.removeValue(forKey: variantDigest)
    try persist(next)
    recordsByVariant = next
  }

  public func removeAll(namespace: String) throws {
    let fingerprint = StorageNamespaceFingerprint(namespace: namespace)
    let next = recordsByVariant.filter { $0.value.securityNamespaceFingerprint != fingerprint }
    guard next.count != recordsByVariant.count else { return }
    try persist(next)
    recordsByVariant = next
  }

  private func persist(_ records: [String: RepresentationRecord]) throws {
    let manifest = Manifest(
      schemaVersion: RepresentationRecord.currentSchemaVersion,
      records: records
    )
    let data = try JSONEncoder().encode(manifest)
    try data.write(to: fileURL, options: [.atomic])
  }
}
