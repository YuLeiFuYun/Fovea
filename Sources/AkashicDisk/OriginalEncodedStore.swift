import AkashicCore
import CryptoKit
import Foundation

public actor OriginalEncodedStore {
  private struct Manifest: Codable {
    var entries: [String: Entry] = [:]
  }

  private struct Entry: Codable {
    let physicalID: PhysicalBlobID
    let byteCount: Int
    let lastAccess: Date
  }

  private let root: URL
  private let blobs: URL
  private let manifestURL: URL
  private let softLimitBytes: Int
  private var manifest: Manifest

  public init(root: URL, softLimitBytes: Int = 128 * 1024 * 1024) throws {
    self.root = root
    self.blobs = root.appendingPathComponent("blobs", isDirectory: true)
    self.manifestURL = root.appendingPathComponent("manifest.json")
    self.softLimitBytes = max(1, softLimitBytes)
    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
    if let data = try? Data(contentsOf: manifestURL) {
      self.manifest = (try? JSONDecoder().decode(Manifest.self, from: data)) ?? Manifest()
    } else {
      self.manifest = Manifest()
    }
  }

  public func read(contentID: String, namespace: String) throws -> Data {
    let key = manifestKey(contentID: contentID, namespace: namespace)
    guard var entry = manifest.entries[key] else { throw AkashicError.notFound }
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
    entry = Entry(physicalID: entry.physicalID, byteCount: entry.byteCount, lastAccess: Date())
    manifest.entries[key] = entry
    return data
  }

  @discardableResult
  public func commit(data: Data, contentID: String, namespace: String) throws -> StoredBlob {
    guard data.count <= softLimitBytes else {
      throw AkashicError.storageUnavailable
    }
    guard contentIDMatches(data: data, contentID: contentID) else {
      throw AkashicError.integrityMismatch
    }
    let key = manifestKey(contentID: contentID, namespace: namespace)
    if let existing = manifest.entries[key],
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
        physicalID: physicalID, byteCount: data.count, lastAccess: Date())
      try persistManifest()
      try trimIfNeeded()
      return StoredBlob(physicalID: physicalID, byteCount: data.count)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  public func physicalID(contentID: String, namespace: String) -> PhysicalBlobID? {
    manifest.entries[manifestKey(contentID: contentID, namespace: namespace)]?.physicalID
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
