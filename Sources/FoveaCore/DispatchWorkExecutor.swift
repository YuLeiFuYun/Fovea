import Dispatch

/// 在 Swift 协作式执行器之外运行同步且可能阻塞的 CPU 工作。
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
