import UIKit

/// 随包真实图片的异步数据读取与主线程发布仓库。
/// 文件 I/O 由缓存持有的 `@concurrent` utility task 执行；预热只登记可取消任务，
/// 不创建脱离缓存生命周期的游离工作，也不在 SwiftUI `body` 中读取文件。
@MainActor
final class WorkbenchBundledImageCache {
    static let shared = WorkbenchBundledImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<Data?, Never>] = [:]

    private init() {
        cache.countLimit = 32
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    func image(for asset: WorkbenchRemoteAsset) async -> UIImage? {
        let key = asset.id as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let task = dataTask(for: asset) else { return nil }

        let data = await task.value
        inFlight.removeValue(forKey: asset.id)
        guard !Task.isCancelled, let data, let image = UIImage(data: data) else { return nil }

        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? max(1, data.count)
        cache.setObject(image, forKey: key, cost: max(1, cost))
        return image
    }

    func prewarm(_ assets: [WorkbenchRemoteAsset]) {
        for asset in assets where asset.sourceKind == .bundled {
            _ = dataTask(for: asset)
        }
    }

    func removeAll() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        cache.removeAllObjects()
    }

    private func dataTask(for asset: WorkbenchRemoteAsset) -> Task<Data?, Never>? {
        if let existing = inFlight[asset.id] { return existing }
        guard let url = asset.bundledURL else { return nil }

        let task = Task<Data?, Never>(priority: .utility) { @concurrent in
            guard !Task.isCancelled else { return nil }
            return try? Data(contentsOf: url, options: [.mappedIfSafe])
        }
        inFlight[asset.id] = task
        return task
    }
}
