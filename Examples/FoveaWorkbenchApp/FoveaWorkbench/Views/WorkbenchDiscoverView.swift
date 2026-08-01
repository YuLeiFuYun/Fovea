import SwiftUI

/// 真实素材首页：通过来源、类别、搜索和分页控制大目录的视图规模。
/// 下一窗口预取有硬上限，不能因滚动把全部远程目录同时送入管线。
struct WorkbenchDiscoverView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var model: WorkbenchAppModel

    @State private var selectedCategory: WorkbenchRemoteAssetCategory?
    @State private var selectedSource: WorkbenchMediaSourceKind?
    @State private var query = ""
    @State private var visibleLimit = 48
    @State private var revision = UUID()

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    introduction
                    featuredExperience
                    scenarioEntry
                    catalogSummary
                    filterControls
                    realImageGallery
                    evidencePrimer
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 18)
                .frame(maxWidth: WorkbenchDesign.regularContentWidth)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Fovea 图片实验场")
            .searchable(text: $query, prompt: "搜索图片、作者或类别")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        revision = UUID()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("重新构造可见图片视图")
                    .accessibilityIdentifier("discover.reload")

                    NavigationLink(destination: WorkbenchAboutRealNetworkView()) {
                        Image(systemName: "info.circle")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("素材、缓存与伦理说明")
                }
            }
        }
        .navigationViewStyle(.stack)
        .accessibilityIdentifier("discover.root")
        .onChange(of: query) { _ in resetPagination() }
        .onChange(of: selectedCategory) { _ in resetPagination() }
        .onChange(of: selectedSource) { _ in resetPagination() }
        .task(id: prefetchKey) {
            model.prefetchRemoteAssets(
                filteredAssets,
                estimatedConsumptionRate: 10,
                minimumCount: 12,
                maximumCount: 72
            )
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                model.activeConfiguration.externalNetworkingEnabled ? "真实网络与本地混合体验" : "确定性离线替身",
                systemImage: model.activeConfiguration.externalNetworkingEnabled
                    ? "network" : "wifi.slash"
            )
            .font(.caption.weight(.semibold))
            .foregroundColor(model.activeConfiguration.externalNetworkingEnabled ? .green : .orange)

            Text("先体验真实图片产品，再进入协议验证。")
                .font(
                    .system(
                        size: horizontalSizeClass == .regular ? 36 : 30, weight: .bold,
                        design: .rounded)
                )
                .fixedSize(horizontal: false, vertical: true)

            Text("这里包含数百张有来源、许可和伦理审查记录的真实图片。首次网络加载后，滚动回屏应优先命中内存；本地素材则随应用立即可用。")
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var featuredExperience: some View {
        NavigationLink(
            destination: WorkbenchRemoteAssetDetailView(asset: WorkbenchRemoteAssetCatalog.featured)
        ) {
            WorkbenchImageSurface(
                configuration: WorkbenchImageSurfaceConfiguration(
                    aspectRatio: horizontalSizeClass == .regular ? 16 / 7 : 4 / 3,
                    contentMode: .fill,
                    cornerRadius: 24
                )
            ) {
                WorkbenchRemoteAssetImage(
                    asset: WorkbenchRemoteAssetCatalog.featured,
                    revision: revision,
                    contentMode: .fill,
                    accessibilityIdentifier: "discover.featured-image"
                )
            } overlay: {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.78)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    VStack(alignment: .leading, spacing: 5) {
                        Text("真实网络主图")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white.opacity(0.82))
                        Text(WorkbenchRemoteAssetCatalog.featured.title)
                            .font(.title2.weight(.bold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                        Text("目标像素、重定向、内存回屏与磁盘恢复")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.86))
                    }
                    .padding(20)
                }
            }
            .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("discover.featured")
    }

    private var scenarioEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(
                title: "按真实任务测试",
                subtitle: "先选择应用形态，再调整来源、数量、列数、裁切和预取。"
            )

            LazyVGrid(columns: journeyColumns, spacing: 14) {
                journeyCard(
                    title: "真实场景工坊",
                    detail: "11 类主流场景、网络/本地/混合源、最多 200 张可交互图片。",
                    symbol: "apps.iphone",
                    destination: WorkbenchScenarioStudioView(),
                    identifier: "discover.journey.studio"
                )
                journeyCard(
                    title: "高压滚动与复用",
                    detail: "SwiftUI / UIKit、脚本滚动、离屏取消、数百资产和内存指标。",
                    symbol: "rectangle.stack.badge.play",
                    destination: FeedStressView(
                        scenario: WorkbenchScenarioCatalog.scenario(id: "scrolling-feed-lab")
                            ?? WorkbenchScenarioCatalog.fallback,
                        initialLayout: .grid
                    ),
                    identifier: "discover.journey.feed"
                )
                journeyCard(
                    title: "缓存与离线恢复",
                    detail: "首次网络、内存回屏、磁盘恢复、304、no-store 与仅缓存失败。",
                    symbol: "externaldrive.badge.checkmark",
                    destination: CacheIdentityLabView(
                        lab: WorkbenchLabCatalog.lab(id: "cache-identity")
                            ?? WorkbenchLabCatalog.all[0]
                    ),
                    identifier: "discover.journey.cache"
                )
            }
        }
    }

    private var catalogSummary: some View {
        HStack(spacing: 12) {
            summaryMetric(
                value: WorkbenchRemoteAssetCatalog.remoteAssets.count,
                title: "网络图片",
                symbol: "network"
            )
            summaryMetric(
                value: WorkbenchRemoteAssetCatalog.bundledAssets.count,
                title: "本地图片",
                symbol: "shippingbox"
            )
            summaryMetric(
                value: WorkbenchRemoteAssetCategory.allCases.count,
                title: "内容类别",
                symbol: "square.grid.2x2"
            )
        }
    }

    private func summaryMetric(value: Int, title: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(String(value), systemImage: symbol)
                .font(.title3.monospacedDigit().weight(.bold))
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 15))
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    sourceButton(title: "全部来源", symbol: "square.stack.3d.up", source: nil)
                    ForEach(WorkbenchMediaSourceKind.allCases) { source in
                        sourceButton(title: source.title, symbol: source.symbol, source: source)
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    categoryButton(title: "全部类别", symbol: "square.grid.2x2", category: nil)
                    ForEach(WorkbenchRemoteAssetCategory.allCases) { category in
                        categoryButton(
                            title: category.title, symbol: category.symbol, category: category)
                    }
                }
            }
        }
    }

    private var realImageGallery: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(
                title: "真实媒体目录",
                subtitle: "找到 \(filteredAssets.count) 项；当前显示 \(visibleAssets.count) 项，滚动到底部继续加载。"
            )

            if visibleAssets.isEmpty {
                ContentUnavailableViewCompat(
                    title: "没有匹配图片",
                    message: "调整搜索词、来源或类别。",
                    symbol: "magnifyingglass"
                )
            } else {
                LazyVGrid(columns: galleryColumns, spacing: 16) {
                    ForEach(Array(visibleAssets.enumerated()), id: \.element.id) { index, asset in
                        NavigationLink(destination: WorkbenchRemoteAssetDetailView(asset: asset)) {
                            WorkbenchRemoteAssetCard(asset: asset, revision: revision)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("discover.asset-index.\(index)")
                        .accessibilityValue(asset.id)
                        .onAppear {
                            guard index >= visibleAssets.count - 8 else { return }
                            loadNextPage()
                        }
                    }
                }

                if visibleAssets.count < filteredAssets.count {
                    Button {
                        loadNextPage()
                    } label: {
                        Label("继续加载", systemImage: "arrow.down.circle")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("discover.load-more")
                }
            }
        }
    }

    private var evidencePrimer: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text("回屏流畅也必须有因果证据")
                    .font(.headline)
                Text("内存命中、原编码磁盘恢复、网络回源、同请求合并、取消和失败会分别记录。视觉上看起来快，不等于可以省略证据。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(18)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func sourceButton(
        title: String,
        symbol: String,
        source: WorkbenchMediaSourceKind?
    ) -> some View {
        filterButton(title: title, symbol: symbol, selected: selectedSource == source) {
            selectedSource = source
        }
    }

    private func categoryButton(
        title: String,
        symbol: String,
        category: WorkbenchRemoteAssetCategory?
    ) -> some View {
        filterButton(title: title, symbol: symbol, selected: selectedCategory == category) {
            selectedCategory = category
        }
    }

    private func filterButton(
        title: String,
        symbol: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(
                    selected ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule()
                )
                .foregroundColor(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func sectionHeading(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.bold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private func journeyCard<Destination: View>(
        title: String,
        detail: String,
        symbol: String,
        destination: Destination,
        identifier: String
    ) -> some View {
        NavigationLink(destination: destination) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundColor(.accentColor)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private var filteredAssets: [WorkbenchRemoteAsset] {
        WorkbenchRemoteAssetCatalog.assets(
            category: selectedCategory,
            sourceKind: selectedSource,
            query: query
        )
    }

    private var visibleAssets: [WorkbenchRemoteAsset] {
        Array(filteredAssets.prefix(visibleLimit))
    }

    private var galleryColumns: [GridItem] {
        horizontalSizeClass == .regular
            ? [GridItem(.adaptive(minimum: 220), spacing: 16)]
            : [GridItem(.flexible()), GridItem(.flexible())]
    }

    private var journeyColumns: [GridItem] {
        [GridItem(.adaptive(minimum: horizontalSizeClass == .regular ? 270 : 300), spacing: 14)]
    }

    private var horizontalPadding: CGFloat {
        horizontalSizeClass == .regular ? 28 : 16
    }

    private var prefetchKey: String {
        "\(selectedCategory?.rawValue ?? "all"):\(selectedSource?.rawValue ?? "all"):\(query):\(visibleLimit)"
    }

    private func resetPagination() {
        visibleLimit = 48
    }

    private func loadNextPage() {
        let next = min(filteredAssets.count, visibleLimit + 48)
        guard next > visibleLimit else { return }
        visibleLimit = next
        model.prefetchRemoteAssets(
            Array(filteredAssets.prefix(next + 96)),
            estimatedConsumptionRate: 10,
            minimumCount: 12,
            maximumCount: 72
        )
    }
}

private struct WorkbenchRemoteAssetCard: View {
    let asset: WorkbenchRemoteAsset
    let revision: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkbenchImageSurface(
                configuration: WorkbenchImageSurfaceConfiguration(
                    aspectRatio: 4 / 3,
                    contentMode: .fill,
                    cornerRadius: 15
                )
            ) {
                WorkbenchRemoteAssetImage(
                    asset: asset,
                    revision: revision,
                    contentMode: .fill,
                    accessibilityIdentifier: "discover.asset-image.\(asset.id)"
                )
            } overlay: {
                Label(asset.sourceKind.title, systemImage: asset.sourceKind.symbol)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(7)
            }

            Text(asset.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(asset.category.title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(9)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 19))
    }
}

/// iOS 15 兼容的空状态，避免为了视觉便利抬高最低系统版本。
private struct ContentUnavailableViewCompat: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.largeTitle).foregroundColor(.secondary)
            Text(title).font(.headline)
            Text(message).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(36)
    }
}
