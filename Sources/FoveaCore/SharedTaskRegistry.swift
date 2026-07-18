import Foundation

public actor SharedTaskRegistry<Key: Hashable & Sendable, Value: Sendable> {
  private struct Entry {
    let taskID: UUID
    let task: Task<Value, Error>
    var subscribers: Set<UUID>
  }

  private var entries: [Key: Entry] = [:]
  private var cancellationCounts: [Key: Int] = [:]

  public init() {}

  public func subscribe(
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
    let task = Task { try await operation() }
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

  public func release(key: Key, subscriberID: UUID) {
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

  public func subscriberCount(for key: Key) -> Int {
    entries[key]?.subscribers.count ?? 0
  }

  public func cancellationCount(for key: Key) -> Int {
    cancellationCounts[key, default: 0]
  }

  public func completed(key: Key, taskID: UUID) {
    guard entries[key]?.taskID == taskID else { return }
    entries.removeValue(forKey: key)
  }
}

public struct SharedTaskSubscription<Key: Hashable & Sendable, Value: Sendable>: Sendable {
  fileprivate let key: Key
  fileprivate let taskID: UUID
  fileprivate let subscriberID: UUID
  fileprivate let task: Task<Value, Error>
  fileprivate let registry: SharedTaskRegistry<Key, Value>
  public let wasJoined: Bool

  public func value() async throws -> Value {
    let result = await task.result
    await registry.completed(key: key, taskID: taskID)
    return try result.get()
  }

  public func cancel() async {
    await registry.release(key: key, subscriberID: subscriberID)
  }
}
