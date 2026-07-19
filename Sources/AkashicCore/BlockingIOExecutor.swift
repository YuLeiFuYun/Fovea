import Dispatch

/// 将阻塞文件系统操作隔离到专用串行队列，避免占用 Swift 协作式执行器。
package final class BlockingIOExecutor: SerialExecutor {
  private let queue: DispatchQueue

  package init(label: String) {
    self.queue = DispatchQueue(label: label, qos: .utility, autoreleaseFrequency: .workItem)
  }

  package func enqueue(_ job: UnownedJob) {
    queue.async {
      job.runSynchronously(on: self.asUnownedSerialExecutor())
    }
  }

  package func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(ordinary: self)
  }
}
