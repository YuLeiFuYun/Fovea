import Dispatch

/// 将阻塞文件系统操作隔离到专用串行队列，避免占用 Swift cooperative executor。
public final class BlockingIOExecutor: SerialExecutor {
  private let queue: DispatchQueue

  public init(label: String) {
    self.queue = DispatchQueue(label: label, qos: .utility)
  }

  public func enqueue(_ job: UnownedJob) {
    queue.async {
      job.runSynchronously(on: self.asUnownedSerialExecutor())
    }
  }

  public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(ordinary: self)
  }
}
