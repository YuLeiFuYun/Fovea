import SwiftUI

/// 汇集主视觉大图、头像、聊天附件和商品卡片等常见产品图像模式。
/// 每个表面使用真实合规素材与独立目标尺寸，以验证同源多表征复用。
struct ProductPatternsLabView: View {
    @EnvironmentObject private var model: WorkbenchAppModel
    let lab: WorkbenchLab

    @State private var revision = UUID()
    @State private var actionMessage = "尚未执行宿主操作"

    private var primaryScenario: WorkbenchScenario {
        lab.scenarios.first ?? WorkbenchScenarioCatalog.fallback
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                WorkbenchLabHeader(lab: lab)
                hero
                avatarAndChat
                productGrid
                controls
                WorkbenchLatestRunCard(
                    record: model.latestRun(for: primaryScenario.id),
                    expected: [
                        WorkbenchExpectation("complete", title: "产品模式基础请求完成", rule: .completed),
                        WorkbenchExpectation(
                            "origin", title: "首次运行最多访问一个 origin", rule: .originAtMost(1)),
                        WorkbenchExpectation("cache", title: "缓存写入未降级", rule: .noCacheWriteFailure),
                    ]
                )
            }
            .padding(20)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle(lab.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("lab.product-patterns")
    }

    private var hero: some View {
        WorkbenchSectionCard(title: "详情主视觉 · 响应式大图") {
            WorkbenchRemoteAssetImage(
                asset: heroAsset,
                revision: revision,
                contentMode: model.activeConfiguration.contentMode,
                accessibilityIdentifier: "product.hero"
            )
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text(
                "\(heroAsset.originalPixelWidth) × \(heroAsset.originalPixelHeight) 的真实风景图按容器与 display scale 生成目标像素；详情页不应先分配无界全尺寸位图。"
            )
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    private var avatarAndChat: some View {
        WorkbenchSectionCard(title: "头像与聊天缩略图") {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 8) {
                    WorkbenchRemoteAssetImage(
                        asset: avatarAsset,
                        revision: revision,
                        contentMode: .fill,
                        accessibilityIdentifier: "product.avatar"
                    )
                    .frame(width: 76, height: 76)
                    .clipShape(Circle())
                    Text("圆形头像").font(.caption)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("图片消息")
                        .font(.subheadline.weight(.semibold))
                    WorkbenchRemoteAssetImage(
                        asset: chatAsset,
                        revision: revision,
                        contentMode: .fill,
                        accessibilityIdentifier: "product.chat-thumbnail"
                    )
                    .aspectRatio(4 / 3, contentMode: .fill)
                    .frame(maxWidth: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Text("真实动物照片作为消息缩略图；快速离开页面时取消订阅，重新进入后可从内存或磁盘恢复。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
    }

    private var productGrid: some View {
        WorkbenchSectionCard(title: "商品双列网格 · 同源多目标") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Array(gridAssets.enumerated()), id: \.element.id) { index, asset in
                    VStack(alignment: .leading, spacing: 7) {
                        WorkbenchRemoteAssetImage(
                            asset: asset,
                            revision: revision,
                            contentMode: index.isMultiple(of: 2) ? .fill : .fit,
                            accessibilityIdentifier: "product.grid.\(index)"
                        )
                        .aspectRatio(index.isMultiple(of: 2) ? 1 : 4 / 3, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text(asset.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(index.isMultiple(of: 2) ? "裁切填充 · 方形" : "完整显示 · 4:3")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Text("多种真实资源在头像、消息、主视觉与商品卡片中使用不同目标尺寸；重复进入页面时应复用正确的编码和渲染结果。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var controls: some View {
        WorkbenchSectionCard(title: "宿主操作") {
            WorkbenchActionStatus(message: actionMessage, identifier: "product.action-status")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                compactButton("重建视图", symbol: "arrow.clockwise", identifier: "product.rebuild") {
                    revision = UUID()
                    actionMessage = "产品图片视图已重新构建"
                }
                compactButton("运行证据", symbol: "play.fill", identifier: "product.run") {
                    if model.run(primaryScenario) != nil {
                        actionMessage = "产品模式证据运行已提交"
                    }
                }
                .disabled(!model.isReady)
                compactButton("清内存重载", symbol: "memorychip", identifier: "product.purge") {
                    Task {
                        await model.purgeMemory()
                        revision = UUID()
                        actionMessage = "内存图片已清空并重新加载"
                    }
                }
                .disabled(!model.isReady)
            }
        }
    }

    private func compactButton(
        _ title: String,
        symbol: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: WorkbenchDesign.controlMinimumHeight)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(identifier)
    }

    private var heroAsset: WorkbenchRemoteAsset {
        remoteAsset(in: .nature)
    }

    private var avatarAsset: WorkbenchRemoteAsset {
        remoteAsset(in: .portraits)
    }

    private var chatAsset: WorkbenchRemoteAsset {
        remoteAsset(in: .wildlife)
    }

    private var gridAssets: [WorkbenchRemoteAsset] {
        [.plantFood, .objects, .art, .plants].map(remoteAsset(in:))
    }

    private func remoteAsset(in category: WorkbenchRemoteAssetCategory) -> WorkbenchRemoteAsset {
        WorkbenchRemoteAssetCatalog.remoteAssets.first { $0.category == category }
            ?? WorkbenchRemoteAssetCatalog.featured
    }

}

struct SingleImageLabView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var model: WorkbenchAppModel
    let lab: WorkbenchLab

    @State private var selectedScenarioID: String
    @State private var selectedAssetID = WorkbenchRemoteAssetCatalog.featured.id
    @State private var selectedAssetCategory = WorkbenchRemoteAssetCatalog.featured.category
    @State private var selectedAssetSource = WorkbenchStudioSourceMode.remote
    @State private var contentMode = WorkbenchContentMode.fit
    @State private var retentionMode = WorkbenchRetentionMode.retainUntilReplacement
    @State private var revision = UUID()
    @State private var actionMessage = "尚未执行单图操作"

    init(lab: WorkbenchLab) {
        self.lab = lab
        _selectedScenarioID = State(initialValue: lab.scenarioIDs.first ?? "cacheable-image")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                WorkbenchLabHeader(lab: lab)
                visualExperiment
                protocolExperiment
                pageDiagnostics
            }
            .padding(20)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("single-image.scroll")
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(lab.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var visualExperiment: some View {
        WorkbenchSectionCard(title: "真实图片的显示几何") {
            Picker("来源", selection: $selectedAssetSource) {
                ForEach(WorkbenchStudioSourceMode.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)

            Picker("类别", selection: $selectedAssetCategory) {
                ForEach(WorkbenchRemoteAssetCategory.allCases) { category in
                    Label(category.title, systemImage: category.symbol).tag(category)
                }
            }
            .pickerStyle(.menu)

            Picker("图片", selection: $selectedAssetID) {
                ForEach(singleImageAssets) { asset in
                    Text(asset.title).tag(asset.id)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: selectedAssetCategory) { _ in selectFirstAvailableAsset() }
            .onChange(of: selectedAssetSource) { _ in selectFirstAvailableAsset() }

            WorkbenchRemoteAssetImage(
                asset: selectedAsset,
                revision: revision,
                contentMode: contentMode,
                retentionMode: retentionMode,
                transitionDuration: model.activeConfiguration.transitionDuration,
                accessibilityIdentifier: "single-image.preview"
            )
            .aspectRatio(
                contentMode == .fit ? selectedAsset.aspectRatio : 16 / 9, contentMode: .fit
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            if horizontalSizeClass == .regular {
                HStack(spacing: 16) {
                    geometryControls
                    Divider()
                    replacementControls
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    geometryControls
                    Divider()
                    replacementControls
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    revision = UUID()
                    actionMessage = "单图预览已重新显示"
                } label: {
                    Label("重新显示", systemImage: "arrow.clockwise")
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("single-image.rebuild")

                Text(
                    "\(selectedAsset.originalPixelWidth) × \(selectedAsset.originalPixelHeight) · \(selectedAsset.license)"
                )
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
            }
        }
    }

    private var geometryControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("裁切方式")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Picker("裁切方式", selection: $contentMode) {
                ForEach(WorkbenchContentMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("single-image.content-mode")
            Text(contentMode == .fit ? "完整显示图片，允许留白。" : "填满容器，边缘可能被裁切。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var replacementControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("身份替换时")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Picker("身份替换", selection: $retentionMode) {
                ForEach(WorkbenchRetentionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            Text(retentionModeDescription)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var protocolExperiment: some View {
        WorkbenchSectionCard(title: "确定性网络条件") {
            Text("下面的剧本使用内置确定性源站，专门验证慢响应、分块、缺失 MIME 和缓存语义；它们不替代上方的真实网络体验。")
                .font(.subheadline)
                .foregroundColor(.secondary)

            WorkbenchScenarioPicker(
                title: "响应条件",
                scenarios: lab.scenarios,
                selection: $selectedScenarioID
            )

            WorkbenchActionStatus(
                message: actionMessage,
                identifier: "single-image.action-status"
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(scenario.title).font(.subheadline.weight(.semibold))
                Text(scenario.summary).font(.caption).foregroundColor(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                Button {
                    if model.run(scenario) != nil {
                        actionMessage = "单次请求已提交，等待证据结果"
                    }
                } label: {
                    Label("运行一次", systemImage: "play.fill").lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isReady)
                .accessibilityIdentifier("single-image.run")

                Button {
                    if model.run(scenario, count: model.draftConfiguration.burstCount) != nil {
                        actionMessage = "并发请求已提交，等待共享证据"
                    }
                } label: {
                    Label(
                        "并发 \(model.draftConfiguration.burstCount)",
                        systemImage: "person.3.sequence.fill"
                    )
                    .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .disabled(!model.isReady)
                .accessibilityIdentifier("single-image.burst")
            }

            WorkbenchLatestRunCard(
                record: model.latestRun(for: scenario.id),
                expected: expectations
            )
        }
    }

    private var pageDiagnostics: some View {
        WorkbenchSectionCard(title: "判断标准") {
            VStack(alignment: .leading, spacing: 8) {
                judgment("目标像素", "预览只生成容器所需像素，不先解码完整原图。")
                judgment("慢响应", "先显示占位；完成后只发布完整 final。")
                judgment("分块响应", "中间字节不会成为跨请求可复用图片。")
                judgment("缺失 MIME", "允许依据安全探测成功，但必须记录响应异常。")
            }

            let recent = model.diagnosticEvents.suffix(6)
            if !recent.isEmpty {
                DisclosureGroup("最近的开发者事件") {
                    ForEach(Array(recent), id: \.sequence) { item in
                        Text(
                            "#\(item.sequence) \(item.event.kind.rawValue) \(item.event.reason ?? "")"
                        )
                        .font(.caption2.monospaced())
                        .lineLimit(2)
                    }
                    .padding(.top, 5)
                }
                .font(.caption.weight(.semibold))
            }
        }
    }

    private func judgment(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.circle")
                .foregroundColor(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var singleImageAssets: [WorkbenchRemoteAsset] {
        let categoryAssets = WorkbenchRemoteAssetCatalog.all.filter {
            $0.category == selectedAssetCategory
        }
        switch selectedAssetSource {
        case .remote:
            return categoryAssets.filter { $0.sourceKind == .remote }
        case .bundled:
            let local = categoryAssets.filter { $0.sourceKind == .bundled }
            return local.isEmpty ? WorkbenchRemoteAssetCatalog.bundledAssets : local
        case .mixed:
            return categoryAssets
        }
    }

    private func selectFirstAvailableAsset() {
        selectedAssetID = singleImageAssets.first?.id ?? WorkbenchRemoteAssetCatalog.featured.id
        revision = UUID()
    }

    private var selectedAsset: WorkbenchRemoteAsset {
        WorkbenchRemoteAssetCatalog.asset(id: selectedAssetID)
            ?? WorkbenchRemoteAssetCatalog.featured
    }

    private var scenario: WorkbenchScenario {
        WorkbenchScenarioCatalog.scenario(id: selectedScenarioID)
            ?? lab.scenarios.first
            ?? WorkbenchScenarioCatalog.fallback
    }

    private var expectations: [WorkbenchExpectation] {
        [
            WorkbenchExpectation("complete", title: "响应条件得到预期结果", rule: .completed),
            WorkbenchExpectation("origin", title: "单次运行最多访问一次 origin", rule: .originAtMost(1)),
            WorkbenchExpectation("cache", title: "缓存写入没有降级", rule: .noCacheWriteFailure),
        ]
    }

    private var retentionModeDescription: String {
        switch retentionMode {
        case .clearImmediately:
            "切换身份时立即清空旧图，适合私有内容。"
        case .retainUntilReplacement:
            "新图成功前保留旧图，减少普通内容的视觉闪烁。"
        }
    }
}
