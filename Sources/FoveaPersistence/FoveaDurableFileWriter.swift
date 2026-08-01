import Darwin
import Foundation
import FoveaStorage

package enum FoveaDurableFileWriteSwitchPoint: String, CaseIterable, Sendable {
    case afterDataWritten
    case afterFileSynced
    case afterRename
    case afterDirectorySynced
}

package typealias FoveaDurableFileWriteFaultInjector =
    @Sendable (FoveaDurableFileWriteSwitchPoint) throws -> Void

/// 在同一目录内暂存并耐久地原子替换文件。
///
/// 成功返回前依次保证：暂存文件安全属性已设置、内容写完、文件 `fsync`、原子
/// `rename`、父目录 `fsync`。调用方仍需用更高层事务协调多个文件之间的可见性。
package enum FoveaDurableFileWriter {
    package static func writeReplacing(_ data: Data, to destination: URL) throws {
        try writeReplacing(data, to: destination, faultInjector: { _ in })
    }

    package static func writeReplacing(
        _ data: Data,
        to destination: URL,
        faultInjector: FoveaDurableFileWriteFaultInjector
    ) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".durable-tmp-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posixError() }
        do {
            try FoveaManagedFileSecurity.validateOpenedPrivateRegularFile(descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }

        var descriptorIsOpen = true
        do {
            // 属性必须在文件同步前写入；rename 会保留同一 inode 的保护属性与扩展属性。
            try FoveaManagedFileSecurity.securePublishedFile(temporary)
            try writeAll(data, to: descriptor)
            try faultInjector(.afterDataWritten)
            guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
            try faultInjector(.afterFileSynced)

            let closeResult = Darwin.close(descriptor)
            descriptorIsOpen = false
            guard closeResult == 0 else { throw posixError() }

            guard rename(temporary.path, destination.path) == 0 else { throw posixError() }
            try faultInjector(.afterRename)
            try synchronizeDirectory(directory)
            try faultInjector(.afterDirectorySynced)
        } catch {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard result > 0 else { throw POSIXError(.EIO) }
                written += result
            }
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }
        try FoveaManagedFileSecurity.validateOpenedDirectory(descriptor)
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
    }

    private static func rename(_ source: String, _ destination: String) -> Int32 {
        source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                Darwin.rename(sourcePointer, destinationPointer)
            }
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
