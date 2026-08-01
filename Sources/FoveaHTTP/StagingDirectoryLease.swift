import AkashicCore
import Darwin
import Foundation
import FoveaStorage

/// 对单个 transport 暂存文件的所有权租约。
///
/// 租约强持有其 session 目录所有者，保证 transport 关闭与 handoff 淘汰并发时文件
/// 不会提前消失；最后一个引用释放时删除文件。读取前重新验证普通文件属性，避免
/// 将路径替换或链接攻击带入解码边界。
package final class TransportStagedFileLease: @unchecked Sendable {
    package let fileURL: URL
    package let byteCount: Int
    private let sessionLease: StagingDirectoryLease?
    private let lock = NSLock()
    private var ownsFile = true

    package init(
        fileURL: URL,
        byteCount: Int,
        sessionLease: StagingDirectoryLease? = nil
    ) {
        self.fileURL = fileURL
        self.byteCount = max(0, byteCount)
        self.sessionLease = sessionLease
    }

    deinit {
        lock.lock()
        let shouldDelete = ownsFile
        ownsFile = false
        lock.unlock()
        if shouldDelete { try? FileManager.default.removeItem(at: fileURL) }
        _ = sessionLease
    }

    package func mappedData() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard ownsFile else { throw TransportError.incompleteBody }
        try FoveaManagedFileSecurity.validateRegularFile(fileURL)
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count == byteCount else { throw TransportError.incompleteBody }
        return data
    }

    /// 为另一个受管临时存储创建独立正文。
    ///
    /// 共享 fetch 的多个订阅者可能同时持有本 lease，因此不得通过 move 窃取所有权。
    /// 同卷支持 clonefile 时使用写时复制克隆；否则退化为普通复制。原 lease 始终保持可读。
    package func cloneContents(to destination: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard ownsFile else { throw TransportError.incompleteBody }
        try FoveaManagedFileSecurity.validateRegularFile(fileURL)

        let result = fileURL.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.clonefile(sourcePath, destinationPath, 0)
            }
        }
        if result != 0 {
            let cloneError = errno
            guard cloneError == ENOTSUP || cloneError == EXDEV || cloneError == EINVAL else {
                throw POSIXError(POSIXErrorCode(rawValue: cloneError) ?? .EIO)
            }
            try FileManager.default.copyItem(at: fileURL, to: destination)
        }
        try FoveaManagedFileSecurity.validateRegularFile(destination)
    }
}

/// 拥有一个传输私有暂存目录，并清理同一根目录下的遗弃会话。
private actor StagingSessionRegistry {
    static let shared = StagingSessionRegistry()
    private var paths: Set<String> = []

    func snapshot() -> Set<String> { paths }
    func insert(_ path: String) { paths.insert(path) }
    func remove(_ path: String) { paths.remove(path) }
}

package final class StagingDirectoryLease: Sendable {
    package let directory: URL
    private let ownerDescriptor: Int32

    private init(directory: URL, ownerDescriptor: Int32) {
        self.directory = directory
        self.ownerDescriptor = ownerDescriptor
    }

    package static func acquire(
        root: URL,
        maintenanceLockTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) async throws -> StagingDirectoryLease {
        try Task.checkCancellation()
        try FoveaManagedFileSecurity.prepareDirectory(root)
        let maintenanceDescriptor = try openLock(
            at: root.appendingPathComponent(".fovea-staging-maintenance.lock")
        )
        do {
            try await acquireMaintenanceLock(
                maintenanceDescriptor,
                timeoutNanoseconds: maintenanceLockTimeoutNanoseconds
            )
        } catch {
            _ = Darwin.close(maintenanceDescriptor)
            throw error
        }
        defer {
            _ = Darwin.lockf(maintenanceDescriptor, F_ULOCK, 0)
            _ = Darwin.close(maintenanceDescriptor)
        }

        let activePaths = await StagingSessionRegistry.shared.snapshot()
        try removeAbandonedSessions(in: root, activePaths: activePaths)
        try removeLegacyStageFiles(in: root)

        let directory = root.appendingPathComponent(
            "session-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FoveaManagedFileSecurity.prepareDirectory(directory)
        let ownerURL = directory.appendingPathComponent(".owner.lock", isDirectory: false)
        let ownerDescriptor: Int32
        do {
            ownerDescriptor = try openLock(at: ownerURL)
            guard Darwin.lockf(ownerDescriptor, F_TLOCK, 0) == 0 else {
                throw posixError()
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        await StagingSessionRegistry.shared.insert(directory.standardizedFileURL.path)
        return StagingDirectoryLease(
            directory: directory,
            ownerDescriptor: ownerDescriptor
        )
    }

    deinit {
        // 在仍持有所有权锁时删除私有目录，使并发清理
        // 不会在解锁与删除之间误判该会话已经遗弃。
        try? FileManager.default.removeItem(at: directory)
        let path = directory.standardizedFileURL.path
        Task { await StagingSessionRegistry.shared.remove(path) }
        _ = Darwin.lockf(ownerDescriptor, F_ULOCK, 0)
        _ = Darwin.close(ownerDescriptor)
    }

    /// 使用非阻塞锁轮询，使任务取消和跨进程异常持锁都具有有限边界。
    private static func acquireMaintenanceLock(
        _ descriptor: Int32,
        timeoutNanoseconds: UInt64
    ) async throws {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = startedAt.addingReportingOverflow(timeoutNanoseconds)
        let boundedDeadline = overflow ? UInt64.max : deadline

        while true {
            try Task.checkCancellation()
            if Darwin.lockf(descriptor, F_TLOCK, 0) == 0 { return }
            let code = errno
            guard code == EACCES || code == EAGAIN else { throw posixError(code) }

            let now = DispatchTime.now().uptimeNanoseconds
            guard now < boundedDeadline else {
                throw POSIXError(.ETIMEDOUT)
            }
            let remaining = boundedDeadline - now
            try await Task.sleep(nanoseconds: min(25_000_000, remaining))
        }
    }

    private static func removeAbandonedSessions(
        in root: URL,
        activePaths: Set<String>
    ) throws {
        let candidates = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        ).filter { $0.lastPathComponent.hasPrefix("session-") }

        for directory in candidates {
            let path = directory.standardizedFileURL.path
            guard !activePaths.contains(path) else { continue }
            try FoveaManagedFileSecurity.validateDirectory(directory)
            let ownerURL = directory.appendingPathComponent(".owner.lock", isDirectory: false)
            guard FileManager.default.fileExists(atPath: ownerURL.path) else {
                try FileManager.default.removeItem(at: directory)
                continue
            }

            let descriptor = try openLock(at: ownerURL)
            defer { _ = Darwin.close(descriptor) }
            if Darwin.lockf(descriptor, F_TLOCK, 0) == 0 {
                try FileManager.default.removeItem(at: directory)
                _ = Darwin.lockf(descriptor, F_ULOCK, 0)
            } else {
                let code = errno
                guard code == EACCES || code == EAGAIN else { throw posixError(code) }
            }
        }
    }

    private static func removeLegacyStageFiles(in root: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsSubdirectoryDescendants]
        ).filter { $0.lastPathComponent.hasPrefix("stage-") }

        for file in files {
            try FoveaManagedFileSecurity.validateRegularFile(file)
            try FileManager.default.removeItem(at: file)
        }
    }

    private static func openLock(at url: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posixError() }
        do {
            try FoveaManagedFileSecurity.validateOpenedPrivateRegularFile(descriptor)
            guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw posixError()
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
