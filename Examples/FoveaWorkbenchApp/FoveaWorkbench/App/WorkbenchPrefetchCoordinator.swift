import Dispatch
import Foundation
import FoveaCore
import ImageCraftCore

/// 管理 Workbench 的有界预取任务与已完成身份。
/// 它只负责“提前加载”，不拥有管线、配置或用户可见错误状态。
@MainActor
final class WorkbenchPrefetchCoordinator {
    private struct PrefetchKey: Hashable {
        let assetID: String
        let targetWidth: Int
        let targetHeight: Int
        let contentMode: WorkbenchContentMode
    }

    private struct TaskEntry {
        let identifier: UUID
        let task: Task<Void, Never>
    }

    private var tasks: [PrefetchKey: TaskEntry] = [:]
    private var completedKeys: Set<PrefetchKey> = []
    private var planner = WorkbenchPrefetchPlanner()

    var completedCount: Int { completedKeys.count }
    var pendingCount: Int { tasks.count }

    func prefetch(
        assets: [WorkbenchRemoteAsset],
        pipeline: FoveaPipeline,
        configuration: WorkbenchConfiguration,
        targetWidth: Int,
        targetHeight: Int,
        estimatedConsumptionRate: Double,
        minimumCount: Int,
        maximumCount: Int,
        stateDidChange: @escaping @MainActor (Int, Int) -> Void
    ) {
        prefetch(
            assets: assets,
            configuration: configuration,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            estimatedConsumptionRate: estimatedConsumptionRate,
            minimumCount: minimumCount,
            maximumCount: maximumCount,
            stateDidChange: stateDidChange
        ) { asset, target, configuration in
            do {
                let request = try WorkbenchRequestFactory.makeRemoteAssetRequest(
                    asset: asset,
                    target: target,
                    configuration: configuration
                )
                _ = try await pipeline.image(for: request)
                return !Task.isCancelled
            } catch {
                return false
            }
        }
    }

    /// 测试与生产共用的调度状态机。任务完成时同时校验 key 与任务版本，
    /// 防止 reset 后的旧 completion 删除同 key 的新任务句柄。
    func prefetch(
        assets: [WorkbenchRemoteAsset],
        configuration: WorkbenchConfiguration,
        targetWidth: Int,
        targetHeight: Int,
        estimatedConsumptionRate: Double,
        minimumCount: Int,
        maximumCount: Int,
        stateDidChange: @escaping @MainActor (Int, Int) -> Void,
        load:
            @escaping @MainActor (
                WorkbenchRemoteAsset,
                TargetPixels,
                WorkbenchConfiguration
            ) async -> Bool
    ) {
        guard configuration.externalNetworkingEnabled,
            let target = try? TargetPixels(width: targetWidth, height: targetHeight)
        else { return }

        let recommendation = planner.recommendedItemCount(
            estimatedConsumptionRate: estimatedConsumptionRate,
            minimum: minimumCount,
            maximum: maximumCount
        )
        stateDidChange(completedKeys.count, recommendation)
        let candidates = assets.lazy.compactMap { asset -> (WorkbenchRemoteAsset, PrefetchKey)? in
            guard asset.sourceKind == .remote else { return nil }
            let key = PrefetchKey(
                assetID: asset.id,
                targetWidth: target.width,
                targetHeight: target.height,
                contentMode: configuration.contentMode
            )
            guard !self.completedKeys.contains(key), self.tasks[key] == nil else { return nil }
            return (asset, key)
        }

        for (asset, key) in candidates.prefix(recommendation) {
            let taskIdentifier = UUID()
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let task = Task { [weak self] in
                let succeeded = await load(asset, target, configuration) && !Task.isCancelled
                guard let self, tasks[key]?.identifier == taskIdentifier else { return }
                tasks.removeValue(forKey: key)
                if succeeded, completedKeys.insert(key).inserted {
                    planner.record(
                        durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- startedAt
                    )
                }
                let nextRecommendation = planner.recommendedItemCount(
                    estimatedConsumptionRate: estimatedConsumptionRate,
                    minimum: minimumCount,
                    maximum: maximumCount
                )
                stateDidChange(completedKeys.count, nextRecommendation)
            }
            tasks[key] = TaskEntry(identifier: taskIdentifier, task: task)
        }
    }

    /// 取消尚未完成的预取，但保留已完成身份，避免页面切换后重复预取。
    func cancelPending() {
        for entry in tasks.values { entry.task.cancel() }
        tasks.removeAll()
    }

    /// 管线或内存代际改变时清空全部预取状态。
    func reset(stateDidChange: @escaping @MainActor (Int, Int) -> Void) {
        cancelPending()
        completedKeys.removeAll()
        planner.reset()
        stateDidChange(0, 0)
    }
}
