import Dispatch
import FoveaCore

/// 将系统内存压力转换为 RenderedMemory 清理，不改变磁盘缓存或在途任务语义。
package actor FoveaMemoryPressureMonitor {
  private let pipeline: FoveaPipeline
  private let source: DispatchSourceMemoryPressure

  package init(pipeline: FoveaPipeline) {
    self.pipeline = pipeline
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical],
      queue: DispatchQueue.global(qos: .utility)
    )
    self.source = source
    source.setEventHandler { [pipeline] in
      Task { @concurrent in
        _ = await pipeline.purgeMemoryCache()
      }
    }
    source.resume()
  }

  deinit {
    source.cancel()
  }

  package func simulatePressureForTesting() async -> Int {
    await pipeline.purgeMemoryCache()
  }
}
