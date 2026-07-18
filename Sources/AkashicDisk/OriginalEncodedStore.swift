import AkashicCore
import CryptoKit
import Foundation

public actor OriginalEncodedStore {
  private static let manifestSchemaVersion: UInt16 = 2

  private struct Manifest: Codable {
    let schemaVersion: UInt16
    var entries: [String: Entry]

    init(
      schemaVersion: UInt16 = OriginalEncodedStore.manifestSchemaVersion,
      entries: [String: Entry] = [:]
    ) {
      self.schemaVersion = schemaVersion
      self.entries = entries
    }
  }

  private struct Entry: Codable {
    let physicalID: PhysicalBlobID
    let namespace: String
    let byteCount: Int
    let lastAccess: Date
  }

  private let blobs: URL
  private let manifestURL: URL
  private let softLimitBytes: Int
  private var manifest: Manifest

  public init(root: URL, softLimitBytes: Int = 128 * 1024 * 1024) throws {
    let blobs = root.appendingPathComponent("blobs", isDirectory: true)
    let manifestURL = root.appendingPathComponent("manifest.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)

    var loaded = Manifest()
    var resetStore = false
    if let data = try? Data(contentsOf: manifestURL),
      let decoded = try? JSONDecoder().decode(Manifest.self, from: data),
      decoded.schemaVersion == Self.manifestSchemaVersion
    {
      loaded = decoded
    } else if FileManager.default.fileExists(atPath: manifestURL.path) {
      resetStore = true
    }

    if resetStore {
      try? FileManager.default.removeItem(at: blobs)
      try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(loaded)
      try data.write(to: manifestURL, options: [.atomic])
    }

    self.blobs = blobs
    self.manifestURL = manifestURL
    self.softLimitBytes = max(1, softLimitBytes)
    self.manifest = loaded
  }

  public func read(contentID: String, namespace: String) throws -> Data {
    let key = manifestKey(contentID: contentID, namespace: namespace)
    guard var entry = manifest.entries[key], entry.namespace == namespace else {
      throw AkashicError.notFound
    }
    let url = blobURL(entry.physicalID)
    guard let data = try? Data(contentsOf: url),
      data.count == entry.byteCount,
      contentIDMatches(data: data, contentID: contentID)
    else {
      manifest.entries.removeValue(forKey: key)
      try? FileManager.default.removeItem(at: url)
      try? persistManifest()
      throw AkashicError.integrityMismatch
    }
    entry = Entry(
      physicalID: entry.physicalID,
      namespace: entry.namespace,
      byteCount: entry.byteCount,
      lastAccess: Date()
    )
    manifest.entries[key] = entry
    return data
  }

  @discardableResult
  public func commit(data: Data, contentID: String, namespace: String) throws -> StoredBlob {
    guard data.count <= softLimitBytes else { throw AkashicError.storageUnavailable }
    guard contentIDMatches(data: data, contentID: contentID) else {
      throw AkashicError.integrityMismatch
    }
    let key = manifestKey(contentID: contentID, namespace: namespace)
    if let existing = manifest.entries[key],
      existing.namespace == namespace,
      FileManager.default.fileExists(atPath: blobURL(existing.physicalID).path)
    {
      return StoredBlob(physicalID: existing.physicalID, byteCount: existing.byteCount)
    }

    let physicalID = PhysicalBlobID()
    let temporary = blobs.appendingPathComponent(".tmp-\(UUID().uuidString)")
    let destination = blobURL(physicalID)
    try data.write(to: temporary, options: [.atomic])
    do {
      try FileManager.default.moveItem(at: temporary, to: destination)
      manifest.entries[key] = Entry(
        physicalID: physicalID,
        namespace: namespace,
        byteCount: data.count,
        lastAccess: Date()
      )
      try persistManifest()
      try trimIfNeeded()
      return StoredBlob(physicalID: physicalID, byteCount: data.count)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      try? FileManager.default.removeItem(at: destination)
      manifest.entries.removeValue(forKey: key)
      throw error
    }
  }

  public func physicalID(contentID: String, namespace: String) -> PhysicalBlobID? {
    let entry = manifest.entries[manifestKey(contentID: contentID, namespace: namespace)]
    return entry?.namespace == namespace ? entry?.physicalID : nil
  }

  public func remove(contentID: String, namespace: String) throws {
    let key = manifestKey(contentID: contentID, namespace: namespace)
    guard let entry = manifest.entries.removeValue(forKey: key) else { return }
    try? FileManager.default.removeItem(at: blobURL(entry.physicalID))
    try persistManifest()
  }

  public func removeAll(namespace: String) throws {
    let victims = manifest.entries.filter { $0.value.namespace == namespace }
    guard !victims.isEmpty else { return }
    for (key, entry) in victims {
      try? FileManager.default.removeItem(at: blobURL(entry.physicalID))
      manifest.entries.removeValue(forKey: key)
    }
    try persistManifest()
  }

  public func removeAll() throws {
    try? FileManager.default.removeItem(at: blobs)
    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
    manifest = Manifest()
    try persistManifest()
  }

  private func trimIfNeeded() throws {
    var total = manifest.entries.values.reduce(0) { $0 + $1.byteCount }
    guard total > softLimitBytes else { return }
    for (key, entry) in manifest.entries.sorted(by: { $0.value.lastAccess < $1.value.lastAccess }) {
      try? FileManager.default.removeItem(at: blobURL(entry.physicalID))
      manifest.entries.removeValue(forKey: key)
      total -= entry.byteCount
      if total <= softLimitBytes { break }
    }
    try persistManifest()
  }

  private func persistManifest() throws {
    let data = try JSONEncoder().encode(manifest)
    try data.write(to: manifestURL, options: [.atomic])
  }

  private func blobURL(_ id: PhysicalBlobID) -> URL {
    blobs.appendingPathComponent(id.description, isDirectory: false)
  }

  private func contentIDMatches(data: Data, contentID: String) -> Bool {
    let parts = contentID.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3,
      parts[0] == "sha256",
      let expectedLength = Int(parts[2]),
      expectedLength == data.count
    else { return false }
    let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return actual == parts[1]
  }

  private func manifestKey(contentID: String, namespace: String) -> String {
    let digest = SHA256.hash(data: Data("\(namespace)\u{0}\(contentID)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
