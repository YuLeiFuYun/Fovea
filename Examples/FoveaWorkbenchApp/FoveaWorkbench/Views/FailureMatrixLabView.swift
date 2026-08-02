import SwiftUI

/// 按用户后果组织网络、内容、安全和资源失败，而非按内部错误枚举排列。
/// 每个案例同时说明公开原因码、恢复动作以及是否允许缓存状态变化。
struct FailureMatrixLabView: View {
    @EnvironmentObject private var model: WorkbenchAppModel
    let lab: WorkbenchLab

    @State private var selectedFamily = FailureFamily.server
    @State private var selectedScenarioID: String

    init(lab: WorkbenchLab) {
        self.lab = lab
        _selectedScenarioID = State(initialValue: lab.scenarioIDs.first ?? "http-404")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                WorkbenchLabHeader(lab: lab)
                principle
                familyPicker
                caseList
                selectedCase
                WorkbenchLatestRunCard(
                    record: model.latestRun(for: scenario.id),
                    expected: expectations
                )
            }
            .padding(20)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(lab.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("lab.failure-matrix")
        .onChange(of: selectedFamily) { family in
            if let first = scenarios(in: family).first {
                selectedScenarioID = first.id
            }
        }
    }

    private var principle: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "cross.case.fill")
                .font(.title2)
                .foregroundColor(.orange)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("失败必须可解释、可恢复且不污染缓存")
                    .font(.headline)
                Text("页面没有崩溃只是最低要求。真正的成功标准是：用户看到合理反馈，管线给出稳定分类，重试边界明确，错误内容不进入可复用状态。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
    }

    private var familyPicker: some View {
        Picker("故障类别", selection: $selectedFamily) {
            ForEach(FailureFamily.allCases) { family in
                Text(family.title).tag(family)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("failure.family")
    }

    private var caseList: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
            ForEach(scenarios(in: selectedFamily)) { item in
                Button {
                    selectedScenarioID = item.id
                } label: {
                    HStack(alignment: .top, spacing: 11) {
                        Image(
                            systemName: selectedScenarioID == item.id
                                ? "checkmark.circle.fill" : itemSymbol(item)
                        )
                        .foregroundColor(selectedScenarioID == item.id ? .accentColor : .orange)
                        .frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.primary)
                            Text(userImpact(item))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                    .background(
                        selectedScenarioID == item.id
                            ? Color.accentColor.opacity(0.10) : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 15)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(
                                selectedScenarioID == item.id
                                    ? Color.accentColor.opacity(0.5)
                                    : Color.secondary.opacity(0.12),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("failure.case.\(item.id)")
            }
        }
    }

    private var selectedCase: some View {
        WorkbenchSectionCard(title: "本次验证") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(scenario.title).font(.title3.weight(.bold))
                        Text(scenario.summary).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button("执行") { _ = model.run(scenario) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.isReady)
                        .accessibilityIdentifier("failure.run")
                }

                Divider()
                expectedRow("用户结果", value: expectedUserResult)
                expectedRow("结构化契约", value: scenario.expectedOutcome.title)
                expectedRow("缓存影响", value: expectedCacheResult)
            }
        }
    }

    private func expectedRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(.caption)
            Spacer(minLength: 0)
        }
    }

    private var scenario: WorkbenchScenario {
        WorkbenchScenarioCatalog.scenario(id: selectedScenarioID)
            ?? scenarios(in: selectedFamily).first
            ?? WorkbenchScenarioCatalog.fallback
    }

    private func scenarios(in family: FailureFamily) -> [WorkbenchScenario] {
        lab.scenarios.filter { family.includes($0) }
    }

    private var expectations: [WorkbenchExpectation] {
        switch scenario.expectedOutcome {
        case .failure(let reason):
            [WorkbenchExpectation("reason", title: "失败原因与公开契约一致", rule: .expectedFailure(reason))]
        case .success, .environmentDependent:
            [WorkbenchExpectation("complete", title: "结果符合场景契约", rule: .completed)]
        }
    }

    private func itemSymbol(_ scenario: WorkbenchScenario) -> String {
        switch selectedFamily {
        case .server: "server.rack"
        case .content: "photo.badge.exclamationmark"
        case .policy: "hand.raised.fill"
        }
    }

    private func userImpact(_ scenario: WorkbenchScenario) -> String {
        switch scenario.id {
        case "http-404": "资源不存在；展示稳定失败，不应无意义重试。"
        case "http-500": "服务器暂时故障；允许有限重试，最终仍需明确失败。"
        case "incomplete-body": "下载被截断；不得发布半张图或半缓存。"
        case "wrong-mime": "服务返回网页而不是图片；在解码前拒绝。"
        case "corrupt-image": "内容已损坏；探测失败且不能污染缓存。"
        case "empty-image-body": "响应成功但没有图片字节；失败关闭。"
        case "oversized-body": "资源超出预算；在大分配前终止。"
        case "cache-only-miss": "离线模式没有缓存；不访问网络。"
        case "destination-denied": "目标站点不在许可范围；缓存和网络前拒绝。"
        default: scenario.summary
        }
    }

    private var expectedUserResult: String {
        switch selectedFamily {
        case .server: "显示可重试或终止的网络错误，不展示旧请求的迟到图片。"
        case .content: "显示内容不可用，不把错误页或损坏字节当作图片。"
        case .policy: "明确说明离线或权限限制，不偷偷扩大网络访问。"
        }
    }

    private var expectedCacheResult: String {
        switch scenario.id {
        case "http-500", "http-404", "wrong-mime", "corrupt-image", "empty-image-body",
            "oversized-body", "incomplete-body":
            "不发布新的可复用图片记录"
        case "cache-only-miss", "destination-denied":
            "不读取越权记录，也不写入任何新状态"
        default:
            "按结构化失败策略处理"
        }
    }
}

private enum FailureFamily: String, CaseIterable, Identifiable {
    case server
    case content
    case policy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .server: "网络与服务"
        case .content: "内容安全"
        case .policy: "离线与权限"
        }
    }

    func includes(_ scenario: WorkbenchScenario) -> Bool {
        switch self {
        case .server:
            return ["http-404", "http-500", "incomplete-body"].contains(scenario.id)
        case .content:
            return ["wrong-mime", "corrupt-image", "empty-image-body", "oversized-body"]
                .contains(scenario.id)
        case .policy:
            return ["cache-only-miss", "destination-denied"].contains(scenario.id)
        }
    }
}
