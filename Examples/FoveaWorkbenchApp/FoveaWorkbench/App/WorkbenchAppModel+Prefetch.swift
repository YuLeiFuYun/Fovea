import Foundation

extension WorkbenchAppModel {
    func prefetchRemoteAssets(
        _ assets: [WorkbenchRemoteAsset],
        targetWidth: Int = 640,
        targetHeight: Int = 480,
        estimatedConsumptionRate: Double = 8,
        minimumCount: Int = 8,
        maximumCount: Int = 64
    ) {
        guard let pipeline else { return }
        prefetchCoordinator.prefetch(
            assets: assets,
            pipeline: pipeline,
            configuration: activeConfiguration,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            estimatedConsumptionRate: estimatedConsumptionRate,
            minimumCount: minimumCount,
            maximumCount: maximumCount
        ) { [weak self] completed, recommended in
            self?.publishPrefetchState(completed: completed, recommended: recommended)
        }
    }

    func cancelPrefetches() {
        prefetchCoordinator.cancelPending()
    }

    func resetPrefetchState() {
        prefetchCoordinator.reset { [weak self] completed, recommended in
            self?.publishPrefetchState(completed: completed, recommended: recommended)
        }
    }
}
