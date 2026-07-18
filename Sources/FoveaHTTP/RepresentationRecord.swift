import Foundation

public enum CacheDisposition: String, Codable, Hashable, Sendable {
  case reusable
  case noStore
  case privateNamespace
}

public struct RepresentationRecord: Codable, Hashable, Sendable {
  public let recordSchemaVersion: UInt16
  public let securityNamespace: String
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
    recordSchemaVersion: UInt16 = 2,
    securityNamespace: String,
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
    self.securityNamespace = securityNamespace
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
  func removeAll(namespace: String) async throws
}

public actor RepresentationRecordStore: RepresentationRecordStoring {
  private let fileURL: URL
  private var records: [String: RepresentationRecord]

  public init(root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    self.fileURL = root.appendingPathComponent("representation-records.json")
    if let data = try? Data(contentsOf: fileURL),
      let decoded = try? JSONDecoder().decode([String: RepresentationRecord].self, from: data)
    {
      self.records = decoded
    } else {
      self.records = [:]
      try? FileManager.default.removeItem(at: fileURL)
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

  public func removeAll(namespace: String) throws {
    let keys = records.compactMap { key, record in
      record.securityNamespace == namespace ? key : nil
    }
    guard !keys.isEmpty else { return }
    for key in keys { records.removeValue(forKey: key) }
    try persist()
  }

  private func persist() throws {
    let data = try JSONEncoder().encode(records)
    try data.write(to: fileURL, options: [.atomic])
  }
}
