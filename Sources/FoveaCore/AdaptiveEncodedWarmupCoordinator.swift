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

    private struct Entry: Sendable {
        let task: Task<Void, Never>
        var waiters: [UUID: AsyncStream<Void>.Continuation]
    }

    private let maximumEntryCount: Int
    private var entries: [Key: Entry] = [:]

    package init(maximumEntryCount: Int) {
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    package func start(
        request: ImageRequest,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        guard request.authorizationContext == .public,
            !request.containsCredentialHeaders,
            request.cachePolicy == .automatic
        else { return }

        let key = Self.key(for: request)
        guard entries[key] == nil, entries.count < maximumEntryCount else { return }

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
        let keys = entries.keys.filter { $0.namespace == namespace }
        for key in keys { cancel(key: key) }
    }

    package func cancelAll() {
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
        guard let entry = entries.removeValue(forKey: key) else { return }
        for continuation in entry.waiters.values {
            continuation.yield(())
            continuation.finish()
        }
    }

    private func cancel(key: Key) {
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
