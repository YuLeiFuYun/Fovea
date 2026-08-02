import FoveaCore
import SwiftUI

/// 用可重复步骤展示冷载、内存命中、磁盘命中、Vary 与 no-store。
/// 页面把预期、操作和实际证据分开，避免用户从动画速度推测缓存语义。
struct CacheIdentityLabView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var model: WorkbenchAppModel
    let lab: WorkbenchLab

    @State private var selectedScenarioID: String
    @State private var revision = UUID()
    @State private var completedStep = 0
    @State private var actionMessage = "尚未执行缓存验证"

    init(lab: WorkbenchLab) {
        self.lab = lab
        _selectedScenarioID = State(initialValue: lab.scenarioIDs.first ?? "no-store")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                WorkbenchLabHeader(lab: lab)
                conceptChooser
                experimentSteps
                resultArea
                cacheTimeline
            }
            .padding(20)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(lab.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("lab.cache-identity")
        .onChange(of: selectedScenarioID) { _ in
            completedStep = 0
            revision = UUID()
            actionMessage = "已切换缓存验证场景"
        }
    }

    private var conceptChooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("你想观察什么？")
                .font(.title3.weight(.bold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ForEach(lab.scenarios) { item in
                    Button {
                        selectedScenarioID = item.id
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: conceptSymbol(item))
                                .font(.title3)
                                .foregroundColor(
                                    item.id == selectedScenarioID ? .white : .accentColor
                                )
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conceptTitle(item))
                                    .font(.subheadline.weight(.semibold))
                                Text(conceptSummary(item))
                                    .font(.caption)
                                    .foregroundColor(
                                        item.id == selectedScenarioID
                                            ? .white.opacity(0.82) : .secondary
                                    )
                                    .lineLimit(3)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(13)
                        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                        .foregroundColor(item.id == selectedScenarioID ? .white : .primary)
                        .background(
                            item.id == selectedScenarioID
                                ? Color.accentColor : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("cache.case.\(item.id)")
                }
            }
        }
    }

    private var experimentSteps: some View {
        WorkbenchSectionCard(title: "按顺序验证") {
            if scenario.behavior == .vary {
                Picker("图片语言版本", selection: $model.draftConfiguration.varyLanguage) {
                    ForEach(WorkbenchVaryLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                Button("应用语言版本") {
                    Task {
                        await model.applyConfiguration()
                        actionMessage = "图片语言版本已应用"
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!model.hasUnappliedConfiguration)
                .accessibilityIdentifier("cache.apply-language")
            }

            WorkbenchActionStatus(message: actionMessage, identifier: "cache.action-status")

            HStack(alignment: .top, spacing: 8) {
                stepIndicator(number: 0, title: "重置")
                connector(completed: completedStep >= 1)
                stepIndicator(number: 1, title: "首次打开")
                connector(completed: completedStep >= 2)
                stepIndicator(number: 2, title: "再次打开")
            }

            Text(stepInstruction)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .accessibilityIdentifier("cache.instruction")

            HStack(spacing: 10) {
                Button {
                    Task {
                        await model.resetEvidence()
                        revision = UUID()
                        completedStep = 0
                        actionMessage = "缓存与诊断证据已重置"
                    }
                } label: {
                    Label("重置", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("cache.reset-evidence")

                Button {
                    if model.run(scenario) != nil {
                        completedStep = max(completedStep, 1)
                        actionMessage = "首次请求已提交，等待证据结果"
                    }
                } label: {
                    Label("首次打开", systemImage: "1.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isReady)
                .accessibilityIdentifier("cache.first-run")

                Button {
                    if model.run(scenario) != nil {
                        completedStep = 2
                        actionMessage = "第二次请求已提交，等待复用证据"
                    }
                } label: {
                    Label("再次打开", systemImage: "2.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isReady || completedStep < 1)
                .accessibilityIdentifier("cache.second-run")
            }
        }
    }

    @ViewBuilder
    private var resultArea: some View {
        if horizontalSizeClass == .regular {
            HStack(alignment: .top, spacing: 14) {
                previewCard
                latestEvidence
            }
        } else {
            VStack(spacing: 14) {
                previewCard
                latestEvidence
            }
        }
    }

    private var previewCard: some View {
        WorkbenchSectionCard(title: "用户看到的图片") {
            WorkbenchImagePreview(
                scenario: scenario,
                configuration: model.activeConfiguration,
                revision: revision,
                accessibilityIdentifier: "cache.preview"
            )
            Text(visualExpectation)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var latestEvidence: some View {
        WorkbenchLatestRunCard(
            record: model.latestRun(for: scenario.id),
            expected: expectations
        )
    }

    private var cacheTimeline: some View {
        WorkbenchSectionCard(title: "刚才发生了什么") {
            let events = relevantEvents
            if events.isEmpty {
                Text("完成一次请求后，这里会说明网络、内存、磁盘或再验证路径。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(events), id: \.sequence) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: eventSymbol(item.event.kind))
                            .foregroundColor(eventColor(item.event.kind))
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(eventTitle(item.event.kind))
                                .font(.subheadline.weight(.semibold))
                            HStack(spacing: 8) {
                                if let status = item.event.statusCode { Text("HTTP \(status)") }
                                if let reason = item.event.reason { Text(reason) }
                            }
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                        }
                        Spacer(minLength: 0)
                        Text("#\(item.sequence)")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var relevantEvents: ArraySlice<RecordedDiagnosticEvent> {
        model.diagnosticEvents.filter { event in
            switch event.event.kind {
            case .fetchStarted, .fetchJoined, .fetchCompleted, .originalEncodedHit,
                .renderedMemoryHit, .cacheWriteFailed, .responseAnomaly:
                true
            default:
                false
            }
        }.suffix(12)
    }

    private var scenario: WorkbenchScenario {
        WorkbenchScenarioCatalog.scenario(id: selectedScenarioID)
            ?? lab.scenarios.first
            ?? WorkbenchScenarioCatalog.fallback
    }

    private var expectations: [WorkbenchExpectation] {
        var values = [
            WorkbenchExpectation("complete", title: "图片行为符合选定策略", rule: .completed),
            WorkbenchExpectation("cache", title: "缓存写入没有降级", rule: .noCacheWriteFailure),
        ]
        switch scenario.behavior {
        case .noStore, .varyWildcard:
            values.append(
                WorkbenchExpectation("origin", title: "再次打开仍访问网络", rule: .originAtLeast(1))
            )
        case .revalidation:
            values.append(
                WorkbenchExpectation(
                    "304", title: "服务器确认缓存仍然有效", rule: .statusAtLeast(code: 304, count: 1))
            )
        default:
            values.append(
                WorkbenchExpectation("origin", title: "没有多余网络请求", rule: .originAtMost(1))
            )
        }
        return values
    }

    private func stepIndicator(number: Int, title: String) -> some View {
        VStack(spacing: 5) {
            Image(
                systemName: completedStep >= number ? "checkmark.circle.fill" : "\(number).circle"
            )
            .font(.title3)
            .foregroundColor(completedStep >= number ? .green : .secondary)
            Text(title)
                .font(.caption2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func connector(completed: Bool) -> some View {
        Rectangle()
            .fill(completed ? Color.green : Color.secondary.opacity(0.25))
            .frame(height: 2)
            .padding(.top, 10)
    }

    private var stepInstruction: String {
        switch completedStep {
        case 0: "先重置证据，再首次打开图片，建立可解释的冷启动基线。"
        case 1: secondStepInstruction
        default: "两次请求已提交。等待结果后，对照网络次数、缓存命中和 HTTP 状态。"
        }
    }

    private var secondStepInstruction: String {
        switch scenario.behavior {
        case .noStore: "再次打开时必须重新访问网络，因为响应禁止复用。"
        case .revalidation: "再次打开时发送条件请求，服务器可用 304 确认旧图片仍有效。"
        case .vary: "切换语言后得到另一版本；切回时应命中原来的对应版本。"
        case .varyWildcard: "服务器声明无法安全复用，再次打开必须重新访问网络。"
        default: "再次打开时应优先命中内存或磁盘，而不是重复下载。"
        }
    }

    private var visualExpectation: String {
        switch scenario.behavior {
        case .vary:
            "英文版与简体中文版代表两个可共存的图片版本，不能互相覆盖。"
        case .noStore, .varyWildcard:
            "图片仍能显示，但离开当前请求后不形成可供新请求使用的缓存命中。"
        case .revalidation:
            "再次打开不应闪烁或改变像素；协议层应出现 304。"
        default:
            scenario.summary
        }
    }

    private func conceptTitle(_ scenario: WorkbenchScenario) -> String {
        switch scenario.behavior {
        case .noStore: "每次都重新下载"
        case .revalidation: "确认缓存仍有效"
        case .vary: "同一地址的多个版本"
        case .varyWildcard: "服务器禁止安全复用"
        default: scenario.title
        }
    }

    private func conceptSummary(_ scenario: WorkbenchScenario) -> String {
        switch scenario.behavior {
        case .noStore: "适合敏感或一次性内容，显示成功但不留下跨请求缓存。"
        case .revalidation: "旧图片保留，服务器只确认是否变化，减少重复字节。"
        case .vary: "语言等请求字段决定实际图片版本，缓存必须正确分流。"
        case .varyWildcard: "响应无法形成稳定变体身份，必须保守地重新请求。"
        default: scenario.summary
        }
    }

    private func conceptSymbol(_ scenario: WorkbenchScenario) -> String {
        switch scenario.behavior {
        case .noStore: "eye.slash"
        case .revalidation: "arrow.triangle.2.circlepath"
        case .vary: "square.2.layers.3d"
        case .varyWildcard: "questionmark.folder"
        default: "externaldrive"
        }
    }

    private func eventTitle(_ kind: DiagnosticEventKind) -> String {
        switch kind {
        case .fetchStarted: "开始访问网络"
        case .fetchJoined: "加入已有网络任务"
        case .fetchCompleted: "网络获取完成"
        case .originalEncodedHit: "从磁盘读取原始图片"
        case .renderedMemoryHit: "从内存直接显示"
        case .cacheWriteFailed: "图片已显示，但缓存写入降级"
        case .responseAnomaly: "响应存在可解释异常"
        default: kind.rawValue
        }
    }

    private func eventSymbol(_ kind: DiagnosticEventKind) -> String {
        switch kind {
        case .fetchStarted, .fetchJoined, .fetchCompleted: "network"
        case .originalEncodedHit: "externaldrive"
        case .renderedMemoryHit: "memorychip"
        case .cacheWriteFailed: "externaldrive.badge.exclamationmark"
        case .responseAnomaly: "exclamationmark.triangle"
        default: "circle"
        }
    }

    private func eventColor(_ kind: DiagnosticEventKind) -> Color {
        switch kind {
        case .cacheWriteFailed, .responseAnomaly: .orange
        case .originalEncodedHit, .renderedMemoryHit: .green
        default: .blue
        }
    }
}
