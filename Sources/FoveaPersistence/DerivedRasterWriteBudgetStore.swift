import AkashicCore
import Foundation
import FoveaStorage

/// 派生光栅持久写预算的独立、固定大小、耐崩溃元数据。
///
/// reservation 必须先于 blob staging 持久化。这样即使进程在物理写入或 alias 发布期间崩溃，
/// 重开也不会把已经授权的写成本凭空归零。当前算法是固定窗口而非滑动窗口；窗口边界的 burst
/// 必须由 clean W2/W11 与设备写放大证据决定是否可接受。
package actor DerivedRasterWriteBudgetStore {
    package static let currentSchemaVersion: UInt16 = 1
    private static let maximumStateBytes = 16 * 1024

    private nonisolated let ioExecutor = FoveaBlockingIOExecutor(
        label: "dev.fovea.persistence.derived-raster-write-budget"
    )

    package nonisolated var unownedExecutor: UnownedSerialExecutor {
        ioExecutor.asUnownedSerialExecutor()
    }

    private struct State: Codable, Equatable {
        let schemaVersion: UInt16
        let windowStartedAt: Date
        let reservedBytes: Int
    }

    private let fileURL: URL
    private var state: State?

    private init(root: URL) {
        fileURL = root.appendingPathComponent("derived-raster-write-budget.json")
    }

    package static func open(root: URL) async throws -> DerivedRasterWriteBudgetStore {
        let store = DerivedRasterWriteBudgetStore(root: root)
        try await store.bootstrap(root: root)
        return store
    }

    private func bootstrap(root: URL) throws {
        try FoveaManagedFileSecurity.prepareDirectory(root)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try FoveaBoundedFileReader.read(
                from: fileURL, maximumBytes: Self.maximumStateBytes)
        } catch {
            throw AkashicError.invalidManifest
        }
        guard let decoded = try? JSONDecoder().decode(State.self, from: data),
            decoded.schemaVersion == Self.currentSchemaVersion,
            decoded.reservedBytes >= 0,
            decoded.windowStartedAt.timeIntervalSinceReferenceDate.isFinite
        else { throw AkashicError.invalidManifest }
        state = decoded
    }

    /// 在任何 derived blob staging 之前耐久地预留本次写成本。
    ///
    /// 时间回拨不会刷新预算：只有达到正向窗口边界时才会开始新窗口。
    package func reserve(
        byteCount: Int,
        at now: Date,
        maximumBytes: Int,
        windowNanoseconds: UInt64
    ) throws -> Bool {
        guard byteCount > 0, maximumBytes > 0, windowNanoseconds > 0,
            now.timeIntervalSinceReferenceDate.isFinite
        else { throw AkashicError.storageUnavailable }
        guard byteCount <= maximumBytes else { return false }

        let current = normalizedState(at: now, windowNanoseconds: windowNanoseconds)
        let addition = current.reservedBytes.addingReportingOverflow(byteCount)
        guard !addition.overflow, addition.partialValue <= maximumBytes else { return false }

        let next = State(
            schemaVersion: Self.currentSchemaVersion,
            windowStartedAt: current.windowStartedAt,
            reservedBytes: addition.partialValue
        )
        try persist(next)
        state = next
        return true
    }

    package func reservedBytesForTesting() -> Int {
        state?.reservedBytes ?? 0
    }

    private func normalizedState(at now: Date, windowNanoseconds: UInt64) -> State {
        guard let state else {
            return State(
                schemaVersion: Self.currentSchemaVersion,
                windowStartedAt: now,
                reservedBytes: 0
            )
        }
        let elapsedSeconds = now.timeIntervalSince(state.windowStartedAt)
        let windowSeconds = Double(windowNanoseconds) / 1_000_000_000
        guard elapsedSeconds >= windowSeconds else { return state }
        return State(
            schemaVersion: Self.currentSchemaVersion,
            windowStartedAt: now,
            reservedBytes: 0
        )
    }

    private func persist(_ state: State) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= Self.maximumStateBytes else { throw AkashicError.storageUnavailable }
        try FoveaDurableFileWriter.writeReplacing(data, to: fileURL)
    }
}
