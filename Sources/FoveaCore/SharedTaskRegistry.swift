import Foundation

/// 标记一个顶层调用进入共享管线的单调时刻。
///
/// 共享任务取消墓碑用该值区分两类调用：取消前已经开始、但因上游异步阶段而较晚
/// 到达 registry 的同批调用；以及取消后才真正创建的新调用。前者可以进入 replacement
/// cohort，后者在租约窗口内只能观察原任务的取消终态。
package struct SharedTaskAdmission: Sendable, Equatable {
    package let startedAtNanoseconds: UInt64

    package init(startedAtNanoseconds: UInt64) {
        self.startedAtNanoseconds = startedAtNanoseconds
    }

    package static func now() -> Self {
        Self(startedAtNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
}

/// 在一个顶层管线调用的 fetch/decode/transform 链路中传播共享任务 admission。
package enum SharedTaskAdmissionContext {
    @TaskLocal package static var current: SharedTaskAdmission?
}

package actor SharedTaskPriorityControl {
    private var priority: ImageRequestPriority
    private var continuations: [UUID: AsyncStream<ImageRequestPriority>.Continuation] = [:]
    private var isFinished = false

    package init(priority: ImageRequestPriority) {
        self.priority = priority
    }

    package func currentPriority() -> ImageRequestPriority { priority }

    package func updates() -> AsyncStream<ImageRequestPriority> {
        let identifier = UUID()
        let stream = AsyncStream<ImageRequestPriority>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        guard !isFinished else {
            stream.continuation.finish()
            return stream.stream
        }
        continuations[identifier] = stream.continuation
        stream.continuation.yield(priority)
        stream.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(identifier) }
        }
        return stream.stream
    }

    fileprivate func update(_ newPriority: ImageRequestPriority) {
        guard !isFinished, newPriority != priority else { return }
        priority = newPriority
        for continuation in continuations.values {
            continuation.yield(newPriority)
        }
    }

    package func finish() {
        guard !isFinished else { return }
        isFinished = true
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll(keepingCapacity: false)
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }
}

package actor SharedTaskRegistry<Key: Hashable & Sendable, Value: Sendable> {
    private struct Entry {
        let taskID: UUID
        let task: Task<Value, Error>
        let priorityControl: SharedTaskPriorityControl
        var subscribers: [UUID: ImageRequestPriority]
        var orphanLeaseID: UUID?
        var completed: Bool
    }

    private struct CancellationTombstone {
        let leaseID: UUID
        let task: Task<Value, Error>
        let priorityControl: SharedTaskPriorityControl
        let cutoffNanoseconds: UInt64
        let expiresAtNanoseconds: UInt64
    }

    private let recordsCancellationCounts: Bool
    private var entries: [Key: Entry] = [:]
    private var cancellationTombstones: [Key: CancellationTombstone] = [:]
    private var cancellationCounts: [Key: Int] = [:]

    deinit {
        for entry in entries.values { entry.task.cancel() }
        for tombstone in cancellationTombstones.values { tombstone.task.cancel() }
    }

    /// 逐键取消计数属于测试仪器，默认关闭。
    /// 获取与解码键具有高基数；生产环境保留它们会形成
    /// 与请求执行无关的无界旁路表。
    package init(recordsCancellationCounts: Bool = false) {
        self.recordsCancellationCounts = recordsCancellationCounts
    }

    package func subscribe(
        key: Key,
        priority: ImageRequestPriority = .normal,
        admission: SharedTaskAdmission = .now(),
        operation: @escaping @Sendable () async throws -> Value
    ) async -> SharedTaskSubscription<Key, Value> {
        await subscribe(
            key: key,
            priority: priority,
            admission: admission
        ) { _ in
            try await operation()
        }
    }

    package func subscribe(
        key: Key,
        priority: ImageRequestPriority,
        admission: SharedTaskAdmission = .now(),
        operation: @escaping @Sendable (SharedTaskPriorityControl) async throws -> Value
    ) async -> SharedTaskSubscription<Key, Value> {
        let subscriberID = UUID()
        let now = DispatchTime.now().uptimeNanoseconds
        await expireCancellationTombstoneIfElapsed(key: key, nowNanoseconds: now)

        if let tombstone = cancellationTombstones[key],
            admission.startedAtNanoseconds > tombstone.cutoffNanoseconds
        {
            return SharedTaskSubscription(
                key: key,
                taskID: UUID(),
                subscriberID: subscriberID,
                task: tombstone.task,
                registry: self,
                priorityControl: tombstone.priorityControl,
                wasJoined: true
            )
        }

        if var entry = entries[key] {
            let completedResultIsJoinable =
                !entry.completed
                || entry.orphanLeaseID != nil
                || cancellationTombstones[key] != nil
            if completedResultIsJoinable {
                let previous = Self.effectivePriority(entry.subscribers)
                entry.subscribers[subscriberID] = priority
                entry.orphanLeaseID = nil
                let effective = Self.effectivePriority(entry.subscribers)
                entries[key] = entry
                if effective != previous { await entry.priorityControl.update(effective) }
                return SharedTaskSubscription(
                    key: key,
                    taskID: entry.taskID,
                    subscriberID: subscriberID,
                    task: entry.task,
                    registry: self,
                    priorityControl: entry.priorityControl,
                    wasJoined: true
                )
            }

            // 普通已完成结果不是缓存。仅显式 orphan-handoff 租约或 cancellation
            // replacement cohort 可复用它；否则新调用必须启动独立执行。
            entries.removeValue(forKey: key)
            await entry.priorityControl.finish()
        }

        return await startEntry(
            key: key,
            subscriberID: subscriberID,
            priority: priority,
            operation: operation
        )
    }

    package func release(
        key: Key,
        subscriberID: UUID,
        cancelTaskWhenUnused: Bool = true,
        handoffGraceNanoseconds: UInt64 = 0,
        cancelledTaskRetentionNanoseconds: UInt64 = 0
    ) async {
        guard var entry = entries[key], entry.subscribers.removeValue(forKey: subscriberID) != nil
        else { return }

        guard entry.subscribers.isEmpty else {
            entries[key] = entry
            let effective = Self.effectivePriority(entry.subscribers)
            await entry.priorityControl.update(effective)
            return
        }

        if entry.completed {
            if !cancelTaskWhenUnused {
                installOrphanLease(
                    key: key,
                    entry: &entry,
                    handoffGraceNanoseconds: handoffGraceNanoseconds
                )
            } else if cancellationTombstones[key] != nil {
                // cancellation lease 到期前保留 replacement cohort 的已完成 Task，
                // 使取消前已开始但更晚到达的调用只复用结果，不再次启动底层操作。
                entries[key] = entry
            } else {
                entries.removeValue(forKey: key)
                await entry.priorityControl.finish()
            }
            return
        }

        if cancelTaskWhenUnused {
            entry.task.cancel()
            entries.removeValue(forKey: key)
            recordCancellation(for: key)
            await entry.priorityControl.finish()
            guard cancelledTaskRetentionNanoseconds > 0 else { return }
            installCancellationTombstone(
                key: key,
                task: entry.task,
                priorityControl: entry.priorityControl,
                retentionNanoseconds: cancelledTaskRetentionNanoseconds
            )
            return
        }

        installOrphanLease(
            key: key,
            entry: &entry,
            handoffGraceNanoseconds: handoffGraceNanoseconds
        )
    }

    package func subscriberCount(for key: Key) -> Int {
        entries[key]?.subscribers.count ?? 0
    }

    package func effectivePriority(for key: Key) async -> ImageRequestPriority? {
        guard let entry = entries[key], !entry.completed else { return nil }
        return await entry.priorityControl.currentPriority()
    }

    package func cancellationCount(for key: Key) -> Int {
        cancellationCounts[key, default: 0]
    }

    package func recordedCancellationKeyCount() -> Int {
        cancellationCounts.count
    }

    @discardableResult
    package func cancelAll(where predicate: @Sendable (Key) -> Bool) async -> Int {
        let keys = Set(entries.keys.filter(predicate)).union(
            cancellationTombstones.keys.filter(predicate)
        )
        for key in keys {
            if let entry = entries.removeValue(forKey: key) {
                entry.task.cancel()
                await entry.priorityControl.finish()
            }
            if let tombstone = cancellationTombstones.removeValue(forKey: key) {
                tombstone.task.cancel()
                await tombstone.priorityControl.finish()
            }
            recordCancellation(for: key)
        }
        return keys.count
    }

    package func completed(key: Key, taskID: UUID) async {
        guard var entry = entries[key], entry.taskID == taskID else { return }
        entry.completed = true

        // 保留到最后一个现有订阅者明确 release；这使“任务先完成、随后订阅取消并
        // detach”的线性化顺序仍可安装有限交接租约。subscribe 对无租约的 completed
        // entry 会先删除再启动新执行，因此普通完成结果仍不可被迟到调用复用。
        if !entry.subscribers.isEmpty
            || entry.orphanLeaseID != nil
            || cancellationTombstones[key] != nil
        {
            entries[key] = entry
        } else {
            entries.removeValue(forKey: key)
        }
        await entry.priorityControl.finish()
    }

    private func startEntry(
        key: Key,
        subscriberID: UUID,
        priority: ImageRequestPriority,
        operation: @escaping @Sendable (SharedTaskPriorityControl) async throws -> Value
    ) async -> SharedTaskSubscription<Key, Value> {
        let taskID = UUID()
        let priorityControl = SharedTaskPriorityControl(priority: priority)
        let startGate = SharedTaskStartGate()
        let task = Task { @concurrent [weak self] in
            await startGate.wait()
            do {
                try Task.checkCancellation()
                let value = try await operation(priorityControl)
                await self?.completed(key: key, taskID: taskID)
                return value
            } catch {
                await self?.completed(key: key, taskID: taskID)
                throw error
            }
        }
        entries[key] = Entry(
            taskID: taskID,
            task: task,
            priorityControl: priorityControl,
            subscribers: [subscriberID: priority],
            orphanLeaseID: nil,
            completed: false
        )
        await startGate.open()
        return SharedTaskSubscription(
            key: key,
            taskID: taskID,
            subscriberID: subscriberID,
            task: task,
            registry: self,
            priorityControl: priorityControl,
            wasJoined: false
        )
    }

    private func installCancellationTombstone(
        key: Key,
        task: Task<Value, Error>,
        priorityControl: SharedTaskPriorityControl,
        retentionNanoseconds: UInt64
    ) {
        let leaseID = UUID()
        let now = DispatchTime.now().uptimeNanoseconds
        let cutoff = cancellationTombstones[key]?.cutoffNanoseconds ?? now
        let (candidateExpiry, overflow) = now.addingReportingOverflow(retentionNanoseconds)
        let expiresAt = overflow ? UInt64.max : candidateExpiry
        cancellationTombstones[key] = CancellationTombstone(
            leaseID: leaseID,
            task: task,
            priorityControl: priorityControl,
            cutoffNanoseconds: cutoff,
            expiresAtNanoseconds: expiresAt
        )
        Task { @concurrent [weak self] in
            do {
                try await Task.sleep(nanoseconds: retentionNanoseconds)
            } catch {
                return
            }
            await self?.expireCancellationTombstone(key: key, leaseID: leaseID)
        }
    }

    private func expireCancellationTombstoneIfElapsed(
        key: Key,
        nowNanoseconds: UInt64
    ) async {
        guard let tombstone = cancellationTombstones[key],
            nowNanoseconds >= tombstone.expiresAtNanoseconds
        else { return }
        await removeCancellationTombstone(key: key, tombstone: tombstone)
    }

    private func expireCancellationTombstone(key: Key, leaseID: UUID) async {
        guard let tombstone = cancellationTombstones[key], tombstone.leaseID == leaseID else {
            return
        }
        await removeCancellationTombstone(key: key, tombstone: tombstone)
    }

    private func removeCancellationTombstone(
        key: Key,
        tombstone: CancellationTombstone
    ) async {
        guard cancellationTombstones[key]?.leaseID == tombstone.leaseID else { return }
        cancellationTombstones.removeValue(forKey: key)
        let completedEntry = entries[key].flatMap { entry in
            entry.completed && entry.subscribers.isEmpty ? entry : nil
        }
        if completedEntry != nil {
            entries.removeValue(forKey: key)
        }

        await tombstone.priorityControl.finish()
        if let completedEntry {
            await completedEntry.priorityControl.finish()
        }
    }

    private func installOrphanLease(
        key: Key,
        entry: inout Entry,
        handoffGraceNanoseconds: UInt64
    ) {
        let leaseID = UUID()
        entry.orphanLeaseID = leaseID
        let taskID = entry.taskID
        entries[key] = entry
        Task { @concurrent [weak self] in
            if handoffGraceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: handoffGraceNanoseconds)
            }
            await self?.expireOrphanedTask(
                key: key,
                taskID: taskID,
                leaseID: leaseID
            )
        }
    }

    private func expireOrphanedTask(
        key: Key,
        taskID: UUID,
        leaseID: UUID
    ) async {
        guard let entry = entries[key],
            entry.taskID == taskID,
            entry.orphanLeaseID == leaseID,
            entry.subscribers.isEmpty
        else { return }

        entries.removeValue(forKey: key)
        if !entry.completed {
            entry.task.cancel()
            recordCancellation(for: key)
        }
        await entry.priorityControl.finish()
    }

    private func recordCancellation(for key: Key) {
        guard recordsCancellationCounts else { return }
        let current = cancellationCounts[key, default: 0]
        cancellationCounts[key] = current == Int.max ? Int.max : current + 1
    }

    private static func effectivePriority(
        _ subscribers: [UUID: ImageRequestPriority]
    ) -> ImageRequestPriority {
        subscribers.values.max() ?? .normal
    }
}

package struct SharedTaskSubscription<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    fileprivate let key: Key
    fileprivate let taskID: UUID
    fileprivate let subscriberID: UUID
    fileprivate let task: Task<Value, Error>
    fileprivate let registry: SharedTaskRegistry<Key, Value>
    package let priorityControl: SharedTaskPriorityControl
    package let wasJoined: Bool

    package func value() async throws -> Value {
        let relay = SubscriptionResultRelay<Value>()
        let waiter = Task { @concurrent in
            await relay.resolve(task.result)
        }
        defer { waiter.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { await relay.install(continuation) }
            }
        } onCancel: {
            Task { await relay.resolve(.failure(CancellationError())) }
        }
    }

    package func cancel() async {
        await registry.release(key: key, subscriberID: subscriberID)
    }

    /// 取消最后一个订阅者时立即终止底层任务，并短暂保留不可复活的取消墓碑。
    /// 租约窗口内，真正的新调用只能观察原任务的取消结果；取消前已经开始的调用可进入
    /// replacement cohort，从而不被较早到达的取消订阅者连带终止。
    package func cancel(retainingCancelledTaskForNanoseconds retention: UInt64) async {
        await registry.release(
            key: key,
            subscriberID: subscriberID,
            cancelledTaskRetentionNanoseconds: retention
        )
    }

    /// 终止当前订阅者的等待，但保留已启动的共享任务，允许后续订阅者完成交接。
    package func detach(handoffGraceNanoseconds: UInt64 = 250_000_000) async {
        await registry.release(
            key: key,
            subscriberID: subscriberID,
            cancelTaskWhenUnused: false,
            handoffGraceNanoseconds: handoffGraceNanoseconds
        )
    }
}

private actor SharedTaskStartGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll(keepingCapacity: false)
    }
}

private actor SubscriptionResultRelay<Value: Sendable> {
    private enum State {
        case empty
        case waiting(CheckedContinuation<Value, any Error>)
        case resolved(Result<Value, any Error>)
        case finished
    }

    private var state: State = .empty

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        switch state {
        case .empty:
            state = .waiting(continuation)
        case .resolved(let result):
            state = .finished
            continuation.resume(with: result)
        case .waiting, .finished:
            continuation.resume(throwing: CancellationError())
        }
    }

    func resolve(_ result: Result<Value, any Error>) {
        switch state {
        case .empty:
            state = .resolved(result)
        case .waiting(let continuation):
            state = .finished
            continuation.resume(with: result)
        case .resolved, .finished:
            break
        }
    }
}
