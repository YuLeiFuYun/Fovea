import AkashicCore
import Foundation

public enum CacheDisposition: String, Codable, Hashable, Sendable {
  case reusable
  case noStore
  case privateNamespace
}

public struct RepresentationRecord: Codable, Hashable, Sendable {
  public static let currentSchemaVersion: UInt16 = 4

  public let recordSchemaVersion: UInt16
  public let securityNamespaceFingerprint: StorageNamespaceFingerprint
  public let namespaceGeneration: UInt64
  public let variantKeyDigest: String
  public let statusCode: Int
  public let requestTime: Date
  public let responseTime: Date
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
    namespaceGeneration: UInt64 = 0,
    variantKeyDigest: String,
    statusCode: Int,
    requestTime: Date,
    responseTime: Date,
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
    self.variantKeyDigest = variantKeyDigest
    self.statusCode = statusCode
    self.requestTime = requestTime
    self.responseTime = responseTime
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
}

public protocol RepresentationRecordStoring: Sendable {
  func record(
    for variantDigest: String,
    namespace: String,
    namespaceGeneration: UInt64
  ) async -> RepresentationRecord?
  func put(_ record: RepresentationRecord) async throws
  func remove(_ variantDigest: String) async throws
  func removeAll(namespace: String) async throws
}

public actor RepresentationRecordStore: RepresentationRecordStoring {
  private nonisolated let ioExecutor = BlockingIOExecutor(
    label: "dev.fovea.http.representation-records"
  )

  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    ioExecutor.asUnownedSerialExecutor()
  }

  private let fileURL: URL
  private var records: [String: RepresentationRecord]

  private init(root: URL) {
    self.fileURL = root.appendingPathComponent("representation-records.json")
    self.records = [:]
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
    let decoded = try JSONDecoder().decode([String: RepresentationRecord].self, from: data)
    guard
      decoded.values.allSatisfy({
        $0.recordSchemaVersion == RepresentationRecord.currentSchemaVersion
      })
    else {
      throw AkashicError.invalidManifest
    }
    records = decoded
  }

  public func record(
    for variantDigest: String,
    namespace: String,
    namespaceGeneration: UInt64
  ) -> RepresentationRecord? {
    let fingerprint = StorageNamespaceFingerprint(namespace: namespace)
    guard let record = records[variantDigest],
      record.securityNamespaceFingerprint == fingerprint,
      record.namespaceGeneration == namespaceGeneration
    else { return nil }
    return record
  }

  /// 仅用于测试和诊断；产品路径必须同时提供 namespace。
  public func record(for variantDigest: String) -> RepresentationRecord? {
    records[variantDigest]
  }

  public func put(_ record: RepresentationRecord) throws {
    guard record.recordSchemaVersion == RepresentationRecord.currentSchemaVersion else {
      throw AkashicError.invalidManifest
    }
    var next = records
    next[record.variantKeyDigest] = record
    try persist(next)
    records = next
  }

  public func remove(_ variantDigest: String) throws {
    guard records[variantDigest] != nil else { return }
    var next = records
    next.removeValue(forKey: variantDigest)
    try persist(next)
    records = next
  }

  public func removeAll(namespace: String) throws {
    let fingerprint = StorageNamespaceFingerprint(namespace: namespace)
    let next = records.filter { $0.value.securityNamespaceFingerprint != fingerprint }
    guard next.count != records.count else { return }
    try persist(next)
    records = next
  }

  private func persist(_ records: [String: RepresentationRecord]) throws {
    let data = try JSONEncoder().encode(records)
    try data.write(to: fileURL, options: [.atomic])
  }
}
