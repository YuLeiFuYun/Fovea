import Foundation
import FoveaCore
import FoveaObservability
import ImageCraftCore

@MainActor
/// Workbench 的主线程状态所有者，负责配置切换、运行记录和页面可观察证据。
/// 网络、预取与实验执行由独立协作者承担，模型只原子发布已完成的状态快照。
final class WorkbenchAppModel: ObservableObject {
    enum RuntimeState: Equatable {
        case idle
        case opening
        case ready
        case failed(String)
    }

    @Published private(set) var runtimeState: RuntimeState = .idle
    @Published private(set) var pipeline: FoveaPipeline?
    @Published private(set) var activeConfiguration = WorkbenchConfiguration.defaults
    @Published var draftConfiguration: WorkbenchConfiguration
    @Published private(set) var storageGenerationIdentifier = "—"
    @Published private(set) var diagnosticEvents: [RecordedDiagnosticEvent] = []
    @Published private(set) var droppedDiagnosticEvents = 0
    @Published private(set) var originRequestCounts: [String: Int] = [:]
    @Published private(set) var runs: [WorkbenchRunRecord] = []
    @Published private(set) var performanceSnapshots: [WorkbenchPerformanceSnapshot] = []
    @Published private(set) var network = WorkbenchNetworkSnapshot()
    @Published private(set) var identityRevision = UUID()
    @Published private(set) var lastOperationError: String?
    @Published private(set) var prefetchedRemoteAssetCount = 0
    @Published private(set) var recommendedPrefetchCount = 0

    private static let maximumRunHistory = 200
    private static let maximumPerformanceHistory = 50
    private let configurationKey = "FoveaWorkbench.Configuration.v2"
    private let cacheRoot: URL
    private let configurationStore: UserDefaults
    private var runtime: WorkbenchPipelineRuntime?
    private var diagnostics = WorkbenchDiagnosticsSink()
    private var runTasks: [UUID: Task<Void, Never>] = [:]
    private var cancelledRunIDs: Set<UUID> = []
    private var pollingTask: Task<Void, Never>?
    private var networkMonitor: WorkbenchNetworkMonitor?
    let prefetchCoordinator = WorkbenchPrefetchCoordinator()
    private var isOpening = false
    private var isApplicationActive = true

    init(
        cacheRoot overrideCacheRoot: URL? = nil,
        configurationStore: UserDefaults = .standard
    ) {
        self.configurationStore = configurationStore
        let launchState = WorkbenchLaunchState.resolve(
            configurationStore: configurationStore,
            configurationKey: configurationKey,
            overrideCacheRoot: overrideCacheRoot
        )
        draftConfiguration = launchState.configuration
        activeConfiguration = launchState.configuration
        cacheRoot = launchState.cacheRoot
    }

    var hasUnappliedConfiguration: Bool {
        draftConfiguration.normalized() != activeConfiguration
    }

    var requiresPipelineRebuild: Bool {
        runtime == nil
            || draftConfiguration.normalized().pipelineSettings
                != activeConfiguration.pipelineSettings
    }

    var isReady: Bool { pipeline != nil && runtimeState == .ready }
    var activeRunCount: Int { runs.lazy.filter { $0.state == .running }.count }
    var pendingRunTaskCount: Int { runTasks.count }

    var presentedErrorMessage: String? {
        if let lastOperationError { return lastOperationError }
        if case .failed(let message) = runtimeState { return message }
        return nil
    }

    func start() async {
        guard runtimeState == .idle else { return }
        networkMonitor = WorkbenchNetworkMonitor { [weak self] snapshot in
            guard let self, self.network != snapshot else { return }
            self.network = snapshot
        }
        startPollingDiagnostics()
        await applyConfiguration()
    }

    func setApplicationActive(_ isActive: Bool) {
        isApplicationActive = isActive
        if isActive {
            startPollingDiagnostics()
        } else {
            pollingTask?.cancel()
            pollingTask = nil
        }
    }

    func applyConfiguration() async {
        guard !isOpening else { return }
        isOpening = true
        lastOperationError = nil

        let requested = draftConfiguration.normalized()
        if requested != draftConfiguration {
            draftConfiguration = requested
        }

        let previousConfiguration = activeConfiguration
        let rebuildRequired =
            runtime == nil
            || requested.pipelineSettings != previousConfiguration.pipelineSettings

        if !rebuildRequired {
            activeConfiguration = requested
            persistConfiguration(requested)
            if requested.requestSettings != previousConfiguration.requestSettings {
                reloadIdentity()
            }
            runtimeState = .ready
            isOpening = false
            return
        }

        runtimeState = .opening
        await cancelAndDrainAllRuns()
        resetPrefetchState()
        let previousRuntime = runtime
        let previousProfile = previousConfiguration.storageProfileIdentifier
        let newDiagnostics = WorkbenchDiagnosticsSink()

        do {
            let osLogDiagnostics = OSLogDiagnosticsSink(
                configuration: try OSLogDiagnosticsConfiguration(
                    subsystem: "dev.fovea.workbench",
                    category: "pipeline",
                    sampling: .oneIn(16),
                    signpostsEnabled: true
                )
            )
            let newRuntime = try await WorkbenchPipelineFactory.open(
                cacheRoot: cacheRoot,
                configuration: requested,
                diagnostics: WorkbenchDiagnosticsMultiplexer([
                    newDiagnostics,
                    osLogDiagnostics,
                ])
            )

            runtime = newRuntime
            diagnostics = newDiagnostics
            pipeline = newRuntime.pipeline
            activeConfiguration = requested
            storageGenerationIdentifier = newRuntime.storageGenerationIdentifier
            diagnosticEvents = []
            droppedDiagnosticEvents = 0
            await DemoOriginMetrics.shared.reset()
            originRequestCounts = [:]
            identityRevision = UUID()
            persistConfiguration(requested)
            runtimeState = .ready

            if let previousRuntime {
                await previousRuntime.invalidateAndCancel()
            }
            let pruneResult = await WorkbenchStorageMaintenance.pruneObsoleteStorageProfiles(
                cacheRoot: cacheRoot,
                preserving: [requested.storageProfileIdentifier, previousProfile]
            )
            if pruneResult.failedOperationCount > 0 {
                lastOperationError = "缓存配置清理未完全完成；失败操作数：\(pruneResult.failedOperationCount)。"
            }
        } catch {
            if previousRuntime != nil {
                runtimeState = .ready
                lastOperationError = WorkbenchErrorDescription.make(error)
            } else {
                runtime = nil
                pipeline = nil
                runtimeState = .failed(WorkbenchErrorDescription.make(error))
            }
        }
        isOpening = false
    }

    func dismissPresentedError() {
        lastOperationError = nil
        if case .failed = runtimeState {
            runtimeState = pipeline == nil ? .idle : .ready
        }
    }

    func reloadIdentity() {
        identityRevision = UUID()
    }

    @discardableResult
    func run(
        _ scenario: WorkbenchScenario,
        count: Int = 1,
        target explicitTarget: TargetPixels? = nil
    ) -> UUID? {
        guard isReady else { return nil }
        guard activeRunCount == 0 else {
            lastOperationError = "证据运行采用串行隔离；请等待当前实验完成或先取消它。"
            return nil
        }

        let requestCount = max(1, min(64, count))
        let id = UUID()
        runs.insert(
            WorkbenchRunRecord(
                id: id,
                scenarioID: scenario.id,
                scenarioTitle: scenario.title,
                startedAt: Date(),
                requestCount: requestCount,
                completedCount: 0,
                state: .running
            ),
            at: 0
        )
        trimRunHistory()

        let configuration = activeConfiguration
        let revision = identityRevision.uuidString.lowercased()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.executeRun(
                id: id,
                scenario: scenario,
                requestCount: requestCount,
                configuration: configuration,
                identityRevision: revision,
                explicitTarget: explicitTarget
            )
        }
        runTasks[id] = task
        return id
    }

    func cancelRun(_ id: UUID) {
        guard let record = runs.first(where: { $0.id == id }), record.state == .running else {
            return
        }
        cancelledRunIDs.insert(id)
        runTasks[id]?.cancel()
        markRunCancelled(id: id, at: Date())
    }

    func cancelAllRuns() {
        let activeIDs = runs.compactMap { $0.state == .running ? $0.id : nil }
        cancelledRunIDs.formUnion(activeIDs)
        for task in runTasks.values { task.cancel() }
        let now = Date()
        for id in activeIDs { markRunCancelled(id: id, at: now) }
    }

    /// 管线切换使用的强取消：等待每个证据 runtime 完成自身 invalidation，
    /// 避免旧实验在新管线发布后继续占用连接、缓存或回写运行状态。
    private func cancelAndDrainAllRuns() async {
        cancelAllRuns()
        let tasks = Array(runTasks.values)
        for task in tasks { await task.value }
    }

    func clearFinishedRuns() {
        runs.removeAll { $0.state.isFinished }
    }

    func latestRun(for scenarioID: String) -> WorkbenchRunRecord? {
        runs.first { $0.scenarioID == scenarioID }
    }

    func latestEvidence(for scenarioID: String) -> WorkbenchRunEvidence? {
        latestRun(for: scenarioID)?.evidence
    }

    func publishPrefetchState(completed: Int, recommended: Int) {
        prefetchedRemoteAssetCount = completed
        recommendedPrefetchCount = recommended
    }

    func recordPerformanceSnapshot(_ snapshot: WorkbenchPerformanceSnapshot) {
        performanceSnapshots.insert(snapshot, at: 0)
        if performanceSnapshots.count > Self.maximumPerformanceHistory {
            performanceSnapshots.removeLast(
                performanceSnapshots.count - Self.maximumPerformanceHistory
            )
        }
    }

    func purgeMemory() async {
        resetPrefetchState()
        WorkbenchBundledImageCache.shared.removeAll()
        _ = await pipeline?.purgeMemoryCache()
        reloadIdentity()
    }

    func garbageCollect() async {
        guard let pipeline else { return }
        do {
            _ = try await pipeline.garbageCollectCaches()
        } catch {
            lastOperationError = WorkbenchErrorDescription.make(error)
        }
    }

    func revokePublicNamespace() async {
        await revoke(workbenchPublicNamespace)
    }

    func revokePrivateNamespace() async {
        await revoke(workbenchPrivateNamespace)
    }

    func revokePrivateNamespaceB() async {
        await revoke(workbenchPrivateNamespaceB)
    }

    func clearDiagnostics() async {
        await diagnostics.clear()
        diagnosticEvents = []
        droppedDiagnosticEvents = 0
    }

    func resetEvidence() async {
        guard activeRunCount == 0 else {
            lastOperationError = "请先取消或完成当前证据运行，再清空证据。"
            return
        }
        await diagnostics.clear()
        await DemoOriginMetrics.shared.reset()
        diagnosticEvents = []
        droppedDiagnosticEvents = 0
        originRequestCounts = [:]
        performanceSnapshots = []
    }

    func resetConfiguration() {
        draftConfiguration = .defaults
    }

    func diagnosticsJSON() -> String {
        WorkbenchEvidenceExport.diagnosticsJSON(diagnosticEvents)
    }

    func evidenceBundle() -> WorkbenchEvidenceBundle {
        WorkbenchEvidenceExport.bundle(
            configuration: activeConfiguration,
            storageGenerationIdentifier: storageGenerationIdentifier,
            runs: runs,
            diagnostics: diagnosticEvents,
            originRequestCounts: originRequestCounts,
            performanceSnapshots: performanceSnapshots
        )
    }

    private func executeRun(
        id: UUID,
        scenario: WorkbenchScenario,
        requestCount: Int,
        configuration: WorkbenchConfiguration,
        identityRevision: String,
        explicitTarget: TargetPixels?
    ) async {
        let result = await WorkbenchExperimentRunner.execute(
            id: id,
            scenario: scenario,
            requestCount: requestCount,
            configuration: configuration,
            identityRevision: identityRevision,
            explicitTarget: explicitTarget,
            cacheRoot: cacheRoot
        ) { [weak self] completed in
            self?.updateRunProgress(id: id, completed: completed)
        }
        finishRun(
            id: id,
            completed: result.completedCount,
            outcome: result.outcome,
            evidence: result.evidence
        )
        await refreshTelemetrySnapshot()
    }

    private func revoke(_ namespace: SecurityNamespaceID) async {
        guard let pipeline else { return }
        do {
            try await pipeline.revoke(namespace: namespace)
            reloadIdentity()
        } catch {
            lastOperationError = WorkbenchErrorDescription.make(error)
        }
    }

    private func startPollingDiagnostics() {
        guard isApplicationActive, pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshTelemetrySnapshot()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func refreshTelemetrySnapshot() async {
        let sink = diagnostics
        let events = await sink.snapshot()
        let dropped = await sink.droppedEventCount()
        let counts = await DemoOriginMetrics.shared.snapshot()

        if diagnosticEvents.count != events.count
            || diagnosticEvents.last?.sequence != events.last?.sequence
        {
            diagnosticEvents = events
        }
        if droppedDiagnosticEvents != dropped {
            droppedDiagnosticEvents = dropped
        }
        if originRequestCounts != counts {
            originRequestCounts = counts
        }
    }

    private func persistConfiguration(_ configuration: WorkbenchConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        configurationStore.set(data, forKey: configurationKey)
    }

    private func updateRunProgress(id: UUID, completed: Int) {
        mutateRun(id: id) { record in
            record.completedCount = completed
        }
    }

    private func finishRun(
        id: UUID,
        completed: Int,
        outcome: WorkbenchRunRecord.State,
        evidence: WorkbenchRunEvidence
    ) {
        runTasks.removeValue(forKey: id)
        if cancelledRunIDs.remove(id) != nil {
            markRunCancelled(id: id, at: Date())
            return
        }
        mutateRun(id: id) { record in
            record.completedCount = completed
            record.state = outcome
            record.evidence = evidence
            record.finishedAt = Date()
        }
    }

    private func markRunCancelled(id: UUID, at date: Date) {
        mutateRun(id: id) { record in
            guard record.state == .running else { return }
            record.state = .cancelled
            record.finishedAt = date
        }
    }

    private func mutateRun(
        id: UUID,
        mutation: (inout WorkbenchRunRecord) -> Void
    ) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        var record = runs[index]
        mutation(&record)
        runs[index] = record
    }

    private func trimRunHistory() {
        guard runs.count > Self.maximumRunHistory else { return }
        let active = runs.filter { $0.state == .running }
        let finished = runs.filter { $0.state.isFinished }
            .prefix(max(0, Self.maximumRunHistory - active.count))
        runs = active + finished
    }

}
