import Foundation

package enum PermitPoolError: Error, Sendable {
  case queueLimitExceeded
}

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
    var priority: ImageRequestPriority
    let sequence: UInt64
    var bypassCount: Int
  }

  private static let maximumPriorityBypasses = 8

  private var available: Int
  private let queueLimit: Int
  private var granted: Set<UUID> = []
  private var waiters: [UUID: Waiter] = [:]
  private var cancelledBeforeEnqueue: Set<UUID> = []
  private var nextSequence: UInt64 = 0

  package init(limit: Int, queueLimit: Int) {
    self.available = max(1, limit)
    self.queueLimit = max(0, queueLimit)
  }

  package func acquire(
    priority: ImageRequestPriority = .normal,
    priorityUpdates: AsyncStream<ImageRequestPriority>? = nil
  ) async throws -> Permit {
    try Task.checkCancellation()
    let identifier = UUID()
    if available > 0 {
      available -= 1
      granted.insert(identifier)
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
        enqueue(identifier, priority: priority, continuation: continuation)
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

  private func enqueue(
    _ identifier: UUID,
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
    if granted.contains(identifier) {
      release(identifier)
      return
    }
    cancelledBeforeEnqueue.insert(identifier)
  }

  private func release(_ identifier: UUID) {
    guard granted.remove(identifier) != nil else { return }
    guard let next = nextWaiterIdentifier(), let waiter = waiters.removeValue(forKey: next) else {
      available += 1
      return
    }

    for (identifier, var other) in waiters {
      other.bypassCount = min(Self.maximumPriorityBypasses, other.bypassCount + 1)
      waiters[identifier] = other
    }
    granted.insert(next)
    waiter.continuation.resume(returning: true)
  }

  private func nextWaiterIdentifier() -> UUID? {
    if let starved = waiters.min(by: { lhs, rhs in
      let leftStarved = lhs.value.bypassCount >= Self.maximumPriorityBypasses
      let rightStarved = rhs.value.bypassCount >= Self.maximumPriorityBypasses
      if leftStarved != rightStarved { return leftStarved && !rightStarved }
      return lhs.value.sequence < rhs.value.sequence
    }), starved.value.bypassCount >= Self.maximumPriorityBypasses {
      return starved.key
    }

    return waiters.max { lhs, rhs in
      if lhs.value.priority != rhs.value.priority {
        return lhs.value.priority < rhs.value.priority
      }
      return lhs.value.sequence > rhs.value.sequence
    }?.key
  }
}
