import AkashicCore
import AkashicDisk
import Darwin
import Foundation
import FoveaHTTP

public enum FoveaPersistenceError: Error, Equatable, Sendable {
  case writerAlreadyActive
  case incompatibleActiveConfiguration
}

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
    let bundle = try await PersistentStoreRegistry.shared.bundle(
      generation: generation,
      encodedSoftLimitBytes: encodedSoftLimitBytes
    )
    return FoveaPersistentStores(
      generation: bundle.generation,
      encoded: bundle.encoded,
      records: bundle.records
    )
  }
}

private final class PersistentStoreBundle: Sendable {
  let generation: StoreGenerationHandle
  let encoded: OriginalEncodedStore
  let records: RepresentationRecordStore
  let encodedSoftLimitBytes: Int
  let writerLease: StoreWriterLease

  init(
    generation: StoreGenerationHandle,
    encoded: OriginalEncodedStore,
    records: RepresentationRecordStore,
    encodedSoftLimitBytes: Int,
    writerLease: StoreWriterLease
  ) {
    self.generation = generation
    self.encoded = encoded
    self.records = records
    self.encodedSoftLimitBytes = encodedSoftLimitBytes
    self.writerLease = writerLease
  }
}

private actor PersistentStoreRegistry {
  static let shared = PersistentStoreRegistry()

  private enum Entry {
    case opening(
      encodedSoftLimitBytes: Int,
      task: Task<PersistentStoreBundle, any Error>
    )
    case ready(PersistentStoreBundle)
  }

  private var entries: [String: Entry] = [:]

  func bundle(
    generation: StoreGenerationHandle,
    encodedSoftLimitBytes: Int
  ) async throws -> PersistentStoreBundle {
    let normalizedLimit = max(1, encodedSoftLimitBytes)
    let key = canonicalPath(generation.root)
    if let existing = entries[key] {
      switch existing {
      case .ready(let bundle):
        guard bundle.encodedSoftLimitBytes == normalizedLimit else {
          throw FoveaPersistenceError.incompatibleActiveConfiguration
        }
        return bundle
      case .opening(let activeLimit, let task):
        guard activeLimit == normalizedLimit else {
          throw FoveaPersistenceError.incompatibleActiveConfiguration
        }
        return try await task.value
      }
    }

    let task = Task<PersistentStoreBundle, any Error> {
      let writerLease = try StoreWriterLease.acquire(root: generation.root)
      let encoded = try await OriginalEncodedStore.open(
        root: generation.root.appendingPathComponent("encoded", isDirectory: true),
        softLimitBytes: normalizedLimit
      )
      let records = try await RepresentationRecordStore.open(
        root: generation.root.appendingPathComponent("records", isDirectory: true)
      )
      return PersistentStoreBundle(
        generation: generation,
        encoded: encoded,
        records: records,
        encodedSoftLimitBytes: normalizedLimit,
        writerLease: writerLease
      )
    }
    entries[key] = .opening(encodedSoftLimitBytes: normalizedLimit, task: task)

    do {
      let bundle = try await task.value
      entries[key] = .ready(bundle)
      return bundle
    } catch {
      entries.removeValue(forKey: key)
      throw error
    }
  }

  private func canonicalPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }
}

private final class StoreWriterLease: Sendable {
  private let descriptor: Int32

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  static func acquire(root: URL) throws -> StoreWriterLease {
    let lockURL = root.appendingPathComponent(".fovea-writer.lock", isDirectory: false)
    let descriptor = Darwin.open(
      lockURL.path,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else { throw posixError() }

    do {
      try StorageDirectorySecurity.validateOpenedPrivateRegularFile(descriptor)
    } catch {
      _ = Darwin.close(descriptor)
      throw error
    }
    guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
      let error = posixError()
      _ = Darwin.close(descriptor)
      throw error
    }
    guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
      let code = errno
      _ = Darwin.close(descriptor)
      if code == EACCES || code == EAGAIN {
        throw FoveaPersistenceError.writerAlreadyActive
      }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    return StoreWriterLease(descriptor: descriptor)
  }

  deinit {
    _ = Darwin.lockf(descriptor, F_ULOCK, 0)
    _ = Darwin.close(descriptor)
  }

  private static func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
