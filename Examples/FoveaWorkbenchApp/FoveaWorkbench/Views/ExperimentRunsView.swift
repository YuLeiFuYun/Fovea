import SwiftUI

/// 展示有界运行历史、预期判定和可导出的证据包。
/// 页面只消费已脱敏模型，不直接读取传输对象或持久化路径。
struct ExperimentRunsView: View {
    @EnvironmentObject private var model: WorkbenchAppModel

    @State private var unexpectedOnly = false
    @State private var evidenceDocument: WorkbenchEvidenceDocument?
    @State private var isExportingEvidence = false
    @State private var exportError: String?
    @State private var actionMessage = "尚未执行证据操作"
    @State private var coreSuiteTask: Task<Void, Never>?

    var body: some View {
        NavigationView {
            List {
                operationStatusSection
                suiteSection
                evidenceSection
                performanceSection
                concurrencySection
                runsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("证据与运行")
            .fileExporter(
                isPresented: $isExportingEvidence,
                document: evidenceDocument,
                contentType: .json,
                defaultFilename: evidenceFilename
            ) { result in
                switch result {
                case .success:
                    actionMessage = "证据包已导出"
                case .failure:
                    exportError = "证据导出失败。请检查目标位置的写入权限。"
                    actionMessage = "证据包导出失败"
                }
                evidenceDocument = nil
            }
            .alert("无法导出证据", isPresented: exportAlertBinding) {
                Button("好", role: .cancel) {}
            } message: {
                Text(exportError ?? "未知错误")
            }
        }
        .navigationViewStyle(.stack)
        .onDisappear {
            coreSuiteTask?.cancel()
            coreSuiteTask = nil
        }
    }

    private var operationStatusSection: some View {
        Section("操作结果") {
            WorkbenchActionStatus(
                message: actionMessage,
                identifier: "experiments.action-status"
            )
            NavigationLink(destination: DiagnosticsContentView()) {
                Label("查看管线诊断", systemImage: "waveform.path.ecg")
                    .frame(minHeight: WorkbenchDesign.controlMinimumHeight)
            }
            .accessibilityIdentifier("evidence.open-diagnostics")
        }
    }

    private var suiteSection: some View {
        Section("快速套件") {
            Button {
                startCoreSuite()
            } label: {
                Label("运行确定性核心套件", systemImage: "checkmark.seal")
            }
            .disabled(!model.isReady || coreSuiteTask != nil || model.activeRunCount > 0)
            .accessibilityIdentifier("experiments.run-core-suite")

            Button(role: .destructive) {
                let activeCount = model.activeRunCount
                coreSuiteTask?.cancel()
                coreSuiteTask = nil
                model.cancelAllRuns()
                actionMessage =
                    activeCount > 0 ? "已取消\(activeCount)个运行" : "确定性核心套件已取消"
            } label: {
                Label("取消全部运行", systemImage: "stop.circle")
            }
            .disabled(model.activeRunCount == 0 && coreSuiteTask == nil)
            .accessibilityIdentifier("experiments.cancel-all")

            Button {
                let finishedCount = model.runs.lazy.filter { $0.state.isFinished }.count
                model.clearFinishedRuns()
                actionMessage = "已清除\(finishedCount)条完成记录"
            } label: {
                Label("清除已完成记录", systemImage: "trash")
            }
            .disabled(model.runs.allSatisfy { !$0.state.isFinished })
            .accessibilityIdentifier("experiments.clear-finished")
        }
    }

    private var evidenceSection: some View {
        Section("证据包") {
            Button {
                exportEvidence()
            } label: {
                Label("导出 JSON 证据包", systemImage: "square.and.arrow.up")
            }
            .disabled(model.runs.isEmpty && model.diagnosticEvents.isEmpty)
            .accessibilityIdentifier("experiments.export-evidence")

            metadataRow("源码修订", value: sourceRevision)
            metadataRow("源码树状态", value: sourceTree)
            metadataRow("存储代际", value: model.storageGenerationIdentifier)
            Text(
                "导出内容包含配置指纹、源码 revision/dirty 标记、设备与系统、每次运行的源站、共享、缓存与取消证据、诊断时间线和源站计数。"
            )
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    private func metadataRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    private var performanceSection: some View {
        Section("滚动性能代理") {
            if model.performanceSnapshots.isEmpty {
                Text("在列表性能实验中运行脚本或手动测量后，这里会显示帧间隔与常驻内存结果。")
                    .foregroundColor(.secondary)
            } else {
                ForEach(model.performanceSnapshots.prefix(10)) { snapshot in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(snapshot.workloadID)
                                .font(.headline)
                            Spacer()
                            Text("\(snapshot.host) · \(snapshot.layout)")
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                        }
                        HStack(spacing: 12) {
                            Text("卡顿代理 \(snapshot.hitchCount)")
                            Text(
                                "最长间隔 \(snapshot.maximumFrameIntervalMilliseconds, specifier: "%.1f") 毫秒"
                            )
                            Text("常驻内存 +\(formatBytes(snapshot.peakFootprintDeltaBytes))")
                            Text("\(snapshot.durationMilliseconds) 毫秒")
                        }
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                    }
                    .accessibilityIdentifier("performance.snapshot.\(snapshot.workloadID)")
                }
            }
            Text("这些代理值只用于同设备、同配置的回归比较；它们不等同于苹果性能分析工具或 MetricKit 给出的帧率、能耗与热状态结论。")
                .font(.caption)
                .foregroundColor(.orange)
        }
    }

    private func formatBytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "无数据" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes),
            countStyle: .memory
        )
    }

    private var concurrencySection: some View {
        Section("并发参数") {
            Stepper(
                "相同请求并发数：\(model.draftConfiguration.burstCount)",
                value: $model.draftConfiguration.burstCount,
                in: 2...32
            )
            Text("并发请求使用完全相同的图片请求；运行记录直接保存网络共享与解码共享计数，不必再从全局日志猜测。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var runsSection: some View {
        Section {
            Toggle("仅显示非预期结果", isOn: $unexpectedOnly)
            if filteredRuns.isEmpty {
                Text(model.runs.isEmpty ? "尚未运行实验" : "没有非预期结果")
                    .foregroundColor(.secondary)
            } else {
                ForEach(filteredRuns) { record in
                    RunRecordRow(record: record) {
                        model.cancelRun(record.id)
                    }
                }
            }
        } header: {
            HStack {
                Text("最近运行")
                Spacer()
                Text("\(filteredRuns.count)/\(model.runs.count)")
                    .font(.caption.monospacedDigit())
            }
        }
    }

    private var filteredRuns: [WorkbenchRunRecord] {
        unexpectedOnly ? model.runs.filter { $0.state.isUnexpected } : model.runs
    }

    private var evidenceFilename: String {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "fovea-workbench-evidence-\(timestamp)"
    }

    private var sourceRevision: String { WorkbenchBuildMetadata.revision }

    private var sourceTree: String { WorkbenchBuildMetadata.sourceTree }

    private var exportAlertBinding: Binding<Bool> {
        Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )
    }

    private func exportEvidence() {
        do {
            evidenceDocument = try WorkbenchEvidenceDocument(bundle: model.evidenceBundle())
            isExportingEvidence = true
            actionMessage = "证据包已生成，等待选择保存位置"
        } catch {
            exportError = "证据 JSON 编码失败。"
            actionMessage = "证据包编码失败"
        }
    }

    private func startCoreSuite() {
        guard coreSuiteTask == nil else { return }
        let scenarios = coreSuiteScenarios
        guard !scenarios.isEmpty else {
            actionMessage = "未找到确定性核心套件场景"
            return
        }
        actionMessage = "确定性核心套件运行中：0/\(scenarios.count)"
        coreSuiteTask = Task { @MainActor in
            defer { coreSuiteTask = nil }
            await runCoreSuite(scenarios)
        }
    }

    private func runCoreSuite(_ scenarios: [WorkbenchScenario]) async {
        for (index, scenario) in scenarios.enumerated() {
            guard !Task.isCancelled else {
                actionMessage = "确定性核心套件已取消"
                return
            }
            guard let runID = startCoreSuiteScenario(scenario) else { return }
            guard await waitForCoreSuiteScenario(scenario, runID: runID) else { return }
            guard !Task.isCancelled else {
                model.cancelRun(runID)
                actionMessage = "确定性核心套件已取消"
                return
            }
            actionMessage = "确定性核心套件运行中：\(index + 1)/\(scenarios.count)"
        }
        actionMessage = "确定性核心套件已完成：\(scenarios.count)/\(scenarios.count)"
    }

    private func startCoreSuiteScenario(_ scenario: WorkbenchScenario) -> UUID? {
        let requestCount =
            scenario.id == "single-flight-burst"
            ? model.draftConfiguration.burstCount : 1
        guard let runID = model.run(scenario, count: requestCount) else {
            actionMessage = "无法启动“\(scenario.title)”；套件已停止"
            return nil
        }
        return runID
    }

    private func waitForCoreSuiteScenario(
        _ scenario: WorkbenchScenario,
        runID: UUID
    ) async -> Bool {
        while !Task.isCancelled {
            guard let record = model.runs.first(where: { $0.id == runID }) else {
                actionMessage = "“\(scenario.title)”运行记录丢失；套件已停止"
                return false
            }
            if record.state.isUnexpected {
                actionMessage = "“\(scenario.title)”结果非预期；套件已停止"
                return false
            }
            if record.state.isFinished { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private var coreSuiteScenarios: [WorkbenchScenario] {
        [
            "cacheable-image",
            "etag-revalidation",
            "vary-language",
            "vary-wildcard",
            "authenticated-private",
            "same-origin-redirect",
            "http-404",
            "wrong-mime",
            "corrupt-image",
            "oversized-body",
            "incomplete-body",
            "empty-image-body",
            "single-flight-burst",
        ].compactMap(WorkbenchScenarioCatalog.scenario(id:))
    }
}

struct RunRecordRow: View {
    let record: WorkbenchRunRecord
    var cancel: (() -> Void)?

    init(record: WorkbenchRunRecord, cancel: (() -> Void)? = nil) {
        self.record = record
        self.cancel = cancel
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundColor(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.scenarioTitle).font(.headline)
                Text(record.state.title)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                HStack(spacing: 12) {
                    Text("\(record.completedCount)/\(record.requestCount)")
                    if let duration = record.durationMilliseconds {
                        Text("\(duration) 毫秒")
                    }
                }
                .font(.caption2.monospaced())
                .foregroundColor(.secondary)
                if record.state.isFinished {
                    Text(record.evidence.summary)
                        .font(.caption2.monospaced())
                        .foregroundColor(record.evidence.cacheDegraded ? .orange : .secondary)
                        .accessibilityIdentifier("run.evidence.\(record.scenarioID)")
                }
            }
            Spacer()
            if record.state == .running, let cancel {
                Button(role: .destructive, action: cancel) {
                    Image(systemName: "stop.fill")
                }
                .accessibilityLabel("取消 \(record.scenarioTitle)")
            }
        }
        .padding(.vertical, 3)
    }

    private var symbol: String {
        switch record.state {
        case .running: "hourglass"
        case .success, .environmentSuccess, .expectedFailure: "checkmark.circle.fill"
        case .environmentFailure: "globe.badge.chevron.backward"
        case .unexpectedFailure, .unexpectedSuccess: "xmark.octagon.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    private var color: Color {
        switch record.state {
        case .running: .accentColor
        case .success, .environmentSuccess, .expectedFailure: .green
        case .environmentFailure: .orange
        case .unexpectedFailure, .unexpectedSuccess: .red
        case .cancelled: .secondary
        }
    }
}
