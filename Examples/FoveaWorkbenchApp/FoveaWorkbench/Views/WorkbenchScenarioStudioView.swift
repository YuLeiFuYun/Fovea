import FoveaCore
import SwiftUI

/// 允许用户组合来源、布局、数量、预取和缓存操作的真实场景工坊。
/// 参数上限保护视图树与网络并发，实验动作均有可见过程说明。
struct WorkbenchScenarioStudioView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var model: WorkbenchAppModel

    @State private var pattern = WorkbenchExperiencePattern.socialFeed
    @State private var sourceMode = WorkbenchStudioSourceMode.mixed
    @State private var itemCount = 30
    @State private var columnCount = 2
    @State private var contentMode = WorkbenchContentMode.fill
    @State private var prefetchEnabled = true
    @State private var controlsExpanded = true
    @State private var revision = UUID()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    introduction
                    controls
                    processExplanation
                    WorkbenchPatternSurface(
                        pattern: pattern,
                        assets: selectedAssets,
                        columnCount: columnCount,
                        contentMode: contentMode,
                        revision: revision
                    )
                    .accessibilityIdentifier("studio.surface")
                    evidenceSummary
                }
                .padding(
                    .horizontal,
                    WorkbenchDesign.horizontalPadding(isRegular: horizontalSizeClass == .regular)
                )
                .padding(.vertical, WorkbenchDesign.sectionSpacing)
                .frame(maxWidth: WorkbenchDesign.regularContentWidth)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
        }
        .accessibilityIdentifier("studio.root")
        .navigationTitle("真实场景工坊")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: prefetchKey) {
            guard prefetchEnabled else { return }
            model.prefetchRemoteAssets(
                selectedAssets,
                estimatedConsumptionRate: 8,
                minimumCount: 8,
                maximumCount: 48
            )
            WorkbenchBundledImageCache.shared.prewarm(Array(selectedAssets.prefix(32)))
        }
        .onAppear { normalizeSelection() }
        .onChange(of: pattern) { _ in normalizeSelection() }
        .onChange(of: sourceMode) { _ in normalizeSelection() }
        .onChange(of: itemCount) { _ in revision = UUID() }
        .onChange(of: columnCount) { _ in revision = UUID() }
        .onChange(of: contentMode) { _ in revision = UUID() }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("交互式产品场景", systemImage: pattern.symbol)
                .font(.title2.weight(.bold))
            Text("选择真实应用形态和素材来源，然后亲眼观察首次加载、预取、滚动回屏、内存清理和不同裁切策略。这里不把协议术语当作使用说明。")
                .foregroundColor(.secondary)
        }
    }

    private var controls: some View {
        WorkbenchSectionCard(title: "你要怎样测试") {
            Menu {
                ForEach(WorkbenchExperiencePattern.allCases) { item in
                    Button {
                        pattern = item
                    } label: {
                        Label(item.title, systemImage: item.symbol)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Label(pattern.title, systemImage: pattern.symbol)
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: WorkbenchDesign.controlMinimumHeight,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("应用场景")
            .accessibilityValue(pattern.title)
            .accessibilityIdentifier("studio.pattern")

            Picker("素材来源", selection: $sourceMode) {
                ForEach(WorkbenchStudioSourceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: WorkbenchDesign.controlMinimumHeight)
            .accessibilityIdentifier("studio.source")

            DisclosureGroup("数量、布局与加载策略", isExpanded: $controlsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Stepper(
                        "显示图片：\(itemCount)",
                        value: $itemCount,
                        in: 8...maximumItemCount,
                        step: itemCount < 40 ? 4 : 10
                    )
                    Stepper("每行列数：\(columnCount)", value: $columnCount, in: 1...4)

                    Picker("显示方式", selection: $contentMode) {
                        ForEach(WorkbenchContentMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(minHeight: WorkbenchDesign.controlMinimumHeight)

                    Toggle("提前加载即将出现的网络图片", isOn: $prefetchEnabled)

                    Text(
                        "当前清单：\(WorkbenchRemoteAssetCatalog.remoteAssets.count) 张网络图片，\(WorkbenchRemoteAssetCatalog.bundledAssets.count) 张本地图片；本页使用其中 \(selectedAssets.count) 张。"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.top, 8)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180), spacing: 12)],
                spacing: 12
            ) {
                actionButton("重新显示", symbol: "arrow.clockwise") {
                    revision = UUID()
                }
                actionButton("清内存再看", symbol: "memorychip") {
                    Task {
                        await model.purgeMemory()
                        revision = UUID()
                    }
                }
                actionButton("预取当前内容", symbol: "arrow.down.circle") {
                    model.prefetchRemoteAssets(
                        selectedAssets,
                        estimatedConsumptionRate: 20,
                        minimumCount: min(selectedAssets.count, 16),
                        maximumCount: min(selectedAssets.count, 128)
                    )
                }
                actionButton("清空证据", symbol: "trash") {
                    Task { await model.resetEvidence() }
                }
            }
        }
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(WorkbenchActionButtonStyle(.secondary))
    }

    private var processExplanation: some View {
        WorkbenchSectionCard(title: "本次观察流程") {
            Label(pattern.summary, systemImage: "1.circle.fill")
            Label(
                prefetchEnabled
                    ? "进入页面后预取前 32 个网络资源；尚未出现的图片项不会全部抢占网络。"
                    : "关闭预取后，只有进入可见范围的图片项才发起请求。",
                systemImage: "2.circle.fill"
            )
            Label("首次成功后，回屏应先命中已渲染内存缓存，不再显示旋转加载状态。", systemImage: "3.circle.fill")
            Label("清内存后允许从原编码磁盘缓存恢复；只有缓存不存在或失效才回源。", systemImage: "4.circle.fill")
        }
        .font(.subheadline)
    }

    private var evidenceSummary: some View {
        WorkbenchSectionCard(title: "当前会话结果") {
            WorkbenchEvidenceGrid(evidence: currentEvidence)
            HStack {
                Label(
                    "已预取 \(model.prefetchedRemoteAssetCount) · 建议窗口 \(model.recommendedPrefetchCount)",
                    systemImage: "arrow.down.circle"
                )
                Spacer()
                Label(model.network.pathTitle, systemImage: model.network.symbol)
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    private var currentEvidence: WorkbenchRunEvidence {
        var evidence = WorkbenchRunEvidence()
        evidence.originRequests = model.originRequestCounts.values.reduce(0, +)
        evidence.eventCounts = Dictionary(
            grouping: model.diagnosticEvents.map(\.event),
            by: \.kind
        ).mapValues(\.count)
        evidence.statusCounts = Dictionary(
            grouping: model.diagnosticEvents.compactMap(\.event.statusCode),
            by: { $0 }
        ).mapValues(\.count)
        return evidence
    }

    private var selectedAssets: [WorkbenchRemoteAsset] {
        Array(availableAssets.prefix(itemCount))
    }

    private var availableAssets: [WorkbenchRemoteAsset] {
        let categories = pattern.preferredCategories
        let remote = WorkbenchRemoteAssetCatalog.remoteAssets.filter {
            categories.contains($0.category)
        }
        let bundled = WorkbenchRemoteAssetCatalog.bundledAssets.filter {
            categories.contains($0.category)
        }
        switch sourceMode {
        case .remote:
            return remote
        case .bundled:
            return bundled
        case .mixed:
            var output: [WorkbenchRemoteAsset] = []
            var remoteIndex = 0
            var bundledIndex = 0
            while remoteIndex < remote.count || bundledIndex < bundled.count {
                if bundledIndex < bundled.count, output.count.isMultiple(of: 5) {
                    output.append(bundled[bundledIndex])
                    bundledIndex += 1
                } else if remoteIndex < remote.count {
                    output.append(remote[remoteIndex])
                    remoteIndex += 1
                } else if bundledIndex < bundled.count {
                    output.append(bundled[bundledIndex])
                    bundledIndex += 1
                }
            }
            return output
        }
    }

    private var maximumItemCount: Int {
        max(8, min(200, availableAssets.count))
    }

    private var prefetchKey: String {
        "\(pattern.rawValue):\(sourceMode.rawValue):\(itemCount):\(prefetchEnabled):\(revision)"
    }

    private func normalizeSelection() {
        itemCount = min(itemCount, maximumItemCount)
        revision = UUID()
    }
}
