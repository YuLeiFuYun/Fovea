import Dispatch
import Foundation
import FoveaCore

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

package struct FoveaSystemPressureReport: Equatable, Sendable {
    package let renderedRemovalCount: Int
    package let animation: AnimationPlaybackRuntimeReport
}

/// Serializes externally ordered system events across asynchronous side effects.
package final class FoveaSystemOrderedEventExecutor<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var isClosed = false

    package init() {}

    package func submit(
        _ event: Event,
        operation: @escaping @Sendable (Event) async -> Void
    ) {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        let previous = tail
        let next = Task { [previous] in
            if let previous { await previous.value }
            guard !Task.isCancelled else { return }
            await operation(event)
        }
        tail = next
        lock.unlock()
    }

    package func cancelPending() {
        lock.lock()
        isClosed = true
        let pending = tail
        tail = nil
        lock.unlock()
        pending?.cancel()
    }

    package func waitUntilDrainedForTesting() async {
        let pending = currentTail()
        await pending?.value
    }

    private func currentTail() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return tail
    }
}

/// 将系统内存压力广播到静态渲染缓存和动画播放 runtime。
///
/// 三个独立 pressure source 避免 event handler 捕获 source 自身形成 retain cycle。应用 active
/// 通知由独立 lifecycle monitor 持有，因此禁用自动 pressure 时不会增加 pipeline anchor。
package actor FoveaMemoryPressureMonitor {
    private weak var pipeline: FoveaPipeline?
    private let animationRuntime: AnimationPlaybackRuntime
    private let automaticallyPurgesMemoryOnPressure: Bool
    private let pressureEventExecutor: FoveaSystemOrderedEventExecutor<AnimationMemoryPressureLevel>
    private let pressureSources: [DispatchSourceMemoryPressure]

    package init(
        pipeline: FoveaPipeline,
        animationRuntime: AnimationPlaybackRuntime,
        automaticallyPurgesMemoryOnPressure: Bool
    ) {
        self.pipeline = pipeline
        self.animationRuntime = animationRuntime
        self.automaticallyPurgesMemoryOnPressure = automaticallyPurgesMemoryOnPressure
        let pressureEventExecutor =
            FoveaSystemOrderedEventExecutor<AnimationMemoryPressureLevel>()
        self.pressureEventExecutor = pressureEventExecutor

        if automaticallyPurgesMemoryOnPressure {
            self.pressureSources = Self.makePressureSources(
                pipeline: pipeline,
                animationRuntime: animationRuntime,
                eventExecutor: pressureEventExecutor
            )
        } else {
            self.pressureSources = []
        }
    }

    /// 保留既有测试与包内调用的单参数构造；动画预算最小且没有 handle 时不分配像素。
    package init(pipeline: FoveaPipeline) {
        self.init(
            pipeline: pipeline,
            animationRuntime: AnimationPlaybackRuntime(
                frameMemoryCostLimit: 1,
                maximumDriverCount: 1
            ),
            automaticallyPurgesMemoryOnPressure: true
        )
    }

    deinit {
        for source in pressureSources { source.cancel() }
        pressureEventExecutor.cancelPending()
    }

    package func simulatePressureForTesting() async -> Int {
        guard automaticallyPurgesMemoryOnPressure else { return 0 }
        return await applyPressure(.critical).renderedRemovalCount
    }

    package func simulatePressureForTesting(
        _ level: AnimationMemoryPressureLevel
    ) async -> FoveaSystemPressureReport {
        await applyPressure(level)
    }

    package func simulateApplicationActiveForTesting(_ active: Bool) async {
        _ = await animationRuntime.setApplicationActive(active)
    }

    private func applyPressure(
        _ level: AnimationMemoryPressureLevel
    ) async -> FoveaSystemPressureReport {
        let renderedRemovalCount: Int
        switch level {
        case .normal:
            renderedRemovalCount = 0
        case .warning:
            renderedRemovalCount = await pipeline?.reclaimMemoryCacheForWarning() ?? 0
        case .critical:
            renderedRemovalCount = await pipeline?.purgeMemoryCache() ?? 0
        }
        let animation = await animationRuntime.applyMemoryPressure(level)
        return FoveaSystemPressureReport(
            renderedRemovalCount: renderedRemovalCount,
            animation: animation
        )
    }

    private nonisolated static func makePressureSources(
        pipeline: FoveaPipeline,
        animationRuntime: AnimationPlaybackRuntime,
        eventExecutor: FoveaSystemOrderedEventExecutor<AnimationMemoryPressureLevel>
    ) -> [DispatchSourceMemoryPressure] {
        let queue = DispatchQueue(
            label: "dev.fovea.system.memory-pressure",
            qos: .utility
        )
        return [
            makePressureSource(
                event: .normal,
                level: .normal,
                queue: queue,
                pipeline: pipeline,
                animationRuntime: animationRuntime,
                eventExecutor: eventExecutor
            ),
            makePressureSource(
                event: .warning,
                level: .warning,
                queue: queue,
                pipeline: pipeline,
                animationRuntime: animationRuntime,
                eventExecutor: eventExecutor
            ),
            makePressureSource(
                event: .critical,
                level: .critical,
                queue: queue,
                pipeline: pipeline,
                animationRuntime: animationRuntime,
                eventExecutor: eventExecutor
            ),
        ]
    }

    private nonisolated static func makePressureSource(
        event: DispatchSource.MemoryPressureEvent,
        level: AnimationMemoryPressureLevel,
        queue: DispatchQueue,
        pipeline: FoveaPipeline,
        animationRuntime: AnimationPlaybackRuntime,
        eventExecutor: FoveaSystemOrderedEventExecutor<AnimationMemoryPressureLevel>
    ) -> DispatchSourceMemoryPressure {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: event,
            queue: queue
        )
        source.setEventHandler { [weak pipeline, weak animationRuntime] in
            eventExecutor.submit(level) { [weak pipeline, weak animationRuntime] level in
                switch level {
                case .normal:
                    break
                case .warning:
                    _ = await pipeline?.reclaimMemoryCacheForWarning()
                case .critical:
                    _ = await pipeline?.purgeMemoryCache()
                }
                _ = await animationRuntime?.applyMemoryPressure(level)
            }
        }
        source.resume()
        return source
    }

}

/// NotificationCenter 持有未声明 Sendable 的 Objective-C 不透明 token。
/// token 数组在同步注册后保持不可变，回调只弱捕获 Sendable runtime，且 deinit 是唯一消费者，
/// 因而不存在跨任务修改。
package final class FoveaLifecycleNotificationMonitor: @unchecked Sendable {
    private let tokens: [NSObjectProtocol]
    private let eventExecutor: FoveaSystemOrderedEventExecutor<Bool>

    package init(animationRuntime: AnimationPlaybackRuntime) {
        let eventExecutor = FoveaSystemOrderedEventExecutor<Bool>()
        self.eventExecutor = eventExecutor
        #if canImport(UIKit)
            tokens = [
                Self.observe(UIApplication.didEnterBackgroundNotification, active: false, animationRuntime: animationRuntime, eventExecutor: eventExecutor),
                Self.observe(UIApplication.didBecomeActiveNotification, active: true, animationRuntime: animationRuntime, eventExecutor: eventExecutor),
            ]
        #elseif canImport(AppKit)
            tokens = [
                Self.observe(NSApplication.didResignActiveNotification, active: false, animationRuntime: animationRuntime, eventExecutor: eventExecutor),
                Self.observe(NSApplication.didBecomeActiveNotification, active: true, animationRuntime: animationRuntime, eventExecutor: eventExecutor),
            ]
        #else
            tokens = []
        #endif
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        eventExecutor.cancelPending()
    }

    private static func observe(
        _ name: Notification.Name,
        active: Bool,
        animationRuntime: AnimationPlaybackRuntime,
        eventExecutor: FoveaSystemOrderedEventExecutor<Bool>
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak animationRuntime] _ in
            eventExecutor.submit(active) { [weak animationRuntime] active in
                _ = await animationRuntime?.setApplicationActive(active)
            }
        }
    }
}
