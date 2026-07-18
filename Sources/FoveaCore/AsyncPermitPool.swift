import Foundation

package enum PermitPoolError: Error, Sendable {
  case queueLimitExceeded
}

actor AsyncPermitPool {
  struct Permit: Sendable {
    fileprivate let identifier: UUID
    fileprivate let pool: AsyncPermitPool

    func release() async {
      await pool.release(identifier)
    }
  }

  private var available: Int
  private let queueLimit: Int
  private var granted: Set<UUID> = []
  private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
  private var waiterOrder: [UUID] = []
  private var waiterHead = 0
  private var cancelledBeforeEnqueue: Set<UUID> = []

  init(limit: Int, queueLimit: Int) {
    self.available = max(1, limit)
    self.queueLimit = max(0, queueLimit)
  }

  func acquire() async throws -> Permit {
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
    let acquired = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        enqueue(identifier, continuation: continuation)
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

  private func enqueue(
    _ identifier: UUID,
    continuation: CheckedContinuation<Bool, Never>
  ) {
    if cancelledBeforeEnqueue.remove(identifier) != nil {
      continuation.resume(returning: false)
      return
    }
    waiters[identifier] = continuation
    waiterOrder.append(identifier)
  }

  private func cancel(_ identifier: UUID) {
    if let continuation = waiters.removeValue(forKey: identifier) {
      continuation.resume(returning: false)
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
    while waiterHead < waiterOrder.count {
      let next = waiterOrder[waiterHead]
      waiterHead += 1
      guard let continuation = waiters.removeValue(forKey: next) else { continue }
      compactWaiterOrderIfNeeded()
      granted.insert(next)
      continuation.resume(returning: true)
      return
    }
    waiterOrder.removeAll(keepingCapacity: true)
    waiterHead = 0
    available += 1
  }

  private func compactWaiterOrderIfNeeded() {
    guard waiterHead >= 1_024, waiterHead * 2 >= waiterOrder.count else { return }
    waiterOrder.removeFirst(waiterHead)
    waiterHead = 0
  }
}
