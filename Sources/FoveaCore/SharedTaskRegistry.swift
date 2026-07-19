import Foundation

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
  }

  private var entries: [Key: Entry] = [:]
  private var cancellationCounts: [Key: Int] = [:]

  package init() {}

  package func subscribe(
    key: Key,
    priority: ImageRequestPriority = .normal,
    operation: @escaping @Sendable () async throws -> Value
  ) async -> SharedTaskSubscription<Key, Value> {
    await subscribe(key: key, priority: priority) { _ in try await operation() }
  }

  package func subscribe(
    key: Key,
    priority: ImageRequestPriority,
    operation: @escaping @Sendable (SharedTaskPriorityControl) async throws -> Value
  ) async -> SharedTaskSubscription<Key, Value> {
    let subscriberID = UUID()
    if var entry = entries[key] {
      let previous = Self.effectivePriority(entry.subscribers)
      entry.subscribers[subscriberID] = priority
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

    let taskID = UUID()
    let priorityControl = SharedTaskPriorityControl(priority: priority)
    let task = Task { @concurrent in try await operation(priorityControl) }
    entries[key] = Entry(
      taskID: taskID,
      task: task,
      priorityControl: priorityControl,
      subscribers: [subscriberID: priority]
    )
    Task { [task] in
      _ = await task.result
      await self.completed(key: key, taskID: taskID)
    }
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

  package func release(
    key: Key,
    subscriberID: UUID,
    cancelTaskWhenUnused: Bool = true
  ) async {
    guard var entry = entries[key], entry.subscribers.removeValue(forKey: subscriberID) != nil
    else { return }
    if entry.subscribers.isEmpty, cancelTaskWhenUnused {
      entry.task.cancel()
      cancellationCounts[key, default: 0] += 1
      entries.removeValue(forKey: key)
      await entry.priorityControl.finish()
    } else {
      entries[key] = entry
      if !entry.subscribers.isEmpty {
        let effective = Self.effectivePriority(entry.subscribers)
        await entry.priorityControl.update(effective)
      }
    }
  }

  package func subscriberCount(for key: Key) -> Int {
    entries[key]?.subscribers.count ?? 0
  }

  package func effectivePriority(for key: Key) async -> ImageRequestPriority? {
    guard let control = entries[key]?.priorityControl else { return nil }
    return await control.currentPriority()
  }

  package func cancellationCount(for key: Key) -> Int {
    cancellationCounts[key, default: 0]
  }

  @discardableResult
  package func cancelAll(where predicate: @Sendable (Key) -> Bool) async -> Int {
    let keys = entries.keys.filter(predicate)
    for key in keys {
      guard let entry = entries.removeValue(forKey: key) else { continue }
      entry.task.cancel()
      cancellationCounts[key, default: 0] += 1
      await entry.priorityControl.finish()
    }
    return keys.count
  }

  package func completed(key: Key, taskID: UUID) async {
    guard let entry = entries[key], entry.taskID == taskID else { return }
    entries.removeValue(forKey: key)
    await entry.priorityControl.finish()
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

  /// 终止当前订阅者的等待，但保留已启动的共享任务，允许后续订阅者完成交接。
  package func detach() async {
    await registry.release(
      key: key,
      subscriberID: subscriberID,
      cancelTaskWhenUnused: false
    )
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
