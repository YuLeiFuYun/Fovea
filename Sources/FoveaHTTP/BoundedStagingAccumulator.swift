import AkashicCore
import CryptoKit
import Foundation

package struct StagedBody: Sendable {
  package let data: Data
  package let digestHex: String
  package let metrics: TransportMetrics

  package init(data: Data, digestHex: String, metrics: TransportMetrics) {
    self.data = data
    self.digestHex = digestHex
    self.metrics = metrics
  }
}

package final class BoundedStagingAccumulator {
  private let maximumBytes: Int
  private let memoryThreshold: Int
  private let stagingDirectory: URL
  private var digest = SHA256()
  private var memory = Data()
  private var fileURL: URL?
  private var handle: FileHandle?
  private var count = 0
  private var finalized = false

  package init(maximumBytes: Int, memoryThreshold: Int, stagingDirectory: URL) throws {
    self.maximumBytes = max(0, maximumBytes)
    self.memoryThreshold = max(0, memoryThreshold)
    self.stagingDirectory = stagingDirectory
    try StorageDirectorySecurity.prepareDirectory(stagingDirectory)
  }

  deinit {
    try? handle?.close()
    if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
  }

  package func append(_ data: Data) throws {
    guard !finalized else { throw TransportError.incompleteBody }
    let (nextCount, overflow) = count.addingReportingOverflow(data.count)
    guard !overflow, nextCount <= maximumBytes else { throw TransportError.bodyTooLarge }
    count = nextCount
    digest.update(data: data)

    if handle == nil, memory.count + data.count <= memoryThreshold {
      memory.append(data)
      return
    }

    if handle == nil {
      let url = stagingDirectory.appendingPathComponent("stage-\(UUID().uuidString)")
      guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
      }
      var newHandle: FileHandle?
      do {
        try StorageDirectorySecurity.securePublishedFile(url)
        let opened = try FileHandle(forWritingTo: url)
        newHandle = opened
        if !memory.isEmpty {
          try opened.write(contentsOf: memory)
        }
      } catch {
        try? newHandle?.close()
        try? FileManager.default.removeItem(at: url)
        throw error
      }
      memory.removeAll(keepingCapacity: false)
      fileURL = url
      handle = newHandle
    }
    try handle?.write(contentsOf: data)
  }

  package func finalize() throws -> StagedBody {
    guard !finalized else { throw TransportError.incompleteBody }
    finalized = true
    try handle?.synchronize()
    try handle?.close()
    handle = nil

    let body: Data
    if let fileURL {
      body = try Data(contentsOf: fileURL, options: .mappedIfSafe)
    } else {
      body = memory
    }
    guard body.count == count else { throw TransportError.incompleteBody }
    let digestHex = digest.finalize().map { String(format: "%02x", $0) }.joined()
    return StagedBody(
      data: body,
      digestHex: digestHex,
      metrics: TransportMetrics(receivedBytes: count, spilledToDisk: fileURL != nil)
    )
  }
}
