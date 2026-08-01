import FoveaCore
import FoveaSwiftUI
import SwiftUI
import UIKit

/// 显示素材本身及其许可、伦理审核、来源和原始尺寸。
/// 网络图进入 Fovea 管线；随包图异步读取，禁止在 SwiftUI body 中执行文件 I/O。
struct WorkbenchRemoteAssetDetailView: View {
    @EnvironmentObject private var model: WorkbenchAppModel
    let asset: WorkbenchRemoteAsset

    @State private var revision = UUID()
    @State private var contentMode = WorkbenchContentMode.fit

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                WorkbenchImageSurface(
                    configuration: .detail(
                        assetAspectRatio: asset.aspectRatio,
                        contentMode: contentMode
                    )
                ) {
                    WorkbenchRemoteAssetImage(
                        asset: asset,
                        revision: revision,
                        contentMode: contentMode,
                        accessibilityIdentifier: "remote-detail.image"
                    )
                } overlay: {
                    sourceBadge
                        .padding(14)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(asset.title).font(.largeTitle.weight(.bold))
                    Text(asset.subtitle).foregroundColor(.secondary)
                }

                WorkbenchSectionCard(title: "亲眼比较显示行为") {
                    Picker("显示方式", selection: $contentMode) {
                        ForEach(WorkbenchContentMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(
                        contentMode == .fit
                            ? "完整显示会保留全部画面，容器可能出现留白。"
                            : "裁切填充会覆盖容器，但边缘内容可能不可见。"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 160), spacing: 10)],
                        spacing: 10
                    ) {
                        actionButtons
                    }
                }

                WorkbenchSectionCard(title: "图片来源与伦理说明") {
                    metadataRow("来源", asset.sourceTitle)
                    metadataRow("作者", asset.author)
                    metadataRow("许可", asset.license)
                    metadataRow(
                        "原始尺寸", "\(asset.originalPixelWidth) × \(asset.originalPixelHeight)")
                    Text(asset.ethicalReview)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Link(destination: asset.sourcePageURL) {
                        Label("查看原始来源页", systemImage: "safari")
                    }
                    Link(destination: asset.licenseURL) {
                        Label("查看许可条款", systemImage: "doc.text")
                    }
                }

                if asset.sourceKind == .remote {
                    WorkbenchSectionCard(title: "最近管线证据") {
                        WorkbenchEvidenceGrid(evidence: currentEvidence)
                        Text("回屏时应优先命中已渲染内存；内存清理后才回退到原编码磁盘缓存或网络。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    WorkbenchSectionCard(title: "本地素材边界") {
                        Text(
                            "这张图片随应用打包，由宿主直接读取并使用独立内存缓存。它用于展示真实项目中本地占位图、离线内容与网络图片并存的情况，不冒充 Fovea 网络管线证据。"
                        )
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(asset.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button {
            revision = UUID()
        } label: {
            Label("重新显示", systemImage: "arrow.clockwise")
                .lineLimit(1)
        }
        .buttonStyle(WorkbenchActionButtonStyle(.primary))

        Button {
            Task {
                await model.purgeMemory()
                revision = UUID()
            }
        } label: {
            Label("清内存再加载", systemImage: "memorychip")
                .lineLimit(1)
        }
        .buttonStyle(WorkbenchActionButtonStyle(.secondary))
    }

    private var sourceBadge: some View {
        Label(asset.sourceKind.title, systemImage: asset.sourceKind.symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private func metadataRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 16)
            Text(value)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
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
}

struct WorkbenchRemoteAssetImage: View {
    @EnvironmentObject private var model: WorkbenchAppModel

    let asset: WorkbenchRemoteAsset
    let revision: UUID
    let contentMode: WorkbenchContentMode
    var retentionMode: WorkbenchRetentionMode = .retainUntilReplacement
    var transitionDuration: Double = 0.16
    let accessibilityIdentifier: String

    var body: some View {
        Group {
            switch asset.sourceKind {
            case .remote:
                remoteImage
            case .bundled:
                bundledImage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.tertiarySystemFill))
        .clipped()
        .accessibilityIdentifier(accessibilityIdentifier)
        .id("\(asset.id):\(revision.uuidString.lowercased())")
    }

    @ViewBuilder
    private var remoteImage: some View {
        if let pipeline = model.pipeline {
            FoveaResponsiveImage(
                loader: pipeline,
                accessibility: .label(Text(asset.title)),
                contentMode: contentMode.value,
                geometryIsStable: true,
                loadingPolicy: FoveaImageLoadingPolicy(
                    // 内存和磁盘复用应在占位出现前完成；只有真实网络延迟才显示骨架。
                    placeholderDelayNanoseconds: 220_000_000,
                    retention: retentionMode.value
                ),
                transitionPolicy: FoveaImageTransitionPolicy(opacityDuration: transitionDuration)
            ) { target in
                try WorkbenchRequestFactory.makeRemoteAssetRequest(
                    asset: asset,
                    resolvedTarget: target,
                    configuration: model.activeConfiguration
                )
            } placeholder: {
                WorkbenchImagePlaceholder(symbol: asset.category.symbol)
            } failure: { context in
                WorkbenchFailureCard(context: context)
            }
        } else {
            WorkbenchImagePlaceholder(symbol: "hourglass")
        }
    }

    private var bundledImage: some View {
        WorkbenchBundledAssetImage(asset: asset, contentMode: contentMode)
    }
}

private struct WorkbenchBundledAssetImage: View {
    let asset: WorkbenchRemoteAsset
    let contentMode: WorkbenchContentMode

    @State private var image: UIImage?
    @State private var finishedLoading = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode == .fit ? .fit : .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .accessibilityLabel(asset.title)
            } else if finishedLoading {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("本地图片不可用")
                        .font(.caption.weight(.semibold))
                }
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WorkbenchImagePlaceholder(symbol: asset.category.symbol)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: asset.id) {
            finishedLoading = false
            image = await WorkbenchBundledImageCache.shared.image(for: asset)
            finishedLoading = true
        }
    }
}

private struct WorkbenchImagePlaceholder: View {
    let symbol: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.secondary.opacity(0.06), Color.secondary.opacity(0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: symbol)
                .font(.title2)
                .foregroundColor(.secondary.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

struct WorkbenchAboutRealNetworkView: View {
    var body: some View {
        List {
            Section("素材规模") {
                Label(
                    "\(WorkbenchRemoteAssetCatalog.remoteAssets.count) 张网络真实图片",
                    systemImage: "network")
                Label(
                    "\(WorkbenchRemoteAssetCatalog.bundledAssets.count) 张本地真实图片",
                    systemImage: "shippingbox")
                Label("按需分页显示并预取即将出现的内容", systemImage: "arrow.down.forward.circle")
            }
            Section("默认行为") {
                Label("普通启动使用真实 HTTPS 图片", systemImage: "network")
                Label("界面自动化和离线模式使用真实确定性素材", systemImage: "checkmark.shield")
                Label("第三方环境故障与核心回归分开判定", systemImage: "exclamationmark.triangle")
            }
            Section("许可与伦理") {
                Text(
                    "清单只接收 Wikimedia Commons 中明确标记为 CC0 或公有领域的文件，并拒绝动物性食物、狩猎捕鱼、动物圈养或表演、暴力、色情、医疗创伤和未成年人可识别肖像。许可允许使用并不自动代表内容适合示例，因此两项检查分别执行。"
                )
            }
            Section("缓存体验") {
                Text(
                    "首次网络加载可能出现骨架；成功后滚动回屏应直接命中已渲染内存缓存。清理内存后允许从原编码磁盘缓存恢复，只有缓存缺失、过期或显式网络实验才再次回源。"
                )
            }
        }
        .navigationTitle("素材与加载说明")
    }
}
