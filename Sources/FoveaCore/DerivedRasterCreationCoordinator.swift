import CryptoKit
import Foundation
import FoveaStorage
import ImageCraftCore

struct DerivedRasterEncodedCandidate: Sendable {
    let surface: DerivedRasterSurface
    let container: Data
    let measuredReadNanoseconds: UInt64
}

enum DerivedRasterCandidateEncoder {
    static func encode(
        image: DecodedImage,
        key: DerivedRasterArtifactKey,
        configuration: DerivedRasterRuntimeConfiguration,
        executor: DispatchWorkExecutor
    ) async throws -> DerivedRasterEncodedCandidate {
        try await executor.run {
            let surface = try makeSurface(image: image, format: key.format)
            let limits = DerivedRasterContainerLimits(
                maximumContainerBytes: configuration.maximumContainerBytes,
                maximumDimension: max(image.pixelWidth, image.pixelHeight),
                maximumPixelCount: pixelCount(image),
                maximumDecodedBytes: surface.pixelData.count
            )
            let container = try makeContainer(surface: surface, key: key, limits: limits)
            let verified = try verifiedSurface(container: container, key: key)
            try verifyDecodedImage(surface: verified, format: key.format)
            let measuredReadNanoseconds = try measureReusableRead(
                container: container,
                key: key,
                limits: limits
            )
            return DerivedRasterEncodedCandidate(
                surface: surface,
                container: container,
                measuredReadNanoseconds: measuredReadNanoseconds
            )
        }
    }

    private static func makeSurface(
        image: DecodedImage,
        format: DerivedRasterFormatIdentity
    ) throws -> DerivedRasterSurface {
        do {
            return try DerivedRasterPixelBridge.surface(from: image, format: format)
        } catch let error as DerivedRasterContainerError {
            throw DerivedRasterCreationStageFailure(
                reason: "derived-raster-surface-\(containerErrorCode(error))"
            )
        }
    }

    private static func makeContainer(
        surface: DerivedRasterSurface,
        key: DerivedRasterArtifactKey,
        limits: DerivedRasterContainerLimits
    ) throws -> Data {
        do {
            return try DerivedRasterContainer.encode(
                pixelData: surface.pixelData,
                width: surface.width,
                height: surface.height,
                format: key.format,
                limits: limits
            )
        } catch let error as DerivedRasterContainerError {
            throw DerivedRasterCreationStageFailure(
                reason: "derived-raster-container-\(containerErrorCode(error))"
            )
        }
    }

    private static func verifiedSurface(
        container: Data,
        key: DerivedRasterArtifactKey
    ) throws -> DerivedRasterSurface {
        guard
            let surface = DerivedRasterArtifactValidator.validatedSurface(
                record: nil,
                container: container,
                matching: key
            )
        else {
            throw DerivedRasterCreationStageFailure(
                reason: "derived-raster-container-verification-failed"
            )
        }
        return surface
    }

    private static func verifyDecodedImage(
        surface: DerivedRasterSurface,
        format: DerivedRasterFormatIdentity
    ) throws {
        do {
            guard let sourceProfile = DerivedRasterContainer.sourceColorProfile(for: format)
            else { throw DerivedRasterContainerError.unsupportedFormat }
            _ = try DerivedRasterPixelBridge.image(
                from: surface,
                sourceColorProfile: sourceProfile
            )
        } catch let error as DerivedRasterContainerError {
            throw DerivedRasterCreationStageFailure(
                reason: "derived-raster-image-\(containerErrorCode(error))"
            )
        }
    }

    private static func measureReusableRead(
        container: Data,
        key: DerivedRasterArtifactKey,
        limits: DerivedRasterContainerLimits
    ) throws -> UInt64 {
        let digest = lowercaseHexString(SHA256.hash(data: container))
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            guard
                let compressed = try? DerivedRasterContainer.validatedCompressedSurface(
                    container,
                    expectedContainerDigestHex: digest,
                    containerContentDigestAlreadyVerified: true,
                    expectedFormat: key.format,
                    limits: limits
                ),
                let sourceProfile = DerivedRasterContainer.sourceColorProfile(for: key.format)
            else { throw DerivedRasterContainerError.integrityMismatch }
            let lazy = try DerivedRasterPixelBridge.lazyImage(
                from: compressed,
                sourceColorProfile: sourceProfile
            )
            _ = lazy.cgImage
            return DispatchTime.now().uptimeNanoseconds &- started
        } catch let error as DerivedRasterContainerError {
            throw DerivedRasterCreationStageFailure(
                reason: "derived-raster-read-sample-\(containerErrorCode(error))"
            )
        }
    }

    private static func pixelCount(_ image: DecodedImage) -> Int {
        let result = image.pixelWidth.multipliedReportingOverflow(by: image.pixelHeight)
        return result.overflow ? .max : result.partialValue
    }

    private static func containerErrorCode(_ error: DerivedRasterContainerError) -> String {
        switch error {
        case .invalidInput: "invalid-input"
        case .unsupportedSchema: "unsupported-schema"
        case .unsupportedFormat: "unsupported-format"
        case .limitExceeded: "limit-exceeded"
        case .integrityMismatch: "integrity-mismatch"
        case .compressionFailed: "compression-failed"
        }
    }
}

package struct DerivedRasterCreationProduct: Sendable {
    package let container: Data
    package let record: DerivedRasterRecord

    package init(container: Data, record: DerivedRasterRecord) {
        self.container = container
        self.record = record
    }
}

/// 后台派生创建的单调活动快照，用于等待已登记工作真正进入终态。
package struct DerivedRasterCreationActivity: Equatable, Sendable {
    package let scheduledCount: UInt64
    package let terminalCount: UInt64
    package let activeCount: Int

    package init(scheduledCount: UInt64, terminalCount: UInt64, activeCount: Int) {
        self.scheduledCount = scheduledCount
        self.terminalCount = terminalCount
        self.activeCount = activeCount
    }
}

/// 与持久化适配器共享、由锁保护的可撤销发布许可。
///
/// `close()` 保持同步，使取消与 namespace 撤销能在取消或等待后台工作前先关闭发布权。
package final class DerivedRasterPublicationLease:
    DerivedRasterPublicationPermission, @unchecked Sendable
{
    private let lock = NSLock()
    private var isOpenStorage = true

    package func permitsPublication() async -> Bool {
        lock.withLock { isOpenStorage }
    }

    package func close() {
        lock.withLock { isOpenStorage = false }
    }
}

/// 精确目标派生光栅身份的后台 single-flight 所有者。
///
/// 协调器绝不参与首次显示，只去重已准入的后台工作、按精确工件身份验证产物记录，
/// 并向存储提供可撤销的发布租约。
package actor DerivedRasterCreationCoordinator {
    private let maximumEntryCount: Int

    package init(maximumEntryCount: Int = 64) {
        self.maximumEntryCount = min(10000, max(1, maximumEntryCount))
    }

    package typealias CreateOperation =
        @Sendable () async throws -> DerivedRasterCreationProduct
    package typealias PublishOperation =
        @Sendable (
            DerivedRasterCreationProduct,
            any DerivedRasterPublicationPermission
        ) async throws -> Void

    private struct Entry {
        let token: UUID
        let key: DerivedRasterArtifactKey
        let lease: DerivedRasterPublicationLease
        var task: Task<Void, Never>?
    }

    private struct ActivityWaiter {
        let baseline: DerivedRasterCreationActivity
        let continuation: CheckedContinuation<DerivedRasterCreationActivity, Never>
    }

    private var entries: [String: Entry] = [:]
    private var scheduledCount: UInt64 = 0
    private var terminalCount: UInt64 = 0
    private var activityWaiters: [UUID: ActivityWaiter] = [:]

    /// 当精确身份空闲时调度一个脱离调用者的 utility 优先级创建任务。
    /// 等价创建任务已活动时返回 `false`。
    @discardableResult
    package func schedule(
        key: DerivedRasterArtifactKey,
        create: @escaping CreateOperation,
        publish: @escaping PublishOperation
    ) -> Bool {
        guard entries[key.digestHex] == nil, entries.count < maximumEntryCount else { return false }
        let token = UUID()
        let lease = DerivedRasterPublicationLease()
        entries[key.digestHex] = Entry(
            token: token,
            key: key,
            lease: lease,
            task: nil
        )
        scheduledCount = Self.saturatingIncrement(scheduledCount)
        let task = Task.detached(priority: .utility) { [weak self] in
            do {
                let product = try await create()
                if !Task.isCancelled,
                    await lease.permitsPublication(),
                    Self.product(product, matches: key)
                {
                    try await publish(product, lease)
                }
            } catch {
                // 后台派生是机会性优化，原始编码解码始终是权威路径。
            }
            await self?.finish(keyDigest: key.digestHex, token: token)
        }
        entries[key.digestHex]?.task = task
        return true
    }

    /// 同步关闭发布租约后取消一个精确创建任务。
    package func cancel(key: DerivedRasterArtifactKey) {
        guard let entry = entries.removeValue(forKey: key.digestHex) else { return }
        entry.lease.close()
        entry.task?.cancel()
        markTerminal(count: 1)
    }

    /// 关闭并取消同一 namespace 中早于活动 generation 的全部创建任务。
    package func revoke(
        namespaceFingerprint: StorageNamespaceFingerprint,
        before activeGeneration: NamespaceGeneration
    ) {
        let removed = entries.values.filter {
            $0.key.namespaceFingerprint == namespaceFingerprint
                && $0.key.namespaceGeneration.value < activeGeneration.value
        }
        for entry in removed {
            entries.removeValue(forKey: entry.key.digestHex)
            entry.lease.close()
        }
        for entry in removed {
            entry.task?.cancel()
        }
        markTerminal(count: removed.count)
    }

    /// 关闭并取消全部创建任务，用于组合根失效而不删除已发布工件。
    package func cancelAll() {
        let removed = Array(entries.values)
        entries.removeAll(keepingCapacity: true)
        for entry in removed {
            entry.lease.close()
        }
        for entry in removed {
            entry.task?.cancel()
        }
        markTerminal(count: removed.count)
    }

    /// 不区分 generation，关闭并取消一个 namespace 中的全部创建任务。
    package func cancelAll(namespaceFingerprint: StorageNamespaceFingerprint) {
        let removed = entries.values.filter {
            $0.key.namespaceFingerprint == namespaceFingerprint
        }
        for entry in removed {
            entries.removeValue(forKey: entry.key.digestHex)
            entry.lease.close()
        }
        for entry in removed {
            entry.task?.cancel()
        }
        markTerminal(count: removed.count)
    }

    package func activeCount() -> Int {
        entries.count
    }

    package func activitySnapshot() -> DerivedRasterCreationActivity {
        currentActivity()
    }

    /// 等待 baseline 之后至少一个任务已登记，且协调器再次进入无活动任务状态。
    ///
    /// 这避免以固定 sleep 或轮询超时推断 utility task 是否获得过执行机会。
    package func waitUntilQuiescent(
        after baseline: DerivedRasterCreationActivity
    ) async -> DerivedRasterCreationActivity {
        if let activity = quiescentActivity(after: baseline) {
            return activity
        }
        let identifier = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let activity = quiescentActivity(after: baseline) {
                    continuation.resume(returning: activity)
                } else {
                    activityWaiters[identifier] = ActivityWaiter(
                        baseline: baseline,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelActivityWaiter(identifier) }
        }
    }

    package func contains(_ key: DerivedRasterArtifactKey) -> Bool {
        entries[key.digestHex] != nil
    }

    private func finish(keyDigest: String, token: UUID) {
        guard entries[keyDigest]?.token == token else { return }
        entries.removeValue(forKey: keyDigest)
        markTerminal(count: 1)
    }

    private func markTerminal(count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            terminalCount = Self.saturatingIncrement(terminalCount)
        }
        resumeActivityWaiters()
    }

    private func currentActivity() -> DerivedRasterCreationActivity {
        DerivedRasterCreationActivity(
            scheduledCount: scheduledCount,
            terminalCount: terminalCount,
            activeCount: entries.count
        )
    }

    private func quiescentActivity(
        after baseline: DerivedRasterCreationActivity
    ) -> DerivedRasterCreationActivity? {
        let activity = currentActivity()
        guard activity.scheduledCount > baseline.scheduledCount,
            activity.terminalCount > baseline.terminalCount,
            activity.activeCount == 0
        else { return nil }
        return activity
    }

    private func resumeActivityWaiters() {
        let resumable = activityWaiters.compactMap { identifier, waiter in
            quiescentActivity(after: waiter.baseline).map { (identifier, waiter, $0) }
        }
        for (identifier, waiter, activity) in resumable {
            activityWaiters.removeValue(forKey: identifier)
            waiter.continuation.resume(returning: activity)
        }
    }

    private func cancelActivityWaiter(_ identifier: UUID) {
        guard let waiter = activityWaiters.removeValue(forKey: identifier) else { return }
        waiter.continuation.resume(returning: currentActivity())
    }

    private nonisolated static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == .max ? .max : value + 1
    }

    private nonisolated static func product(
        _ product: DerivedRasterCreationProduct,
        matches key: DerivedRasterArtifactKey
    ) -> Bool {
        DerivedRasterArtifactValidator.validatedSurface(
            record: product.record,
            container: product.container,
            matching: key
        ) != nil
    }
}
