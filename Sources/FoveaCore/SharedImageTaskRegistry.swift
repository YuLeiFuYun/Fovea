import Foundation
import ImageCraftCore

public actor SharedImageTaskRegistry {
  private struct Entry {
    let taskID: UUID
    let task: Task<DecodedImage, Error>
    var subscribers: Set<UUID>
  }

  private var entries: [FetchExecutionKey: Entry] = [:]
  private var cancellationCounts: [FetchExecutionKey: Int] = [:]

  public init() {}

  public func subscribe(
    key: FetchExecutionKey,
    operation: @escaping @Sendable () async throws -> DecodedImage
  ) -> ImageTaskSubscription {
    let subscriberID = UUID()
    if var entry = entries[key] {
      entry.subscribers.insert(subscriberID)
      entries[key] = entry
      return ImageTaskSubscription(
        key: key, taskID: entry.taskID, subscriberID: subscriberID, task: entry.task, registry: self
      )
    }

    let taskID = UUID()
    let task = Task { try await operation() }
    entries[key] = Entry(taskID: taskID, task: task, subscribers: [subscriberID])
    return ImageTaskSubscription(
      key: key,
      taskID: taskID,
      subscriberID: subscriberID,
      task: task,
      registry: self
    )
  }

  public func release(key: FetchExecutionKey, subscriberID: UUID) {
    guard var entry = entries[key], entry.subscribers.remove(subscriberID) != nil else { return }
    if entry.subscribers.isEmpty {
      entry.task.cancel()
      cancellationCounts[key, default: 0] += 1
      entries.removeValue(forKey: key)
    } else {
      entries[key] = entry
    }
  }

  public func subscriberCount(for key: FetchExecutionKey) -> Int {
    entries[key]?.subscribers.count ?? 0
  }

  public func cancellationCount(for key: FetchExecutionKey) -> Int {
    cancellationCounts[key, default: 0]
  }

  public func completed(key: FetchExecutionKey, taskID: UUID) {
    guard entries[key]?.taskID == taskID else { return }
    entries.removeValue(forKey: key)
  }
}

public struct ImageTaskSubscription: Sendable {
  fileprivate let key: FetchExecutionKey
  fileprivate let taskID: UUID
  fileprivate let subscriberID: UUID
  fileprivate let task: Task<DecodedImage, Error>
  fileprivate let registry: SharedImageTaskRegistry

  public func value() async throws -> DecodedImage {
    let result = await task.result
    await registry.completed(key: key, taskID: taskID)
    return try result.get()
  }

  public func cancel() async {
    await registry.release(key: key, subscriberID: subscriberID)
  }
}
