import Foundation

/// 管理快速 UI 替换期间公开、无凭证请求的原编码预热任务。
///
/// 协调器只负责同一执行身份的任务去重和可取消完成通知。并发、队列、传输字节与
/// 网络优先级仍由 FetchStage 的统一资源模型控制；这里不再维护第二套隐藏并发常数。
/// 完成结果由 PipelineCache 的有界已验证编码驻留层持有，协调器本身不保留响应字节。
package actor AdaptiveEncodedWarmupCoordinator {
    private struct Key: Hashable, Sendable {
        let executionDigest: String
        let namespace: SecurityNamespaceID
    }

    private final class LaunchGate: @unchecked Sendable {
        private let lock = NSLock()
        private let maximumCount: Int
        private var claims: [Key: UUID] = [:]

        init(maximumCount: Int) {
            self.maximumCount = max(1, maximumCount)
        }

        func claim(_ key: Key) -> UUID? {
            lock.lock()
            defer { lock.unlock() }
            guard claims[key] == nil, claims.count < maximumCount else { return nil }
            let token = UUID()
            claims[key] = token
            return token
        }

        func contains(_ key: Key, token: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return claims[key] == token
        }

        func release(_ key: Key) {
            lock.lock()
            claims.removeValue(forKey: key)
            lock.unlock()
        }

        func releaseAll(where predicate: (Key) -> Bool) {
            lock.lock()
            let keys = claims.keys.filter(predicate)
            for key in keys { claims.removeValue(forKey: key) }
            lock.unlock()
        }
    }

    private struct Entry: Sendable {
        let task: Task<Void, Never>
        var waiters: [UUID: AsyncStream<Void>.Continuation]
    }

    private let maximumEntryCount: Int
    private nonisolated let launchGate: LaunchGate
    private var entries: [Key: Entry] = [:]

    package init(maximumEntryCount: Int) {
        let boundedCount = max(1, maximumEntryCount)
        self.maximumEntryCount = boundedCount
        self.launchGate = LaunchGate(maximumCount: boundedCount)
    }

    /// 在调用方线程上先按精确 fetch execution identity 领取一次性启动权，再进行
    /// actor hop。取消风暴因此至多调度一个 warmup Task，而不是先生成大量 Task、
    /// 再依赖 actor 内部去重。
    package nonisolated func schedule(
        request: ImageRequest,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        guard request.authorizationContext == .public,
            !request.containsCredentialHeaders,
            request.cachePolicy == .automatic
        else { return }

        let key = Self.key(for: request)
        guard let claimToken = launchGate.claim(key) else { return }
        Task { [weak self] in
            await self?.startClaimed(
                key: key,
                claimToken: claimToken,
                operation: operation
            )
        }
    }

    private func startClaimed(
        key: Key,
        claimToken: UUID,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        guard launchGate.contains(key, token: claimToken),
            entries[key] == nil,
            entries.count < maximumEntryCount
        else {
            launchGate.release(key)
            return
        }

        let task = Task.detached(priority: .utility) { [weak self] in
            do {
                try await operation()
            } catch {
                // 预热失败不能改变前台请求语义；完成通知只表示前台可以继续常规路径。
            }
            await self?.finish(key: key)
        }
        entries[key] = Entry(task: task, waiters: [:])
    }

    /// 返回同一执行身份的完成通知流。没有在途预热时流立即结束。
    /// AsyncStream 在等待方取消时终止，因此不会为了后台预热阻塞已消失的 UI 订阅。
    package func completionStream(for request: ImageRequest) -> AsyncStream<Void> {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let key = Self.key(for: request)
        guard var entry = entries[key] else {
            pair.continuation.finish()
            return pair.stream
        }

        let waiterID = UUID()
        entry.waiters[waiterID] = pair.continuation
        entries[key] = entry
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeWaiter(waiterID, for: key) }
        }
        return pair.stream
    }

    package func cancelAll(namespace: SecurityNamespaceID) {
        launchGate.releaseAll { $0.namespace == namespace }
        let keys = entries.keys.filter { $0.namespace == namespace }
        for key in keys { cancel(key: key) }
    }

    package func cancelAll() {
        launchGate.releaseAll { _ in true }
        let keys = Array(entries.keys)
        for key in keys { cancel(key: key) }
    }

    package func entryCount() -> Int { entries.count }

    private static func key(for request: ImageRequest) -> Key {
        Key(
            executionDigest: request.fetchExecutionKey.digestHex,
            namespace: request.namespace
        )
    }

    private func finish(key: Key) {
        launchGate.release(key)
        guard let entry = entries.removeValue(forKey: key) else { return }
        for continuation in entry.waiters.values {
            continuation.yield(())
            continuation.finish()
        }
    }

    private func cancel(key: Key) {
        launchGate.release(key)
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.task.cancel()
        for continuation in entry.waiters.values { continuation.finish() }
    }

    private func removeWaiter(_ waiterID: UUID, for key: Key) {
        guard var entry = entries[key] else { return }
        entry.waiters.removeValue(forKey: waiterID)
        entries[key] = entry
    }
}
