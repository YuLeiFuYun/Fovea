import Foundation

public enum CacheDisposition: String, Codable, Hashable, Sendable {
  case reusable
  case noStore
  case privateNamespace
}

public struct RepresentationRecord: Codable, Hashable, Sendable {
  public let recordSchemaVersion: UInt16
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
    recordSchemaVersion: UInt16 = 1,
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
  func record(for variantDigest: String) async -> RepresentationRecord?
  func put(_ record: RepresentationRecord) async throws
  func remove(_ variantDigest: String) async throws
}

public actor RepresentationRecordStore: RepresentationRecordStoring {
  private let fileURL: URL
  private var records: [String: RepresentationRecord]

  public init(root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    self.fileURL = root.appendingPathComponent("representation-records.json")
    if let data = try? Data(contentsOf: fileURL) {
      self.records =
        (try? JSONDecoder().decode([String: RepresentationRecord].self, from: data)) ?? [:]
    } else {
      self.records = [:]
    }
  }

  public func record(for variantDigest: String) -> RepresentationRecord? {
    records[variantDigest]
  }

  public func put(_ record: RepresentationRecord) throws {
    records[record.variantKeyDigest] = record
    try persist()
  }

  public func remove(_ variantDigest: String) throws {
    records.removeValue(forKey: variantDigest)
    try persist()
  }

  private func persist() throws {
    let data = try JSONEncoder().encode(records)
    try data.write(to: fileURL, options: [.atomic])
  }
}
