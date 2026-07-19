import AkashicCore
import CryptoKit
import Foundation

public actor OriginalEncodedStore: OriginalEncodedMaintaining {
  private nonisolated let ioExecutor = BlockingIOExecutor(
    label: "dev.fovea.akashic.original-encoded")

  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    ioExecutor.asUnownedSerialExecutor()
  }
  private static let manifestSchemaVersion: UInt16 = 4

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

  private struct Entry: Codable, Equatable {
    let physicalID: PhysicalBlobID
    let namespaceFingerprint: StorageNamespaceFingerprint
    let contentID: String
    let byteCount: Int
    let lastAccess: Date
  }

  private let blobs: URL
  private let manifestURL: URL
  private let softLimitBytes: Int
  private var manifest: Manifest

  private init(root: URL, softLimitBytes: Int) {
    self.blobs = root.appendingPathComponent("blobs", isDirectory: true)
    self.manifestURL = root.appendingPathComponent("manifest.json")
    self.softLimitBytes = max(1, softLimitBytes)
    self.manifest = Manifest()
  }

  public static func open(
    root: URL,
    softLimitBytes: Int = 128 * 1024 * 1024
  ) async throws -> OriginalEncodedStore {
    let store = OriginalEncodedStore(root: root, softLimitBytes: softLimitBytes)
    try await store.bootstrap(root: root)
    return store
  }

  private func bootstrap(root: URL) throws {
    try StorageDirectorySecurity.prepareDirectory(root)
    try StorageDirectorySecurity.prepareDirectory(blobs)
    if FileManager.default.fileExists(atPath: manifestURL.path) {
      let data = try Data(contentsOf: manifestURL)
      let decoded = try JSONDecoder().decode(Manifest.self, from: data)
      guard decoded.schemaVersion == Self.manifestSchemaVersion else {
        throw AkashicError.invalidManifest
      }
      manifest = decoded
    }
    try reconcileStorageAfterBootstrap()
  }

  public func read(contentID: String, namespace: String) throws -> Data {
    let namespaceFingerprint = StorageNamespaceFingerprint(namespace: namespace)
    let key = manifestKey(contentID: contentID, namespaceFingerprint: namespaceFingerprint)
    guard var entry = manifest.entries[key], entry.namespaceFingerprint == namespaceFingerprint
    else {
      throw AkashicError.notFound
    }
    let url = blobURL(entry.physicalID)
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
      data.count == entry.byteCount,
      contentIDMatches(data: data, contentID: contentID)
    else {
      var next = manifest
      next.entries.removeValue(forKey: key)
      if (try? persistManifest(next)) != nil {
        manifest = next
        try? FileManager.default.removeItem(at: url)
      }
      throw AkashicError.integrityMismatch
    }
    entry = Entry(
      physicalID: entry.physicalID,
      namespaceFingerprint: entry.namespaceFingerprint,
      contentID: entry.contentID,
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
    let namespaceFingerprint = StorageNamespaceFingerprint(namespace: namespace)
    let key = manifestKey(contentID: contentID, namespaceFingerprint: namespaceFingerprint)
    let existing = manifest.entries[key]
    if let existing, existing.namespaceFingerprint == namespaceFingerprint {
      let existingURL = blobURL(existing.physicalID)
      if let existingData = try? Data(contentsOf: existingURL, options: .mappedIfSafe),
        existingData.count == existing.byteCount,
        contentIDMatches(data: existingData, contentID: contentID)
      {
        return StoredBlob(
          physicalID: existing.physicalID, byteCount: existing.byteCount, wasCreated: false)
      }
    }

    let physicalID = PhysicalBlobID()
    let temporary = blobs.appendingPathComponent(".tmp-\(UUID().uuidString)")
    let destination = blobURL(physicalID)
    try data.write(to: temporary, options: [.atomic])
    try StorageDirectorySecurity.securePublishedFile(temporary)
    do {
      try FileManager.default.moveItem(at: temporary, to: destination)
      try StorageDirectorySecurity.securePublishedFile(destination)
      var next = manifest
      next.entries[key] = Entry(
        physicalID: physicalID,
        namespaceFingerprint: namespaceFingerprint,
        contentID: contentID,
        byteCount: data.count,
        lastAccess: Date()
      )
      try persistManifest(next)
      manifest = next
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      try? FileManager.default.removeItem(at: destination)
      throw error
    }

    if let existing, existing.physicalID != physicalID {
      try? FileManager.default.removeItem(at: blobURL(existing.physicalID))
    }
    // 回收失败不得回滚已经原子发布的数据块；下次写入或垃圾回收会继续收敛。
    try? trimIfNeeded()
    return StoredBlob(physicalID: physicalID, byteCount: data.count, wasCreated: true)
  }

  public func garbageCollect(
    retaining references: Set<StoredContentReference>
  ) async throws -> GarbageCollectionResult {
    let victims = manifest.entries.filter { _, entry in
      !references.contains(
        StoredContentReference(
          namespaceFingerprint: entry.namespaceFingerprint,
          contentID: entry.contentID
        )
      )
    }
    guard !victims.isEmpty else {
      return GarbageCollectionResult(removedBlobCount: 0, removedByteCount: 0)
    }

    var next = manifest
    for key in victims.keys { next.entries.removeValue(forKey: key) }
    try persistManifest(next)
    manifest = next

    var firstError: (any Error)?
    var removedCount = 0
    var removedBytes = 0
    for entry in victims.values {
      do {
        try FileManager.default.removeItem(at: blobURL(entry.physicalID))
        removedCount += 1
        removedBytes += entry.byteCount
      } catch let error as CocoaError where error.code == .fileNoSuchFile {
        removedCount += 1
        removedBytes += entry.byteCount
      } catch {
        firstError = firstError ?? error
      }
    }
    if firstError != nil { throw AkashicError.storageUnavailable }
    return GarbageCollectionResult(
      removedBlobCount: removedCount,
      removedByteCount: removedBytes
    )
  }

  public func physicalID(contentID: String, namespace: String) -> PhysicalBlobID? {
    let namespaceFingerprint = StorageNamespaceFingerprint(namespace: namespace)
    let entry = manifest.entries[
      manifestKey(contentID: contentID, namespaceFingerprint: namespaceFingerprint)
    ]
    return entry?.namespaceFingerprint == namespaceFingerprint ? entry?.physicalID : nil
  }

  public func remove(contentID: String, namespace: String) throws {
    let namespaceFingerprint = StorageNamespaceFingerprint(namespace: namespace)
    let key = manifestKey(contentID: contentID, namespaceFingerprint: namespaceFingerprint)
    guard let entry = manifest.entries[key] else { return }

    var next = manifest
    next.entries.removeValue(forKey: key)
    try persistManifest(next)
    manifest = next
    try removeFileIfPresent(blobURL(entry.physicalID))
  }

  public func removeAll(namespace: String) throws {
    let namespaceFingerprint = StorageNamespaceFingerprint(namespace: namespace)
    let victims = manifest.entries.filter {
      $0.value.namespaceFingerprint == namespaceFingerprint
    }
    guard !victims.isEmpty else { return }

    var next = manifest
    for key in victims.keys { next.entries.removeValue(forKey: key) }
    try persistManifest(next)
    manifest = next

    var firstFailure: (any Error)?
    for entry in victims.values {
      do {
        try removeFileIfPresent(blobURL(entry.physicalID))
      } catch {
        firstFailure = firstFailure ?? error
      }
    }
    if let firstFailure { throw firstFailure }
  }

  private func removeFileIfPresent(_ url: URL) throws {
    do {
      try FileManager.default.removeItem(at: url)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    }
  }

  private func reconcileStorageAfterBootstrap() throws {
    let fileManager = FileManager.default
    let files = try fileManager.contentsOfDirectory(
      at: blobs,
      includingPropertiesForKeys: nil,
      options: [.skipsSubdirectoryDescendants]
    )
    let referencedNames = Set(manifest.entries.values.map { $0.physicalID.description })
    for file in files {
      let name = file.lastPathComponent
      if name.hasPrefix(".tmp-") || !referencedNames.contains(name) {
        try fileManager.removeItem(at: file)
      }
    }

    var next = manifest
    for (key, entry) in manifest.entries {
      let url = blobURL(entry.physicalID)
      guard fileManager.fileExists(atPath: url.path) else {
        next.entries.removeValue(forKey: key)
        continue
      }
      try StorageDirectorySecurity.securePublishedFile(url)
    }
    if next.entries != manifest.entries {
      try persistManifest(next)
      manifest = next
    }
  }

  private func trimIfNeeded() throws {
    var total = manifest.entries.values.reduce(0) { $0 + $1.byteCount }
    guard total > softLimitBytes else { return }

    var next = manifest
    var victims: [Entry] = []
    for (key, entry) in manifest.entries.sorted(by: { $0.value.lastAccess < $1.value.lastAccess }) {
      next.entries.removeValue(forKey: key)
      victims.append(entry)
      total -= entry.byteCount
      if total <= softLimitBytes { break }
    }
    try persistManifest(next)
    manifest = next
    for entry in victims {
      try? FileManager.default.removeItem(at: blobURL(entry.physicalID))
    }
  }

  private func persistManifest(_ manifest: Manifest) throws {
    let data = try JSONEncoder().encode(manifest)
    try data.write(to: manifestURL, options: [.atomic])
    try StorageDirectorySecurity.securePublishedFile(manifestURL)
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

  private func manifestKey(
    contentID: String,
    namespaceFingerprint: StorageNamespaceFingerprint
  ) -> String {
    let digest = SHA256.hash(
      data: Data("\(namespaceFingerprint.value)\u{0}\(contentID)".utf8)
    )
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
