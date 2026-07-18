import Foundation

package actor SharedTaskRegistry<Key: Hashable & Sendable, Value: Sendable> {
  private struct Entry {
    let taskID: UUID
    let task: Task<Value, Error>
    var subscribers: Set<UUID>
  }

  private var entries: [Key: Entry] = [:]
  private var cancellationCounts: [Key: Int] = [:]

  package init() {}

  package func subscribe(
    key: Key,
    operation: @escaping @Sendable () async throws -> Value
  ) -> SharedTaskSubscription<Key, Value> {
    let subscriberID = UUID()
    if var entry = entries[key] {
      entry.subscribers.insert(subscriberID)
      entries[key] = entry
      return SharedTaskSubscription(
        key: key,
        taskID: entry.taskID,
        subscriberID: subscriberID,
        task: entry.task,
        registry: self,
        wasJoined: true
      )
    }

    let taskID = UUID()
    let task = Task { @concurrent in try await operation() }
    entries[key] = Entry(taskID: taskID, task: task, subscribers: [subscriberID])
    return SharedTaskSubscription(
      key: key,
      taskID: taskID,
      subscriberID: subscriberID,
      task: task,
      registry: self,
      wasJoined: false
    )
  }

  package func release(key: Key, subscriberID: UUID) {
    guard var entry = entries[key], entry.subscribers.remove(subscriberID) != nil else {
      return
    }
    if entry.subscribers.isEmpty {
      entry.task.cancel()
      cancellationCounts[key, default: 0] += 1
      entries.removeValue(forKey: key)
    } else {
      entries[key] = entry
    }
  }

  package func subscriberCount(for key: Key) -> Int {
    entries[key]?.subscribers.count ?? 0
  }

  package func cancellationCount(for key: Key) -> Int {
    cancellationCounts[key, default: 0]
  }

  @discardableResult
  package func cancelAll(where predicate: @Sendable (Key) -> Bool) -> Int {
    let keys = entries.keys.filter(predicate)
    for key in keys {
      guard let entry = entries.removeValue(forKey: key) else { continue }
      entry.task.cancel()
      cancellationCounts[key, default: 0] += 1
    }
    return keys.count
  }

  package func completed(key: Key, taskID: UUID) {
    guard entries[key]?.taskID == taskID else { return }
    entries.removeValue(forKey: key)
  }
}

package struct SharedTaskSubscription<Key: Hashable & Sendable, Value: Sendable>: Sendable {
  fileprivate let key: Key
  fileprivate let taskID: UUID
  fileprivate let subscriberID: UUID
  fileprivate let task: Task<Value, Error>
  fileprivate let registry: SharedTaskRegistry<Key, Value>
  package let wasJoined: Bool

  package func value() async throws -> Value {
    let relay = SubscriptionResultRelay<Value>()
    let waiter = Task { @concurrent in
      let result = await task.result
      await registry.completed(key: key, taskID: taskID)
      await relay.resolve(result)
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
