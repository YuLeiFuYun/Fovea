import AkashicCore
import Darwin
import Foundation

public struct StoreGenerationHandle: Hashable, Sendable {
  public let identifier: String
  public let compatibilityFingerprint: String
  public let root: URL

  public init(identifier: String, compatibilityFingerprint: String, root: URL) {
    self.identifier = identifier
    self.compatibilityFingerprint = compatibilityFingerprint
    self.root = root
  }
}

package enum StoreGenerationSwitchPoint: CaseIterable, Sendable {
  case afterGenerationDirectoryCreated
  case afterGenerationDescriptorPublished
  case afterPointerStaged
  case afterPointerPublished
}

public enum StoreGenerationDirectory {
  private static let schemaVersion: UInt16 = 1
  private static let processLock = NSLock()
  private static let currentName = "current-generation.json"
  private static let generationsName = "generations"
  private static let descriptorName = "generation.json"
  private static let temporaryPrefix = ".current-generation.tmp-"

  private struct Descriptor: Codable, Hashable {
    let schemaVersion: UInt16
    let identifier: String
    let compatibilityFingerprint: String
    let createdAt: Date
  }

  private struct Pointer: Codable {
    let schemaVersion: UInt16
    let identifier: String
    let compatibilityFingerprint: String
  }

  private struct SchemaEnvelope: Decodable {
    let schemaVersion: UInt16
  }

  public static func open(
    root: URL,
    compatibilityFingerprint: String
  ) throws -> StoreGenerationHandle {
    try open(root: root, compatibilityFingerprint: compatibilityFingerprint) { _ in }
  }

  package static func open(
    root: URL,
    compatibilityFingerprint: String,
    faultInjector: (StoreGenerationSwitchPoint) throws -> Void
  ) throws -> StoreGenerationHandle {
    processLock.lock()
    defer { processLock.unlock() }
    return try openWhileHoldingProcessLock(
      root: root,
      compatibilityFingerprint: compatibilityFingerprint,
      faultInjector: faultInjector
    )
  }

  private static func openWhileHoldingProcessLock(
    root: URL,
    compatibilityFingerprint: String,
    faultInjector: (StoreGenerationSwitchPoint) throws -> Void
  ) throws -> StoreGenerationHandle {
    let normalized = compatibilityFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw AkashicError.invalidManifest }

    let generations = root.appendingPathComponent(generationsName, isDirectory: true)
    let pointerURL = root.appendingPathComponent(currentName, isDirectory: false)
    try StorageDirectorySecurity.prepareDirectory(root)
    try StorageDirectorySecurity.prepareDirectory(generations)
    try reconcileIncompleteState(root: root, generations: generations)

    if let active = try validHandle(
      pointerURL: pointerURL,
      generations: generations,
      expectedFingerprint: normalized
    ) {
      return active
    }

    if let recovered = try newestCompleteGeneration(
      generations: generations,
      compatibilityFingerprint: normalized
    ) {
      try publishPointer(for: recovered, root: root, faultInjector: faultInjector)
      return recovered
    }

    let identifier = UUID().uuidString.lowercased()
    let generationRoot = generations.appendingPathComponent(identifier, isDirectory: true)
    try StorageDirectorySecurity.prepareDirectory(generationRoot)
    try faultInjector(.afterGenerationDirectoryCreated)

    let descriptor = Descriptor(
      schemaVersion: schemaVersion,
      identifier: identifier,
      compatibilityFingerprint: normalized,
      createdAt: Date()
    )
    let descriptorURL = generationRoot.appendingPathComponent(descriptorName, isDirectory: false)
    try JSONEncoder().encode(descriptor).write(to: descriptorURL, options: [.atomic])
    try StorageDirectorySecurity.securePublishedFile(descriptorURL)
    try synchronizeFile(at: descriptorURL)
    try synchronizeDirectory(at: generationRoot)
    try faultInjector(.afterGenerationDescriptorPublished)

    let handle = StoreGenerationHandle(
      identifier: identifier,
      compatibilityFingerprint: normalized,
      root: generationRoot
    )
    try publishPointer(for: handle, root: root, faultInjector: faultInjector)
    return handle
  }

  private static func reconcileIncompleteState(root: URL, generations: URL) throws {
    let fileManager = FileManager.default
    for url in try fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsSubdirectoryDescendants]
    ) where url.lastPathComponent.hasPrefix(temporaryPrefix) {
      try fileManager.removeItem(at: url)
    }

    for generation in try fileManager.contentsOfDirectory(
      at: generations,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsSubdirectoryDescendants]
    ) {
      let values = try generation.resourceValues(forKeys: [.isDirectoryKey])
      guard values.isDirectory == true else { continue }
      let descriptorURL = generation.appendingPathComponent(descriptorName, isDirectory: false)
      guard fileManager.fileExists(atPath: descriptorURL.path) else {
        try fileManager.removeItem(at: generation)
        continue
      }
      // 已有描述文件的未知或未来世代必须保留；旧版本不得在启动清理中改写它们。
      try StorageDirectorySecurity.prepareDirectory(generation)
    }
  }

  private static func validHandle(
    pointerURL: URL,
    generations: URL,
    expectedFingerprint: String
  ) throws -> StoreGenerationHandle? {
    guard FileManager.default.fileExists(atPath: pointerURL.path) else { return nil }
    let data = try Data(contentsOf: pointerURL)
    if let envelope = try? JSONDecoder().decode(SchemaEnvelope.self, from: data),
      envelope.schemaVersion != schemaVersion
    {
      // 不认识的指针格式版本必须失败关闭，禁止降级版本覆盖未来版本的活动指针。
      throw AkashicError.invalidManifest
    }
    guard let pointer = try? JSONDecoder().decode(Pointer.self, from: data),
      pointer.compatibilityFingerprint == expectedFingerprint,
      UUID(uuidString: pointer.identifier) != nil
    else { return nil }

    let generationRoot = generations.appendingPathComponent(pointer.identifier, isDirectory: true)
    let descriptor = try validDescriptor(at: generationRoot)
    guard descriptor.identifier == pointer.identifier,
      descriptor.compatibilityFingerprint == pointer.compatibilityFingerprint
    else { return nil }
    return StoreGenerationHandle(
      identifier: descriptor.identifier,
      compatibilityFingerprint: descriptor.compatibilityFingerprint,
      root: generationRoot
    )
  }

  private static func newestCompleteGeneration(
    generations: URL,
    compatibilityFingerprint: String
  ) throws -> StoreGenerationHandle? {
    let candidates = try FileManager.default.contentsOfDirectory(
      at: generations,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsSubdirectoryDescendants]
    ).compactMap { root -> (Descriptor, URL)? in
      guard let descriptor = try? validDescriptor(at: root),
        descriptor.compatibilityFingerprint == compatibilityFingerprint
      else { return nil }
      return (descriptor, root)
    }
    guard
      let selected = candidates.max(by: { lhs, rhs in
        if lhs.0.createdAt == rhs.0.createdAt {
          return lhs.0.identifier < rhs.0.identifier
        }
        return lhs.0.createdAt < rhs.0.createdAt
      })
    else { return nil }
    return StoreGenerationHandle(
      identifier: selected.0.identifier,
      compatibilityFingerprint: selected.0.compatibilityFingerprint,
      root: selected.1
    )
  }

  private static func validDescriptor(at generationRoot: URL) throws -> Descriptor {
    let identifier = generationRoot.lastPathComponent
    guard UUID(uuidString: identifier) != nil else { throw AkashicError.invalidManifest }
    let descriptorURL = generationRoot.appendingPathComponent(descriptorName, isDirectory: false)
    let data = try Data(contentsOf: descriptorURL)
    if let envelope = try? JSONDecoder().decode(SchemaEnvelope.self, from: data),
      envelope.schemaVersion != schemaVersion
    {
      throw AkashicError.invalidManifest
    }
    let descriptor = try JSONDecoder().decode(Descriptor.self, from: data)
    guard descriptor.schemaVersion == schemaVersion,
      descriptor.identifier == identifier,
      !descriptor.compatibilityFingerprint.isEmpty
    else { throw AkashicError.invalidManifest }
    return descriptor
  }

  private static func publishPointer(
    for handle: StoreGenerationHandle,
    root: URL,
    faultInjector: (StoreGenerationSwitchPoint) throws -> Void
  ) throws {
    let pointer = Pointer(
      schemaVersion: schemaVersion,
      identifier: handle.identifier,
      compatibilityFingerprint: handle.compatibilityFingerprint
    )
    let temporary = root.appendingPathComponent(
      "\(temporaryPrefix)\(UUID().uuidString.lowercased())",
      isDirectory: false
    )
    let current = root.appendingPathComponent(currentName, isDirectory: false)
    do {
      try JSONEncoder().encode(pointer).write(to: temporary, options: [.withoutOverwriting])
      try StorageDirectorySecurity.securePublishedFile(temporary)
      try synchronizeFile(at: temporary)
      try faultInjector(.afterPointerStaged)
      try atomicReplace(temporary: temporary, destination: current)
      try StorageDirectorySecurity.securePublishedFile(current)
      try synchronizeDirectory(at: root)
      try faultInjector(.afterPointerPublished)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  private static func synchronizeFile(at url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private static func synchronizeDirectory(at url: URL) throws {
    try synchronizeFile(at: url)
  }

  private static func atomicReplace(temporary: URL, destination: URL) throws {
    let result = temporary.path.withCString { source in
      destination.path.withCString { target in
        Darwin.rename(source, target)
      }
    }
    guard result == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}
