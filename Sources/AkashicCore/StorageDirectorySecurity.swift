import Darwin
import Foundation

package enum StorageDirectorySecurity {
  package static func prepareDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: directoryAttributes
    )
    try validateDirectory(url)
    try excludeFromBackup(url)
    try FileManager.default.setAttributes(
      directoryAttributes,
      ofItemAtPath: url.path
    )
  }

  package static func securePublishedFile(_ url: URL) throws {
    try validateRegularFile(url)
    try excludeFromBackup(url)
    try FileManager.default.setAttributes(
      fileAttributes,
      ofItemAtPath: url.path
    )
  }

  package static func validateDirectory(_ url: URL) throws {
    let status = try fileStatusWithoutFollowingLinks(at: url)
    let fileType = status.st_mode & S_IFMT
    guard fileType == S_IFDIR, status.st_uid == Darwin.geteuid() else {
      throw AkashicError.storageUnavailable
    }
  }

  package static func validateRegularFile(_ url: URL) throws {
    let status = try fileStatusWithoutFollowingLinks(at: url)
    let fileType = status.st_mode & S_IFMT
    guard fileType == S_IFREG,
      status.st_nlink == 1,
      status.st_uid == Darwin.geteuid()
    else {
      throw AkashicError.storageUnavailable
    }
  }

  package static func validateOpenedPrivateRegularFile(_ descriptor: Int32) throws {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else { throw posixError() }
    let fileType = status.st_mode & S_IFMT
    guard fileType == S_IFREG,
      status.st_nlink == 1,
      status.st_uid == Darwin.geteuid()
    else {
      throw AkashicError.storageUnavailable
    }
  }

  package static func validateOpenedDirectory(_ descriptor: Int32) throws {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else { throw posixError() }
    let fileType = status.st_mode & S_IFMT
    guard fileType == S_IFDIR, status.st_uid == Darwin.geteuid() else {
      throw AkashicError.storageUnavailable
    }
  }

  private static func fileStatusWithoutFollowingLinks(at url: URL) throws -> stat {
    var status = stat()
    let result = url.path.withCString { Darwin.lstat($0, &status) }
    guard result == 0 else { throw posixError() }
    return status
  }

  private static func excludeFromBackup(_ url: URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableURL = url
    try mutableURL.setResourceValues(values)
  }

  private static var directoryAttributes: [FileAttributeKey: Any] {
    var attributes: [FileAttributeKey: Any] = [
      .posixPermissions: NSNumber(value: Int16(0o700))
    ]
    #if os(iOS)
      attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
    #endif
    return attributes
  }

  private static var fileAttributes: [FileAttributeKey: Any] {
    var attributes: [FileAttributeKey: Any] = [
      .posixPermissions: NSNumber(value: Int16(0o600))
    ]
    #if os(iOS)
      attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
    #endif
    return attributes
  }

  private static func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
