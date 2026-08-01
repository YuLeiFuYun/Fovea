import AkashicMemory
import ImageCraftCore

/// 已解码、已变换图片在安全命名空间和撤销代际中的完整缓存身份。
///
/// 自定义缓存必须把全部字段视为键的一部分；忽略 namespace、generation、codec
/// fingerprint 或 transformer fingerprint 会造成跨账户或跨实现像素复用。
public struct RenderedImageCacheKey: Hashable, Sendable {
    /// 授权主体隔离边界。
    public let namespace: SecurityNamespaceID
    /// namespace 撤销后的持久代际栅栏。
    public let generation: NamespaceGeneration
    /// 内容、目标、颜色、transformer 与 codec 的完整渲染身份。
    public let renderKey: RenderKey

    /// 创建一个不得降维比较的完整渲染缓存键。
    public init(
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration,
        renderKey: RenderKey
    ) {
        self.namespace = namespace
        self.generation = generation
        self.renderKey = renderKey
    }
}

/// 一次缓存清理确认释放的条目与归一化成本。
public struct RenderedImageCacheRemovalSummary: Hashable, Sendable {
    /// 已移除条目数。
    public let itemCount: Int
    /// 已移除条目的归一化成本总和。
    public let costBytes: Int

    /// 创建清理摘要；负值按零处理。
    public init(itemCount: Int, costBytes: Int) {
        self.itemCount = max(0, itemCount)
        self.costBytes = max(0, costBytes)
    }
}

/// Fovea 渲染像素缓存的同步热路径契约。
///
/// 实现必须提供线程安全、线性化的读取、写入和清理语义。该接口故意保持同步：
/// 内存命中位于滚动显示热路径，不能强制 actor hop。基于 actor 的第三方缓存可在
/// 外层维护一个锁保护的内存前端，并把持久或异步工作放到其后端。
public protocol RenderedImageCaching: Sendable {
    /// 同步读取一个完整身份匹配的派生图像。
    func image(for key: RenderedImageCacheKey) -> DecodedImage?
    /// 以调用方提供的归一化字节成本插入或替换图像。
    func insert(_ image: DecodedImage, for key: RenderedImageCacheKey, cost: Int)
    /// 删除单个完整身份。
    func remove(_ key: RenderedImageCacheKey)
    /// 原子删除所有满足谓词的条目。
    func removeAll(where predicate: @Sendable (RenderedImageCacheKey) -> Bool)
    /// 删除全部条目并返回删除前的条目数和成本。
    func removeAllAndReport() -> RenderedImageCacheRemovalSummary
    /// 当前归一化总成本。
    var currentCost: Int { get }
    /// 当前条目数。
    var count: Int { get }
}

/// 官方 SIEVE 内存实现。它不是协议语义的一部分，可由调用方整体替换。
package final class DefaultRenderedImageCache: RenderedImageCaching {
    private let storage: MemoryCache<RenderedImageCacheKey, DecodedImage>

    package init(costLimit: Int) {
        storage = MemoryCache(costLimit: costLimit)
    }

    package func image(for key: RenderedImageCacheKey) -> DecodedImage? {
        storage.value(for: key)
    }

    package func insert(
        _ image: DecodedImage,
        for key: RenderedImageCacheKey,
        cost: Int
    ) {
        storage.insert(image, for: key, cost: cost)
    }

    package func remove(_ key: RenderedImageCacheKey) {
        storage.remove(key)
    }

    package func removeAll(where predicate: @Sendable (RenderedImageCacheKey) -> Bool) {
        storage.removeAll(where: predicate)
    }

    package func removeAllAndReport() -> RenderedImageCacheRemovalSummary {
        let summary = storage.removeAllAndReport()
        return RenderedImageCacheRemovalSummary(
            itemCount: summary.itemCount,
            costBytes: summary.costBytes
        )
    }

    package var currentCost: Int { storage.currentCost }
    package var count: Int { storage.count }
}
