import Dispatch
import FoveaCore

/// 将系统内存压力转换为 RenderedMemory 清理，不改变磁盘缓存或在途任务语义。
package actor FoveaMemoryPressureMonitor {
    private weak let pipeline: FoveaPipeline?
    private let source: DispatchSourceMemoryPressure

    package init(pipeline: FoveaPipeline) {
        self.pipeline = pipeline
        let queue = DispatchQueue(
            label: "dev.fovea.system.memory-pressure",
            qos: .utility
        )
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: queue
        )
        self.source = source
        source.setEventHandler { [weak pipeline] in
            guard let pipeline else { return }
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
        guard let pipeline else { return 0 }
        return await pipeline.purgeMemoryCache()
    }
}
