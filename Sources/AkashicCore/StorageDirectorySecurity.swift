import Foundation

package enum StorageDirectorySecurity {
  package static func prepareDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: directoryAttributes
    )
    try excludeFromBackup(url)
    try applyProtection(to: url)
  }

  package static func securePublishedFile(_ url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw CocoaError(.fileNoSuchFile)
    }
    try excludeFromBackup(url)
    try applyProtection(to: url)
  }

  private static func excludeFromBackup(_ url: URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableURL = url
    try mutableURL.setResourceValues(values)
  }

  private static var directoryAttributes: [FileAttributeKey: Any]? {
    #if os(iOS)
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    #else
      nil
    #endif
  }

  private static func applyProtection(to url: URL) throws {
    #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path
      )
    #endif
  }
}
