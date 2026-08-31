import AkashicMemory
import Foundation
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

/// 默认 rendered cache 的 package-only pressure refinement。
///
/// public `RenderedImageCaching` 故意不暴露 probation/main 语义；第三方 cache 不需要理解
/// Fovea 的分层 admission 策略。系统 warning 只在实现显式支持该 refinement 时回收低价值层，否则
/// 保持既有 full-purge 行为，避免静默减弱宿主的 pressure response。
package protocol TieredRenderedImageReclaiming: Sendable {
    func reclaimLowValueAndReport() -> RenderedImageCacheRemovalSummary
}

/// 官方 scan-resistant 分层内存实现。它不是协议语义的一部分，可由调用方整体替换。
///
/// 普通首次命中进入有界 probation window；放不进该窗口的大图只进入一个单槽
/// large-probation，连续一次性 hero 扫描因此只保留最新低置信度身份。两类 probation 都只有
/// 发生真实读取后才晋升 main SIEVE。普通 probation 使用全局连续槽并同时约束字节/entry 数；
/// main 使用最多八分片 SIEVE；分片数按 main/probation 预算自适应，使每个 shard 至少
/// 能容纳完整 probation window，避免 warm set 晋升仅因随机 hash 分布发生容量驱逐，同时在
/// 预算足够时保留八路热命中并发。large-probation 驻留时先清 ordinary probation；只有
/// proven-main 的实际驻留已超过 `total - large` 时才做必要 trim，否则保持
/// main 配置不动，并由跨 tier coordination lock 阻止其在 large owner 存活期间无约束增长。
/// large identity 真正晋升后，main 才能临时借用空闲 probation 预算；任意时刻三层实际驻留
/// 成本都不得超过调用方配置的全局上限。
package final class DefaultRenderedImageCache: @unchecked Sendable, RenderedImageCaching,
    TieredRenderedImageReclaiming
{
    private struct Resident: Sendable {
        let image: DecodedImage
        let cost: Int
    }

    private static let defaultProbationCostLimit = 16 * 1024 * 1024
    private static let defaultProbationCountLimit = 16
    // Cardinality mirrors the byte-side complete-probation-window invariant: every identity
    // admitted by one maximum-cardinality ordinary probation window can promote without a
    // count-driven loss, while proven main does not reserve extra identity slots by default.
    private static let defaultMainCountLimit = defaultProbationCountLimit

    private let coordinationLock = NSLock()
    private let probation: FoveaCompactSieveCache<RenderedImageCacheKey, Resident>
    private let largeProbation: FoveaCompactSieveCache<RenderedImageCacheKey, Resident>
    private let main: ShardedMemoryCache<RenderedImageCacheKey, Resident>?
    // Identity-only SIEVE governor mirrors proven-main reuse without duplicating image values.
    // A main hit marks the identity visited here as well, so count pressure cannot override the
    // reuse signal already observed by the byte-bounded main SIEVE.
    private let mainCountGovernor: FoveaCompactSieveCache<RenderedImageCacheKey, Bool>?
    private let totalCostLimit: Int
    private let probationCostLimit: Int
    private let mainBaseCostLimit: Int
    /// The proven main identity whose promotion/replacement currently justifies borrowing the
    /// otherwise-unused probation budget. Keeping the key lets remove/revoke end the loan exactly
    /// when its causal resident disappears instead of leaving main expanded behind a stale bool.
    private var expandedMainBudgetOwnerKey: RenderedImageCacheKey?

    package init(costLimit: Int, probationCostLimit requestedProbationCostLimit: Int? = nil) {
        let normalizedTotal = max(1, costLimit)
        totalCostLimit = normalizedTotal

        let selectedProbation: Int
        if let requestedProbationCostLimit {
            if normalizedTotal == 1 {
                selectedProbation = 1
            } else {
                selectedProbation = min(
                    max(1, requestedProbationCostLimit),
                    max(1, normalizedTotal / 2)
                )
            }
        } else if normalizedTotal <= Self.defaultProbationCostLimit {
            selectedProbation = normalizedTotal
        } else {
            selectedProbation = min(
                Self.defaultProbationCostLimit,
                max(1, normalizedTotal / 2)
            )
        }

        probationCostLimit = selectedProbation
        probation = FoveaCompactSieveCache(
            costLimit: selectedProbation,
            countLimit: Self.defaultProbationCountLimit
        )
        // Residents too large for the ordinary probation window still need a first-use stage.
        // Keep exactly one such identity so repeated large one-off images replace each other
        // instead of masquerading as proven main-cache reuse.
        largeProbation = FoveaCompactSieveCache(
            costLimit: normalizedTotal,
            countLimit: 1
        )
        let remaining = normalizedTotal - selectedProbation
        mainBaseCostLimit = max(0, remaining)
        if remaining > 0 {
            let mainShardCount = max(
                1,
                min(8, remaining / selectedProbation)
            )
            main = ShardedMemoryCache(costLimit: remaining, shardCount: mainShardCount)
            mainCountGovernor = FoveaCompactSieveCache(
                costLimit: Self.defaultMainCountLimit,
                countLimit: Self.defaultMainCountLimit
            )
        } else {
            main = nil
            mainCountGovernor = nil
        }
    }

    package func image(for key: RenderedImageCacheKey) -> DecodedImage? {
        if let resident = main?.value(for: key) {
            _ = mainCountGovernor?.value(for: key)
            return resident.image
        }
        if let probationResident = probation.value(for: key) {
            return promoteProbationResidentIfNeeded(probationResident, for: key)
        }
        return promoteLargeProbationResidentIfNeeded(for: key)
    }

    package func insert(
        _ image: DecodedImage,
        for key: RenderedImageCacheKey,
        cost: Int
    ) {
        let normalizedCost = max(1, cost)
        let resident = Resident(image: image, cost: normalizedCost)

        coordinationLock.lock()
        defer { coordinationLock.unlock() }

        guard normalizedCost <= totalCostLimit else {
            removeOversizedResidentLocked(key)
            return
        }
        guard let main else {
            probation.insert(resident, for: key, cost: normalizedCost)
            return
        }
        if replaceMainResidentIfPresentLocked(resident, for: key, main: main) {
            return
        }
        if probation.value(for: key) != nil {
            probation.remove(key)
            placeNewResidentLocked(resident, for: key, main: main)
            return
        }

        placeNewResidentLocked(resident, for: key, main: main)
    }

    package func remove(_ key: RenderedImageCacheKey) {
        coordinationLock.lock()
        probation.remove(key)
        mainCountGovernor?.remove(key)
        if let main {
            let removedExpandedOwner = expandedMainBudgetOwnerKey == key
            removeLargeProbationLocked(key, main: main)
            main.remove(key)
            if removedExpandedOwner {
                _ = restoreMainBaseBudgetIfNeededLocked(main)
            }
        } else {
            largeProbation.remove(key)
        }
        coordinationLock.unlock()
    }

    package func removeAll(where predicate: @Sendable (RenderedImageCacheKey) -> Bool) {
        coordinationLock.lock()
        probation.removeAll(where: predicate)
        mainCountGovernor?.removeAll(where: predicate)
        let removedLarge = largeProbation.removeAllAndReport(where: predicate)
        if let main {
            let removedExpandedOwner = expandedMainBudgetOwnerKey.map(predicate) ?? false
            main.removeAll(where: predicate)
            if removedLarge.itemCount > 0 || removedExpandedOwner {
                _ = restoreMainBaseBudgetIfNeededLocked(main)
            }
        }
        coordinationLock.unlock()
    }

    package func removeAllAndReport() -> RenderedImageCacheRemovalSummary {
        coordinationLock.lock()
        let probationSummary = probation.removeAllAndReport()
        let largeProbationSummary = largeProbation.removeAllAndReport()
        _ = mainCountGovernor?.removeAllAndReport()
        let mainSummary = main?.removeAllAndReport()
        if let main {
            _ = restoreMainBaseBudgetIfNeededLocked(main)
        }
        coordinationLock.unlock()
        return RenderedImageCacheRemovalSummary(
            itemCount: probationSummary.itemCount
                + largeProbationSummary.itemCount
                + (mainSummary?.itemCount ?? 0),
            costBytes: probationSummary.costBytes
                + largeProbationSummary.costBytes
                + (mainSummary?.costBytes ?? 0)
        )
    }

    /// Memory-warning fast reclaim: discard both ordinary and large first-hit probation residents
    /// while preserving identities that proved a real second use. Proven main may temporarily
    /// borrow otherwise-unused probation budget; warning pressure ends that loan as well.
    package func reclaimLowValueAndReport() -> RenderedImageCacheRemovalSummary {
        coordinationLock.lock()
        let probationSummary = probation.removeAllAndReport()
        let largeProbationSummary = largeProbation.removeAllAndReport()
        var removedItemCount = probationSummary.itemCount + largeProbationSummary.itemCount
        var removedCostBytes = probationSummary.costBytes + largeProbationSummary.costBytes
        if let main {
            let restored = restoreMainBaseBudgetIfNeededLocked(main)
            removedItemCount += restored.itemCount
            removedCostBytes += restored.costBytes
        }
        coordinationLock.unlock()
        return RenderedImageCacheRemovalSummary(
            itemCount: removedItemCount,
            costBytes: removedCostBytes
        )
    }

    package var currentCost: Int {
        coordinationLock.lock()
        let result = probation.currentCost + largeProbation.currentCost + (main?.currentCost ?? 0)
        coordinationLock.unlock()
        return result
    }

    package var count: Int {
        coordinationLock.lock()
        let result = probation.count + largeProbation.count + (main?.count ?? 0)
        coordinationLock.unlock()
        return result
    }

    private func promoteProbationResidentIfNeeded(
        _ probationResident: Resident,
        for key: RenderedImageCacheKey
    ) -> DecodedImage? {
        guard let main else { return probationResident.image }

        // Misses never need the cross-segment lock. A probation hit takes it only to linearize
        // promotion against remove/insert. If the entry is removed while waiting, returning the
        // already-observed resident remains linearizable before that removal, but it is not
        // resurrected into main.
        coordinationLock.lock()
        defer { coordinationLock.unlock() }
        if let resident = main.value(for: key) {
            _ = mainCountGovernor?.value(for: key)
            return resident.image
        }
        guard let resident = probation.value(for: key) else {
            return probationResident.image
        }

        restoreMainBaseBudgetIfNeededLocked(main)
        // Every ordinary probation resident is bounded by probationCostLimit, which is never
        // larger than mainBaseCostLimit when a main segment exists. A separate identity-only
        // SIEVE governor bounds proven-main cardinality without shrinking the byte window needed
        // by W2's small set of larger residents.
        admitOrdinaryMainResidentLocked(resident, for: key, main: main)
        probation.remove(key)
        return resident.image
    }

    private func promoteLargeProbationResidentIfNeeded(
        for key: RenderedImageCacheKey
    ) -> DecodedImage? {
        guard let largeProbationResident = largeProbation.value(for: key), let main else {
            return nil
        }
        coordinationLock.lock()
        defer { coordinationLock.unlock() }
        if let resident = main.value(for: key) {
            return resident.image
        }
        guard let resident = largeProbation.value(for: key) else {
            return largeProbationResident.image
        }

        // A real lookup is the second-use evidence that admits a large first-hit resident to main.
        // Remove the low-confidence owner first, then let proven main borrow the otherwise-unused
        // probation budget until the next ordinary first-hit insertion restores the normal split.
        mainCountGovernor?.remove(key)
        largeProbation.remove(key)
        placeResidentUsingBorrowedProbationBudgetLocked(resident, for: key, main: main)
        return resident.image
    }

    private func removeOversizedResidentLocked(_ key: RenderedImageCacheKey) {
        probation.remove(key)
        mainCountGovernor?.remove(key)
        if let main {
            removeLargeProbationLocked(key, main: main)
            main.remove(key)
        } else {
            largeProbation.remove(key)
        }
    }

    private func replaceMainResidentIfPresentLocked(
        _ resident: Resident,
        for key: RenderedImageCacheKey,
        main: ShardedMemoryCache<RenderedImageCacheKey, Resident>
    ) -> Bool {
        guard main.value(for: key) != nil else { return false }
        _ = mainCountGovernor?.value(for: key)

        // Once an identity has earned main residency, replacement keeps that evidence rather
        // than demoting it merely because a new DecodedImage instance was produced.
        probation.remove(key)
        discardLargeProbationLocked(main)
        if resident.cost <= mainBaseCostLimit {
            restoreMainBaseBudgetIfNeededLocked(main)
            main.insert(resident, for: key, cost: resident.cost)
        } else {
            mainCountGovernor?.remove(key)
            placeResidentUsingBorrowedProbationBudgetLocked(
                resident,
                for: key,
                main: main
            )
        }
        return true
    }

    private func admitOrdinaryMainResidentLocked(
        _ resident: Resident,
        for key: RenderedImageCacheKey,
        main: ShardedMemoryCache<RenderedImageCacheKey, Resident>
    ) {
        if let governor = mainCountGovernor {
            let victims = governor.insertReportingEvictions(true, for: key, cost: 1)
            for victim in victims where victim != key {
                main.remove(victim)
            }
        }
        main.insert(resident, for: key, cost: resident.cost)
    }

    @discardableResult
    private func restoreMainBaseBudgetIfNeededLocked(
        _ main: ShardedMemoryCache<RenderedImageCacheKey, Resident>
    ) -> MemoryCacheRemovalSummary {
        guard expandedMainBudgetOwnerKey != nil || main.costLimit != mainBaseCostLimit else {
            return MemoryCacheRemovalSummary(itemCount: 0, costBytes: 0)
        }
        let summary = main.updateCostLimit(mainBaseCostLimit)
        expandedMainBudgetOwnerKey = nil
        return summary
    }

    private func placeNewResidentLocked(
        _ resident: Resident,
        for key: RenderedImageCacheKey,
        main: ShardedMemoryCache<RenderedImageCacheKey, Resident>
    ) {
        if resident.cost <= probationCostLimit {
            discardLargeProbationLocked(main)
            restoreMainBaseBudgetIfNeededLocked(main)
            main.remove(key)
            probation.insert(resident, for: key, cost: resident.cost)
            return
        }
        placeLargeProbationResidentLocked(resident, for: key, main: main)
    }

    private func placeLargeProbationResidentLocked(
        _ resident: Resident,
        for key: RenderedImageCacheKey,
        main: ShardedMemoryCache<RenderedImageCacheKey, Resident>
    ) {
        precondition(resident.cost > probationCostLimit && resident.cost <= totalCostLimit)
        _ = probation.removeAllAndReport()
        _ = largeProbation.removeAllAndReport()
        if expandedMainBudgetOwnerKey != nil {
            _ = restoreMainBaseBudgetIfNeededLocked(main)
        }

        // The large first-hit resident remains a probation owner. Reserve exactly enough of the
        // global budget for it, shrinking proven main only when total capacity actually requires
        // that tradeoff. A later large first hit replaces this one-slot low-confidence owner.
        let availableForMain = totalCostLimit - resident.cost
        let currentMainCost = main.currentCost
        if currentMainCost > availableForMain {
            if availableForMain == 0 {
                _ = main.removeAllAndReport()
            } else {
                _ = main.updateCostLimit(availableForMain)
            }
        }
        largeProbation.insert(resident, for: key, cost: resident.cost)
        precondition(
            probation.currentCost + largeProbation.currentCost + main.currentCost <= totalCostLimit)
    }

    private func placeResidentUsingBorrowedProbationBudgetLocked(
        _ resident: Resident,
        for key: RenderedImageCacheKey,
        main: ShardedMemoryCache<RenderedImageCacheKey, Resident>
    ) {
        _ = probation.removeAllAndReport()
        discardLargeProbationLocked(main)
        if main.costLimit != totalCostLimit {
            _ = main.updateCostLimit(totalCostLimit)
        }
        main.insert(resident, for: key, cost: resident.cost)
        expandedMainBudgetOwnerKey = key
    }

    private func discardLargeProbationLocked(
        _ main: ShardedMemoryCache<RenderedImageCacheKey, Resident>
    ) {
        let summary = largeProbation.removeAllAndReport()
        guard summary.itemCount > 0 else { return }
        _ = restoreMainBaseBudgetIfNeededLocked(main)
    }

    private func removeLargeProbationLocked(
        _ key: RenderedImageCacheKey,
        main: ShardedMemoryCache<RenderedImageCacheKey, Resident>
    ) {
        guard largeProbation.contains(key) else { return }
        largeProbation.remove(key)
        _ = restoreMainBaseBudgetIfNeededLocked(main)
    }
}
