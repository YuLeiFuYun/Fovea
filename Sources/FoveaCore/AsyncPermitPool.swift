import Foundation

package enum PermitPoolError: Error, Sendable {
  case queueLimitExceeded
  case requestExceedsLimit
}

/// 支持优先级、防饥饿与带权容量的可取消异步许可池。
package actor AsyncPermitPool {
  package struct Permit: Sendable {
    fileprivate let identifier: UUID
    fileprivate let pool: AsyncPermitPool

    package func release() async {
      await pool.release(identifier)
    }
  }

  private struct Waiter {
    let continuation: CheckedContinuation<Bool, Never>
    let units: Int
    var priority: ImageRequestPriority
    let sequence: UInt64
    var bypassCount: Int
  }

  private static let maximumPriorityBypasses = 8

  private let capacity: Int
  private var available: Int
  private let queueLimit: Int
  private var granted: [UUID: Int] = [:]
  private var waiters: [UUID: Waiter] = [:]
  private var cancelledBeforeEnqueue: Set<UUID> = []
  private var nextSequence: UInt64 = 0

  package init(limit: Int, queueLimit: Int) {
    let capacity = max(1, limit)
    self.capacity = capacity
    self.available = capacity
    self.queueLimit = max(0, queueLimit)
  }

  package func acquire(
    units: Int = 1,
    priority: ImageRequestPriority = .normal,
    priorityUpdates: AsyncStream<ImageRequestPriority>? = nil
  ) async throws -> Permit {
    try Task.checkCancellation()
    let units = max(1, units)
    guard units <= capacity else { throw PermitPoolError.requestExceedsLimit }

    let identifier = UUID()
    if available >= units {
      available -= units
      granted[identifier] = units
      if Task.isCancelled {
        release(identifier)
        throw CancellationError()
      }
      return Permit(identifier: identifier, pool: self)
    }

    guard waiters.count < queueLimit else { throw PermitPoolError.queueLimitExceeded }
    let priorityObserver = priorityUpdates.map { updates in
      Task { @concurrent [weak self] in
        for await updatedPriority in updates {
          await self?.updatePriority(identifier, to: updatedPriority)
        }
      }
    }
    defer { priorityObserver?.cancel() }

    let acquired = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        enqueue(
          identifier,
          units: units,
          priority: priority,
          continuation: continuation
        )
      }
    } onCancel: {
      Task { await self.cancel(identifier) }
    }

    guard acquired else { throw CancellationError() }
    if Task.isCancelled {
      release(identifier)
      throw CancellationError()
    }
    return Permit(identifier: identifier, pool: self)
  }

  package func queuedCount() -> Int { waiters.count }

  package func queuedPriorities() -> [ImageRequestPriority] {
    waiters.values.map(\.priority)
  }

  package var usedUnits: Int { capacity - available }

  private func enqueue(
    _ identifier: UUID,
    units: Int,
    priority: ImageRequestPriority,
    continuation: CheckedContinuation<Bool, Never>
  ) {
    if cancelledBeforeEnqueue.remove(identifier) != nil {
      continuation.resume(returning: false)
      return
    }
    nextSequence &+= 1
    waiters[identifier] = Waiter(
      continuation: continuation,
      units: units,
      priority: priority,
      sequence: nextSequence,
      bypassCount: 0
    )
  }

  private func updatePriority(_ identifier: UUID, to priority: ImageRequestPriority) {
    guard var waiter = waiters[identifier] else { return }
    waiter.priority = priority
    waiters[identifier] = waiter
  }

  private func cancel(_ identifier: UUID) {
    if let waiter = waiters.removeValue(forKey: identifier) {
      waiter.continuation.resume(returning: false)
      return
    }
    if granted[identifier] != nil {
      release(identifier)
      return
    }
    cancelledBeforeEnqueue.insert(identifier)
  }

  private func release(_ identifier: UUID) {
    guard let units = granted.removeValue(forKey: identifier) else { return }
    available = min(capacity, available + units)
    grantFittingWaiters()
  }

  private func grantFittingWaiters() {
    while let next = nextWaiterIdentifier(),
      let waiter = waiters.removeValue(forKey: next)
    {
      available -= waiter.units
      for (identifier, var other) in waiters {
        other.bypassCount = min(Self.maximumPriorityBypasses, other.bypassCount + 1)
        waiters[identifier] = other
      }
      granted[next] = waiter.units
      waiter.continuation.resume(returning: true)
    }
  }

  private func nextWaiterIdentifier() -> UUID? {
    let fitting = waiters.filter { $0.value.units <= available }
    guard !fitting.isEmpty else { return nil }

    if let starved = fitting.min(by: { lhs, rhs in
      let leftStarved = lhs.value.bypassCount >= Self.maximumPriorityBypasses
      let rightStarved = rhs.value.bypassCount >= Self.maximumPriorityBypasses
      if leftStarved != rightStarved { return leftStarved && !rightStarved }
      return lhs.value.sequence < rhs.value.sequence
    }), starved.value.bypassCount >= Self.maximumPriorityBypasses {
      return starved.key
    }

    return fitting.max { lhs, rhs in
      if lhs.value.priority != rhs.value.priority {
        return lhs.value.priority < rhs.value.priority
      }
      return lhs.value.sequence > rhs.value.sequence
    }?.key
  }
}
