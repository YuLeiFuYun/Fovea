import Combine
import Foundation
import QuartzCore

#if canImport(Darwin)
    import Darwin
#endif

/// 在主线程采样帧间隔，并以独立任务低频读取物理内存占用。
/// 这些值用于回归比较而非精密能耗测量，快照必须绑定具体工作负载元数据。
@MainActor
final class WorkbenchPerformanceMonitor: NSObject, ObservableObject {
    @Published private(set) var isMeasuring = false
    @Published private(set) var frameSampleCount = 0
    @Published private(set) var hitchCount = 0
    @Published private(set) var maximumFrameIntervalMilliseconds = 0.0
    @Published private(set) var initialPhysicalFootprintBytes: UInt64?
    @Published private(set) var currentPhysicalFootprintBytes: UInt64?
    @Published private(set) var peakPhysicalFootprintBytes: UInt64?

    private var displayLink: CADisplayLink?
    private var memoryTask: Task<Void, Never>?
    private var lastTimestamp: CFTimeInterval?
    private var startedAt: Date?
    private var workload = Workload(
        id: "unbound",
        host: "unknown",
        layout: "unknown",
        itemCount: 0,
        uniqueAssetCount: 0
    )

    func begin(
        workloadID: String,
        host: WorkbenchFeedHost,
        layout: WorkbenchFeedLayout,
        itemCount: Int,
        uniqueAssetCount: Int
    ) {
        stopWithoutSnapshot()
        frameSampleCount = 0
        hitchCount = 0
        maximumFrameIntervalMilliseconds = 0
        lastTimestamp = nil
        workload = Workload(
            id: workloadID,
            host: host.rawValue,
            layout: layout.rawValue,
            itemCount: itemCount,
            uniqueAssetCount: uniqueAssetCount
        )
        startedAt = Date()

        let initial = Self.physicalFootprintBytes()
        initialPhysicalFootprintBytes = initial
        currentPhysicalFootprintBytes = initial
        peakPhysicalFootprintBytes = initial
        isMeasuring = true

        let link = CADisplayLink(target: self, selector: #selector(displayLinkTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link

        memoryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sampleMemory()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func finish() -> WorkbenchPerformanceSnapshot? {
        guard isMeasuring, let startedAt else { return nil }
        sampleMemory()
        let snapshot = WorkbenchPerformanceSnapshot(
            id: UUID(),
            workloadID: workload.id,
            host: workload.host,
            layout: workload.layout,
            itemCount: workload.itemCount,
            uniqueAssetCount: workload.uniqueAssetCount,
            startedAt: startedAt,
            finishedAt: Date(),
            frameSampleCount: frameSampleCount,
            hitchCount: hitchCount,
            maximumFrameIntervalMilliseconds: maximumFrameIntervalMilliseconds,
            initialPhysicalFootprintBytes: initialPhysicalFootprintBytes,
            peakPhysicalFootprintBytes: peakPhysicalFootprintBytes,
            finalPhysicalFootprintBytes: currentPhysicalFootprintBytes
        )
        stopWithoutSnapshot()
        return snapshot
    }

    func cancel() {
        stopWithoutSnapshot()
    }

    @objc
    private func displayLinkTick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard let lastTimestamp else { return }
        let interval = link.timestamp - lastTimestamp
        guard interval > 0 else { return }

        frameSampleCount += 1
        maximumFrameIntervalMilliseconds = max(
            maximumFrameIntervalMilliseconds,
            interval * 1_000
        )

        let scheduledInterval = link.targetTimestamp - link.timestamp
        let nominal =
            scheduledInterval > 0
            ? scheduledInterval
            : (link.duration > 0 ? link.duration : 1.0 / 60.0)
        if interval > nominal * 1.5 {
            hitchCount += 1
        }
    }

    private func sampleMemory() {
        guard isMeasuring else { return }
        let footprint = Self.physicalFootprintBytes()
        currentPhysicalFootprintBytes = footprint
        if let footprint {
            peakPhysicalFootprintBytes = max(peakPhysicalFootprintBytes ?? 0, footprint)
        }
    }

    private func stopWithoutSnapshot() {
        displayLink?.invalidate()
        displayLink = nil
        memoryTask?.cancel()
        memoryTask = nil
        lastTimestamp = nil
        isMeasuring = false
    }

    nonisolated private static func physicalFootprintBytes() -> UInt64? {
        #if canImport(Darwin)
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            return info.phys_footprint
        #else
            return nil
        #endif
    }

    private struct Workload {
        let id: String
        let host: String
        let layout: String
        let itemCount: Int
        let uniqueAssetCount: Int
    }
}
