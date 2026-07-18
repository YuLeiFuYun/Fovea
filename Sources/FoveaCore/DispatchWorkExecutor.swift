import Dispatch

/// Runs synchronous, potentially blocking CPU work outside Swift's cooperative executor.
package final class DispatchWorkExecutor: Sendable {
  private let queue: DispatchQueue

  package init(label: String, qos: DispatchQoS = .userInitiated) {
    self.queue = DispatchQueue(
      label: label,
      qos: qos,
      attributes: .concurrent,
      autoreleaseFrequency: .workItem
    )
  }

  package func run<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        continuation.resume(with: Result(catching: operation))
      }
    }
  }
}
