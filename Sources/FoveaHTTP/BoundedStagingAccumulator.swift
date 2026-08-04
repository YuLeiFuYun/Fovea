import AkashicCore
import CryptoKit
import Foundation
import FoveaStorage

/// 已完成接收并通过字节上限校验的响应体，以及用于完整性和落盘诊断的元数据。
package struct StagedBody: Sendable {
    package let storage: TransportBodyStorage
    package let verifiedDigest: TransportBodyDigest
    package let metrics: TransportMetrics
    package var digestHex: String { verifiedDigest.hex }
    package var byteCount: Int { storage.byteCount }
    package var stagedFileLease: TransportStagedFileLease? { storage.stagedFileLease }

    package func materializedData() throws -> Data {
        try storage.materializedData()
    }
}

package final class BoundedStagingAccumulator {
    private let maximumBytes: Int
    private let memoryThreshold: Int
    private let stagingDirectory: URL
    private let stagingDirectoryLease: StagingDirectoryLease?
    private var digest = SHA256()
    private var memory = Data()
    private var fileURL: URL?
    private var handle: FileHandle?
    private var count = 0
    private var finalized = false

    package var receivedByteCount: Int { count }

    package convenience init(
        maximumBytes: Int,
        memoryThreshold: Int,
        stagingDirectory: URL
    ) throws {
        try self.init(
            maximumBytes: maximumBytes,
            memoryThreshold: memoryThreshold,
            stagingDirectory: stagingDirectory,
            stagingDirectoryLease: nil
        )
    }

    package convenience init(
        maximumBytes: Int,
        memoryThreshold: Int,
        stagingLease: StagingDirectoryLease
    ) throws {
        try self.init(
            maximumBytes: maximumBytes,
            memoryThreshold: memoryThreshold,
            stagingDirectory: stagingLease.directory,
            stagingDirectoryLease: stagingLease
        )
    }

    private init(
        maximumBytes: Int,
        memoryThreshold: Int,
        stagingDirectory: URL,
        stagingDirectoryLease: StagingDirectoryLease?
    ) throws {
        self.maximumBytes = max(0, maximumBytes)
        self.memoryThreshold = max(0, memoryThreshold)
        self.stagingDirectory = stagingDirectory
        self.stagingDirectoryLease = stagingDirectoryLease
        try FoveaManagedFileSecurity.prepareDirectory(stagingDirectory)
    }

    deinit {
        try? handle?.close()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    package func reserveCapacity(forExpectedByteCount expectedByteCount: Int) throws {
        guard !finalized else { throw TransportError.incompleteBody }
        guard expectedByteCount >= 0, expectedByteCount <= maximumBytes else {
            throw TransportError.bodyTooLarge
        }
        guard handle == nil, count == 0, expectedByteCount <= memoryThreshold else { return }
        memory.reserveCapacity(expectedByteCount)
    }

    package func append(_ data: Data) throws {
        guard !finalized else { throw TransportError.incompleteBody }
        let (nextCount, overflow) = count.addingReportingOverflow(data.count)
        guard !overflow, nextCount <= maximumBytes else { throw TransportError.bodyTooLarge }
        count = nextCount
        digest.update(data: data)

        let inMemoryCount = memory.count.addingReportingOverflow(data.count)
        if handle == nil, !inMemoryCount.overflow, inMemoryCount.partialValue <= memoryThreshold {
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
                try FoveaManagedFileSecurity.securePublishedFile(url)
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

    package func finalize(
        bodyDelivery: TransportBodyDelivery = .materialized
    ) throws -> StagedBody {
        guard !finalized else { throw TransportError.incompleteBody }
        finalized = true
        // transport staging 是立即消费的临时缓冲，不承担崩溃后耐久语义；close 已足以
        // 使同进程后续读取观察到完整字节，额外 fsync 只会把网络关键路径绑定到磁盘。
        try handle?.close()
        handle = nil

        let spilledToDisk = fileURL != nil
        let storage: TransportBodyStorage
        if let fileURL {
            let lease = TransportStagedFileLease(
                fileURL: fileURL,
                byteCount: count,
                sessionLease: stagingDirectoryLease
            )
            self.fileURL = nil
            switch bodyDelivery {
            case .materialized:
                let data = try lease.mappedData()
                guard data.count == count else { throw TransportError.incompleteBody }
                storage = .memory(data)
            case .deferredFileIfStaged:
                storage = .stagedFile(lease)
            }
        } else {
            storage = .memory(memory)
        }
        guard storage.byteCount == count else { throw TransportError.incompleteBody }
        let digestHex = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return StagedBody(
            storage: storage,
            verifiedDigest: TransportBodyDigest(hex: digestHex),
            metrics: TransportMetrics(
                receivedBytes: count,
                spilledToDisk: spilledToDisk
            )
        )
    }
}
