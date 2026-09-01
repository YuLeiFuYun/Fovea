import AkashicMemory
import Foundation

package enum AnimationPlaybackRuntimeError: Error, Equatable, Sendable {
    case capacityExceeded
    case invalidRegistration
    case invalidAuthorizedAsset
    case generationRevoked
}

package struct AnimationPlaybackRuntimeReport: Equatable, Sendable {
    package let registeredDriverCount: Int
    package let registeredLiveSessionCount: Int
    package let affectedDriverCount: Int
    package let affectedLiveSessionCount: Int
    package let failedDriverCount: Int
    package let failedLiveSessionCount: Int
    package let removedFrames: MemoryCacheRemovalSummary
}

/// 一个动画 handle 的稳定注册身份与独立播放 driver。
package struct AnimationPlaybackHandle: Sendable {
    package let identifier: UUID
    package let driver: AnimationPlaybackDriver
    package let presentationCadenceRecommendation: AnimationPresentationCadenceRecommendation?
    private let runtime: AnimationPlaybackRuntime

    fileprivate init(
        identifier: UUID,
        driver: AnimationPlaybackDriver,
        presentationCadenceRecommendation: AnimationPresentationCadenceRecommendation?,
        runtime: AnimationPlaybackRuntime
    ) {
        self.identifier = identifier
        self.driver = driver
        self.presentationCadenceRecommendation = presentationCadenceRecommendation
        self.runtime = runtime
    }

    package func start(
        output: @escaping AnimationPlaybackDriver.OutputHandler,
        failure: @escaping AnimationPlaybackDriver.FailureHandler = { _ in },
        initiallyVisible: Bool = true,
        schedulingMode: AnimationPlaybackSchedulingMode = .automaticDeadlineLoop,
        externalPresentationState: AnimationPlaybackDriver.ExternalPresentationStateHandler? = nil,
        externalPresentationInvalidation: AnimationPlaybackDriver
            .ExternalPresentationInvalidationHandler? = nil,
        externalPresentationRevalidation: AnimationPlaybackDriver
            .ExternalPresentationRevalidationHandler? = nil
    ) async throws {
        try await runtime.start(
            self,
            output: output,
            failure: failure,
            initiallyVisible: initiallyVisible,
            schedulingMode: schedulingMode,
            externalPresentationState: externalPresentationState,
            externalPresentationInvalidation: externalPresentationInvalidation,
            externalPresentationRevalidation: externalPresentationRevalidation
        )
    }

    package func setVisible(_ visible: Bool) async throws {
        try await driver.setVisible(visible)
    }

    package func cancel() async {
        await runtime.cancel(identifier: identifier)
    }
}

package struct MultipartJPEGLivePlaybackHandle: Sendable {
    package let identifier: UUID
    package let session: MultipartJPEGLivePlaybackSession
    private let runtime: AnimationPlaybackRuntime

    fileprivate init(
        identifier: UUID,
        session: MultipartJPEGLivePlaybackSession,
        runtime: AnimationPlaybackRuntime
    ) {
        self.identifier = identifier
        self.session = session
        self.runtime = runtime
    }

    package func start(
        output: @escaping MultipartJPEGLivePlaybackSession.OutputHandler,
        failure: @escaping MultipartJPEGLivePlaybackSession.FailureHandler = { _ in },
        initiallyVisible: Bool = true
    ) async throws {
        try await runtime.startLive(
            self,
            output: output,
            failure: failure,
            initiallyVisible: initiallyVisible
        )
    }

    package func setVisible(_ visible: Bool) async {
        await session.setVisible(visible)
    }

    package func cancel() async {
        await runtime.cancelLive(identifier: identifier)
    }
}

/// Fovea 动画播放会话的共享资源宿主。
///
/// runtime 只共享解码帧预算并广播系统生命周期，不共享 cursor。每个 view 的 loop、seek、
/// dropped-frame 统计和显式暂停仍由独立 driver 持有。注册表有硬上限；critical pressure
/// 先通知所有 driver 关闭发布代际，再清除任何剩余帧，防止迟到结果重新进入内存。
package actor AnimationPlaybackRuntime {
    package static let defaultMaximumDriverCount = 1_024

    private let frameMemory: AnimationFrameMemory
    private let maximumDriverCount: Int
    private let automaticWholeTrackPredecodePeakCostLimit: Int
    private let sharedDecodeWorkingSetPermits: AsyncPermitPool
    private let sharedDecodePermits: AsyncPermitPool?
    private var drivers: [UUID: AnimationPlaybackDriver] = [:]
    private var driverNamespaces: [UUID: SecurityNamespaceID] = [:]
    private var minimumActiveGenerations: [SecurityNamespaceID: NamespaceGeneration] = [:]
    private var liveSessions: [UUID: MultipartJPEGLivePlaybackSession] = [:]
    private var liveNamespaces: [UUID: SecurityNamespaceID] = [:]
    private var lifetimeAnchors: [any Sendable] = []
    private var applicationIsActive = true
    private var memoryPressure: AnimationMemoryPressureLevel = .normal

    package init(
        frameMemoryCostLimit: Int,
        maximumDriverCount: Int = AnimationPlaybackRuntime.defaultMaximumDriverCount,
        automaticWholeTrackPredecodePeakCostLimit: Int? = nil,
        sharedDecodeWorkingSetPermits: AsyncPermitPool? = nil,
        sharedDecodePermits: AsyncPermitPool? = nil
    ) {
        let normalizedFrameMemoryCostLimit = max(1, frameMemoryCostLimit)
        let normalizedDriverCount = min(100_000, max(1, maximumDriverCount))
        let normalizedPredecodePeakCostLimit = max(
            1,
            automaticWholeTrackPredecodePeakCostLimit ?? normalizedFrameMemoryCostLimit
        )
        self.frameMemory = AnimationFrameMemory(costLimit: normalizedFrameMemoryCostLimit)
        self.maximumDriverCount = normalizedDriverCount
        self.automaticWholeTrackPredecodePeakCostLimit = normalizedPredecodePeakCostLimit
        self.sharedDecodeWorkingSetPermits =
            sharedDecodeWorkingSetPermits
            ?? AsyncPermitPool(
                limit: normalizedPredecodePeakCostLimit,
                queueLimit: normalizedDriverCount
            )
        self.sharedDecodePermits = sharedDecodePermits
    }

    package func retainLifetimeAnchor(_ anchor: any Sendable) {
        lifetimeAnchors.append(anchor)
    }

    package func resolveFrameStrategySelection(
        _ selection: AnimationFrameStrategySelection,
        timeline: AnimationPlaybackTimeline,
        resolvedMode: AnimationPlaybackMode,
        wholeTrackDecodedByteCostUpperBound: Int?,
        wholeTrackProviderRetainedByteCostUpperBound: Int?,
        wholeTrackPredecodePeakByteCostUpperBound: Int?,
        explicitMaximumPredecodeAllFrameCount: Int
    ) -> (strategy: AnimationFrameStrategy, maximumPredecodeFrames: Int) {
        switch selection {
        case .fixed(let strategy):
            return (strategy, explicitMaximumPredecodeAllFrameCount)
        case .automaticWholeTrack(
            let requestedMaximumFrameCount,
            let requestedMaximumPredecodePeakByteCost,
            let requestedByteCap
        ):
            let frameCount = timeline.frameCount
            let maximumFrameCount = max(0, requestedMaximumFrameCount)
            let runtimeResidentByteCap = frameMemory.availableWholeTrackAdmissionCost
            let callerDecodedByteCap = requestedByteCap.map { max(0, $0) } ?? Int.max
            let predecodePeakCap = min(
                max(0, requestedMaximumPredecodePeakByteCost),
                automaticWholeTrackPredecodePeakCostLimit
            )
            guard let residentUpperBound = wholeTrackDecodedByteCostUpperBound,
                residentUpperBound > 0,
                let providerRetainedUpperBound = wholeTrackProviderRetainedByteCostUpperBound,
                providerRetainedUpperBound >= 0
            else {
                return (.boundedFrameCache, 0)
            }
            let steadyStateUpperBound = residentUpperBound.addingReportingOverflow(
                providerRetainedUpperBound
            )
            guard memoryPressure == .normal,
                resolvedMode == .normal,
                frameCount > 1,
                frameCount <= maximumFrameCount,
                residentUpperBound <= callerDecodedByteCap,
                !steadyStateUpperBound.overflow,
                steadyStateUpperBound.partialValue <= runtimeResidentByteCap,
                let predecodePeakUpperBound = wholeTrackPredecodePeakByteCostUpperBound,
                predecodePeakUpperBound >= steadyStateUpperBound.partialValue,
                predecodePeakUpperBound <= predecodePeakCap
            else {
                return (.boundedFrameCache, 0)
            }
            return (.predecodeAll, frameCount)
        }
    }

    package func makeHandle(
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration,
        decodeKey: AnimationDecodeKey,
        timeline: AnimationPlaybackTimeline,
        playbackPolicy: AnimationPlaybackPolicy,
        reduceMotionEnabled: Bool,
        provider: any AnimationFrameProvider,
        windowPolicy: AnimationFrameWindowPolicy,
        maximumPredecodeAllFrameCount: Int = 0,
        maximumQueuedAdvances: Int = 8,
        automaticWholeTrackDecodedByteCostUpperBound: Int? = nil,
        providerRetainedByteCost: Int? = nil,
        automaticWholeTrackPredecodePeakByteCost: Int? = nil,
        decodePriority: ImageRequestPriority = .normal,
        clock: any AnimationPlaybackClock = SystemAnimationPlaybackClock()
    ) throws -> AnimationPlaybackHandle {
        try validateHandleRegistration(
            namespace: namespace,
            generation: generation,
            automaticWholeTrackDecodedByteCostUpperBound:
                automaticWholeTrackDecodedByteCostUpperBound,
            providerRetainedByteCost: providerRetainedByteCost,
            automaticWholeTrackPredecodePeakByteCost:
                automaticWholeTrackPredecodePeakByteCost
        )
        let session = AnimationPlaybackSession(
            namespace: namespace,
            generation: generation,
            decodeKey: decodeKey,
            timeline: timeline,
            mode: playbackPolicy.resolvedMode(reduceMotionEnabled: reduceMotionEnabled),
            frameMemory: frameMemory,
            windowPolicy: windowPolicy,
            maximumPredecodeAllFrameCount: maximumPredecodeAllFrameCount
        )
        let coordinator = AnimationPlaybackCoordinator(
            session: session,
            provider: provider,
            maximumQueuedAdvances: maximumQueuedAdvances,
            sharedDecodeWorkingSetPermits: sharedDecodeWorkingSetPermits,
            sharedDecodePermits: sharedDecodePermits,
            automaticWholeTrackDecodedByteCostUpperBound:
                automaticWholeTrackDecodedByteCostUpperBound,
            automaticWholeTrackPredecodePeakByteCost:
                automaticWholeTrackPredecodePeakByteCost,
            decodePriority: decodePriority
        )
        let driver = AnimationPlaybackDriver(coordinator: coordinator, clock: clock)
        let identifier = UUID()
        if let providerRetainedByteCost {
            guard
                frameMemory.reserveExternalRetainedCost(
                    providerRetainedByteCost,
                    for: identifier
                )
            else {
                throw AnimationPlaybackRuntimeError.capacityExceeded
            }
        }
        drivers[identifier] = driver
        driverNamespaces[identifier] = namespace
        return AnimationPlaybackHandle(
            identifier: identifier,
            driver: driver,
            presentationCadenceRecommendation: AnimationPresentationCadenceRecommendation(
                frameDurationsNanoseconds: timeline.frameDurationsNanoseconds
            ),
            runtime: self
        )
    }

    private func validateHandleRegistration(
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration,
        automaticWholeTrackDecodedByteCostUpperBound: Int?,
        providerRetainedByteCost: Int?,
        automaticWholeTrackPredecodePeakByteCost: Int?
    ) throws {
        guard drivers.count + liveSessions.count < maximumDriverCount else {
            throw AnimationPlaybackRuntimeError.capacityExceeded
        }
        if let minimum = minimumActiveGenerations[namespace], generation.value < minimum.value {
            throw AnimationPlaybackRuntimeError.generationRevoked
        }
        let hasAutomaticDecodedCost = automaticWholeTrackDecodedByteCostUpperBound != nil
        let hasAutomaticPeakCost = automaticWholeTrackPredecodePeakByteCost != nil
        guard hasAutomaticDecodedCost == hasAutomaticPeakCost else {
            throw AnimationPlaybackRuntimeError.invalidRegistration
        }
        if hasAutomaticDecodedCost, providerRetainedByteCost == nil {
            throw AnimationPlaybackRuntimeError.invalidRegistration
        }
    }

    package func start(
        _ handle: AnimationPlaybackHandle,
        output: @escaping AnimationPlaybackDriver.OutputHandler,
        failure: @escaping AnimationPlaybackDriver.FailureHandler = { _ in },
        initiallyVisible: Bool = true,
        schedulingMode: AnimationPlaybackSchedulingMode = .automaticDeadlineLoop,
        externalPresentationState: AnimationPlaybackDriver.ExternalPresentationStateHandler? = nil,
        externalPresentationInvalidation: AnimationPlaybackDriver
            .ExternalPresentationInvalidationHandler? = nil,
        externalPresentationRevalidation: AnimationPlaybackDriver
            .ExternalPresentationRevalidationHandler? = nil
    ) async throws {
        guard drivers[handle.identifier] === handle.driver else {
            throw AnimationPlaybackRuntimeError.invalidRegistration
        }
        try await handle.driver.start(
            output: output,
            failure: failure,
            initiallyVisible: initiallyVisible,
            initiallyApplicationActive: applicationIsActive,
            initialMemoryPressure: memoryPressure,
            schedulingMode: schedulingMode,
            externalPresentationState: externalPresentationState,
            externalPresentationInvalidation: externalPresentationInvalidation,
            externalPresentationRevalidation: externalPresentationRevalidation
        )
    }

    package func registerLiveSession(
        _ session: MultipartJPEGLivePlaybackSession,
        namespace: SecurityNamespaceID? = nil,
        generation: NamespaceGeneration? = nil
    ) throws -> MultipartJPEGLivePlaybackHandle {
        guard drivers.count + liveSessions.count < maximumDriverCount else {
            throw AnimationPlaybackRuntimeError.capacityExceeded
        }
        guard (namespace == nil) == (generation == nil) else {
            throw AnimationPlaybackRuntimeError.invalidRegistration
        }
        if let namespace, let generation,
            let minimum = minimumActiveGenerations[namespace],
            generation.value < minimum.value
        {
            throw AnimationPlaybackRuntimeError.generationRevoked
        }
        let identifier = UUID()
        liveSessions[identifier] = session
        if let namespace { liveNamespaces[identifier] = namespace }
        return MultipartJPEGLivePlaybackHandle(
            identifier: identifier,
            session: session,
            runtime: self
        )
    }

    package func startLive(
        _ handle: MultipartJPEGLivePlaybackHandle,
        output: @escaping MultipartJPEGLivePlaybackSession.OutputHandler,
        failure: @escaping MultipartJPEGLivePlaybackSession.FailureHandler = { _ in },
        initiallyVisible: Bool = true
    ) async throws {
        guard liveSessions[handle.identifier] === handle.session else {
            throw AnimationPlaybackRuntimeError.invalidRegistration
        }
        let identifier = handle.identifier
        let session = handle.session
        try await session.start(
            output: output,
            failure: { [weak self, weak session] error in
                await failure(error)
                guard let session else { return }
                await self?.removeTerminalLiveSession(
                    identifier: identifier,
                    session: session
                )
            },
            completion: { [weak self, weak session] in
                guard let session else { return }
                await self?.removeTerminalLiveSession(
                    identifier: identifier,
                    session: session
                )
            },
            initiallyVisible: initiallyVisible,
            initiallyApplicationActive: applicationIsActive,
            initialMemoryPressure: memoryPressure
        )
    }

    @discardableResult
    package func setApplicationActive(_ active: Bool) async -> AnimationPlaybackRuntimeReport {
        applicationIsActive = active
        var affected = 0
        var failed = 0
        for driver in drivers.values {
            do {
                try await driver.setApplicationActive(active)
                affected += 1
            } catch {
                failed += 1
            }
        }
        for session in liveSessions.values {
            await session.setApplicationActive(active)
        }
        return report(
            affected: affected,
            affectedLive: liveSessions.count,
            failed: failed,
            failedLive: 0
        )
    }

    @discardableResult
    package func applyMemoryPressure(
        _ level: AnimationMemoryPressureLevel
    ) async -> AnimationPlaybackRuntimeReport {
        memoryPressure = level
        var affected = 0
        var failed = 0
        var removedItems = 0
        var removedBytes = 0
        for driver in drivers.values {
            do {
                let summary = try await driver.applyMemoryPressure(level)
                affected += 1
                removedItems = Self.saturatingAdd(removedItems, summary.itemCount)
                removedBytes = Self.saturatingAdd(removedBytes, summary.costBytes)
            } catch AnimationPlaybackDriverError.cancelled {
                failed += 1
            } catch {
                failed += 1
            }
        }
        for session in liveSessions.values {
            await session.setMemoryPressure(level)
        }
        if level == .critical {
            let remainder = frameMemory.removeAllAndReport()
            removedItems = Self.saturatingAdd(removedItems, remainder.itemCount)
            removedBytes = Self.saturatingAdd(removedBytes, remainder.costBytes)
        }
        return AnimationPlaybackRuntimeReport(
            registeredDriverCount: drivers.count,
            registeredLiveSessionCount: liveSessions.count,
            affectedDriverCount: affected,
            affectedLiveSessionCount: liveSessions.count,
            failedDriverCount: failed,
            failedLiveSessionCount: 0,
            removedFrames: MemoryCacheRemovalSummary(
                itemCount: removedItems,
                costBytes: removedBytes
            )
        )
    }

    private func removeTerminalLiveSession(
        identifier: UUID,
        session: MultipartJPEGLivePlaybackSession
    ) {
        guard liveSessions[identifier] === session else { return }
        liveSessions.removeValue(forKey: identifier)
        liveNamespaces.removeValue(forKey: identifier)
    }

    package func cancel(identifier: UUID) async {
        guard let driver = drivers.removeValue(forKey: identifier) else { return }
        driverNamespaces.removeValue(forKey: identifier)
        await driver.cancel()
        frameMemory.releaseExternalRetainedCost(for: identifier)
    }

    package func cancelLive(identifier: UUID) async {
        guard let session = liveSessions.removeValue(forKey: identifier) else { return }
        liveNamespaces.removeValue(forKey: identifier)
        await session.cancel()
    }

    package func cancelAll() async {
        let removed = Array(drivers)
        let removedLive = Array(liveSessions.values)
        drivers.removeAll(keepingCapacity: true)
        driverNamespaces.removeAll(keepingCapacity: true)
        liveSessions.removeAll(keepingCapacity: true)
        liveNamespaces.removeAll(keepingCapacity: true)
        for (identifier, driver) in removed {
            await driver.cancel()
            frameMemory.releaseExternalRetainedCost(for: identifier)
        }
        for session in removedLive { await session.cancel() }
        _ = frameMemory.removeAllAndReport()
    }

    package func cancelAll(namespace: SecurityNamespaceID) async {
        let driverIDs = driverNamespaces.compactMap { identifier, candidate in
            candidate == namespace ? identifier : nil
        }
        let liveIDs = liveNamespaces.compactMap { identifier, candidate in
            candidate == namespace ? identifier : nil
        }
        let removedDrivers = driverIDs.compactMap {
            identifier -> (UUID, AnimationPlaybackDriver)? in
            driverNamespaces.removeValue(forKey: identifier)
            guard let driver = drivers.removeValue(forKey: identifier) else { return nil }
            return (identifier, driver)
        }
        let removedLive = liveIDs.compactMap { identifier -> MultipartJPEGLivePlaybackSession? in
            liveNamespaces.removeValue(forKey: identifier)
            return liveSessions.removeValue(forKey: identifier)
        }
        for (identifier, driver) in removedDrivers {
            await driver.cancel()
            frameMemory.releaseExternalRetainedCost(for: identifier)
        }
        for session in removedLive { await session.cancel() }
        _ = frameMemory.removeAll(namespace: namespace)
    }

    package func registeredDriverCount() -> Int { drivers.count }
    package func registeredLiveSessionCount() -> Int { liveSessions.count }
    package func currentFrameMemoryCost() -> Int { frameMemory.currentCost }
    package func currentFrameCount() -> Int { frameMemory.count }
    package func currentPinnedFrameMemoryCostForTesting() -> Int {
        frameMemory.pinnedCostForTesting
    }
    package func currentPinnedFrameCountForTesting() -> Int {
        frameMemory.pinnedCountForTesting
    }
    package func currentProviderRetainedMemoryCostForTesting() -> Int {
        frameMemory.externalRetainedCostForTesting
    }
    package func currentAnimationResidentBudgetCostForTesting() -> Int {
        frameMemory.totalBudgetCostForTesting
    }
    package func automaticWholeTrackPredecodePeakUsedUnitsForTesting() async -> Int {
        await sharedDecodeWorkingSetPermits.usedUnits
    }
    package func automaticWholeTrackPredecodePeakQueuedCountForTesting() async -> Int {
        await sharedDecodeWorkingSetPermits.queuedCount()
    }
    package func applicationIsActiveForTesting() -> Bool { applicationIsActive }
    package func memoryPressureForTesting() -> AnimationMemoryPressureLevel { memoryPressure }

    private func report(
        affected: Int,
        affectedLive: Int,
        failed: Int,
        failedLive: Int
    ) -> AnimationPlaybackRuntimeReport {
        AnimationPlaybackRuntimeReport(
            registeredDriverCount: drivers.count,
            registeredLiveSessionCount: liveSessions.count,
            affectedDriverCount: affected,
            affectedLiveSessionCount: affectedLive,
            failedDriverCount: failed,
            failedLiveSessionCount: failedLive,
            removedFrames: MemoryCacheRemovalSummary(itemCount: 0, costBytes: 0)
        )
    }

    private nonisolated static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let value = lhs.addingReportingOverflow(rhs)
        return value.overflow ? Int.max : value.partialValue
    }
}

extension AnimationPlaybackRuntime: NamespaceRevocationObserving {
    package func namespaceWillRevoke(
        _ namespace: SecurityNamespaceID,
        minimumActiveGeneration: NamespaceGeneration?
    ) async {
        if let minimumActiveGeneration {
            if let existing = minimumActiveGenerations[namespace] {
                if minimumActiveGeneration.value > existing.value {
                    minimumActiveGenerations[namespace] = minimumActiveGeneration
                }
            } else {
                minimumActiveGenerations[namespace] = minimumActiveGeneration
            }
        }
        await cancelAll(namespace: namespace)
    }
}
