import SwiftUI

/// Workbench 的大众入口：先用完整生态叙事承载真实图片，再进入工程验证。
struct EcologicalAtlasHomeView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let document = EcologicalAtlasDocument.current
    @State private var searchText = ""

    private var featuredStories: [EcologicalStory] {
        document.featuredStoryIDs.compactMap { document.storiesByID[$0] }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    hero
                    navigationDeck
                    featuredRail
                    volumeIndex
                    caseStudies
                    evidencePrimer
                    laboratoryEntry
                    reviewNotice
                }
                .padding(
                    .horizontal,
                    WorkbenchDesign.horizontalPadding(isRegular: horizontalSizeClass == .regular)
                )
                .padding(.vertical, WorkbenchDesign.sectionSpacing)
                .frame(maxWidth: WorkbenchDesign.regularContentWidth)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("生态图谱")
            .searchable(text: $searchText, prompt: "搜索议题、机制或争论")
            .overlay(searchOverlay)
        }
        .navigationViewStyle(.stack)
        .accessibilityIdentifier("ecology.root")
    }

    private var hero: some View {
        let story = featuredStories.first ?? document.stories[0]
        let asset =
            WorkbenchRemoteAssetCatalog.asset(id: story.heroAssetID)
            ?? WorkbenchRemoteAssetCatalog.featured
        return WorkbenchImageSurface(
            configuration: WorkbenchImageSurfaceConfiguration(
                aspectRatio: horizontalSizeClass == .regular ? 16 / 7 : 4 / 3,
                contentMode: .fill,
                cornerRadius: 26
            )
        ) {
            WorkbenchRemoteAssetImage(
                asset: asset,
                revision: UUID(uuidString: "499E4F5D-1265-4D26-A06B-98BB5FA940B8") ?? UUID(),
                contentMode: .fill,
                accessibilityIdentifier: "ecology.hero.image"
            )
        } overlay: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.84)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 12) {
                    Text("Fovea 生态图谱")
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                    Text(document.title)
                        .font(.system(size: 39, weight: .bold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(document.deck)
                        .font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 9) {
                        heroMetric(document.volumes.count, "卷")
                        heroMetric(document.stories.count, "专题")
                        heroMetric(
                            Set(document.stories.flatMap { [$0.heroAssetID] + $0.galleryAssetIDs })
                                .count,
                            "图像身份"
                        )
                        heroMetric(document.sources.count, "来源")
                    }
                }
                .foregroundColor(.white)
                .padding(22)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ecology.hero")
    }

    private var navigationDeck: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
            NavigationLink(destination: EcologicalStoryLibraryView(document: document)) {
                navigationCard("全部专题", "按卷、证据性质和页面形态浏览", "books.vertical")
            }
            .accessibilityIdentifier("ecology.open-library")
            NavigationLink(destination: EcologicalCaseStudiesView(document: document)) {
                navigationCard("案例集", "从污染、战争、城市和劳动进入", "square.grid.2x2")
            }
            .accessibilityIdentifier("ecology.open-cases")
            NavigationLink(destination: EcologicalGlossaryView(document: document)) {
                navigationCard("概念索引", "避免把相近术语压成口号", "text.book.closed")
            }
            .accessibilityIdentifier("ecology.open-glossary")
            NavigationLink(destination: EcologicalSystemsMapView(document: document)) {
                navigationCard("系统地图", "查看议题之间的跨卷连接", "point.3.connected.trianglepath.dotted")
            }
            .accessibilityIdentifier("ecology.open-map")
            NavigationLink(destination: EcologicalMethodologyView(document: document)) {
                navigationCard("方法与来源", "核查证据标签、资料边界与复核日期", "checkmark.seal")
            }
            .accessibilityIdentifier("ecology.methodology")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ecology.navigation-deck")
    }

    /// 横向入口使用 LazyHStack，避免首页一次构造所有详情媒体；专题身份不包含滚动位置。
    private var featuredRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("从这里开始", subtitle: "八个入口覆盖诊断、代谢、生命、正义、战争、日常、争论与治理")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 15) {
                    ForEach(featuredStories) { story in
                        NavigationLink(
                            destination: EcologicalStoryView(story: story, document: document)
                        ) {
                            EcologicalStoryCard(story: story, compact: true)
                                .frame(width: 278)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("ecology.featured.\(story.id)")
                    }
                }
            }
        }
    }

    private var volumeIndex: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("八卷结构", subtitle: "不是三十二张平铺卡片，而是八条彼此交叉的因果路径")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), spacing: 16)], spacing: 16) {
                ForEach(document.volumes) { volume in
                    NavigationLink(
                        destination: EcologicalVolumeView(volume: volume, document: document)
                    ) {
                        EcologicalVolumeCard(
                            volume: volume,
                            story: document.stories(in: volume).first ?? document.stories[0]
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ecology.volume.\(volume.id)")
                }
            }
        }
    }

    private var caseStudies: some View {
        let stories = document.caseStudyStoryIDs.compactMap { document.storiesByID[$0] }
        return VStack(alignment: .leading, spacing: 14) {
            sectionHeader("穿过具体系统", subtitle: "从一条供应链、一次冲突或一项基础设施决策观察多重后果")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                ForEach(stories.prefix(6)) { story in
                    NavigationLink(
                        destination: EcologicalStoryView(story: story, document: document)
                    ) {
                        EcologicalStoryCard(story: story, compact: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var evidencePrimer: some View {
        WorkbenchSectionCard(title: "一条结论应当怎样被阅读") {
            Text("每个专题强制区分因果机制、分配后果、主张、反对意见和综合判断。证据标签说明结论属于评估共识、观测、模型、理论、价值立场还是仍有争议的证据。")
                .foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(EcologicalEpistemicStatus.allCases, id: \.self) { status in
                        EcologicalStatusBadge(status: status)
                    }
                }
            }
        }
    }

    private var laboratoryEntry: some View {
        WorkbenchSectionCard(title: "把内容变成真实图片压力场景") {
            Text("三十二个专题使用八种页面形态、160 个稳定媒体身份和本地/网络混合来源。完整图库、场景工坊和 2,000 项高压信息流仍作为二级工程实验场。")
                .foregroundColor(.secondary)
            NavigationLink(destination: WorkbenchDiscoverView()) {
                Label("打开 Fovea 图片实验场", systemImage: "photo.stack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(WorkbenchActionButtonStyle(.primary))
            .accessibilityIdentifier("ecology.open-workbench")
        }
    }

    private var reviewNotice: some View {
        Text("资料复核日期：\(document.reviewedAt)。专题保留原始来源和争议边界；内容更新必须通过数据契约与界面回归。")
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var searchOverlay: some View {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EcologicalSearchResultsView(query: searchText, document: document)
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
        }
    }

    private func heroMetric(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value.formatted()).font(.headline.monospacedDigit())
            Text(label).font(.caption2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func navigationCard(_ title: String, _ subtitle: String, _ symbol: String) -> some View
    {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.bold))
            Text(subtitle).font(.subheadline).foregroundColor(.secondary)
        }
    }
}

private struct EcologicalVolumeCard: View {
    let volume: EcologicalVolume
    let story: EcologicalStory
    @State private var revision = UUID()

    private var asset: WorkbenchRemoteAsset {
        WorkbenchRemoteAssetCatalog.asset(id: story.heroAssetID)
            ?? WorkbenchRemoteAssetCatalog.featured
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkbenchImageSurface(
                configuration: WorkbenchImageSurfaceConfiguration(
                    aspectRatio: 16 / 9,
                    contentMode: .fill,
                    cornerRadius: 0
                )
            ) {
                WorkbenchRemoteAssetImage(
                    asset: asset,
                    revision: revision,
                    contentMode: .fill,
                    accessibilityIdentifier: "ecology.volume.image.\(volume.id)"
                )
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(String(format: "卷 %02d · %d 个专题", volume.number, volume.storyIDs.count))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundColor(.secondary)
                Text(volume.title).font(.title3.weight(.bold))
                Text(volume.subtitle).font(.subheadline.weight(.semibold))
                Text(volume.summary).font(.caption).foregroundColor(.secondary).lineLimit(4)
            }
            .padding(15)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
