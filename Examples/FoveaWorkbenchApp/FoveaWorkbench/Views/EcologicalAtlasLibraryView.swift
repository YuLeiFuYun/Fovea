import SwiftUI

/// 专题库按卷和证据性质筛选，但筛选只改变可见集合，不改变专题或媒体缓存身份。
struct EcologicalStoryLibraryView: View {
    let document: EcologicalAtlasDocument
    @State private var selectedStatus: EcologicalEpistemicStatus?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("32 个专题")
                        .font(.largeTitle.weight(.bold))
                    Text("按八卷阅读，或使用证据性质筛选。筛选改变内容集合，不改变专题身份和图片缓存键。")
                        .foregroundColor(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterButton("全部", status: nil)
                        ForEach(EcologicalEpistemicStatus.allCases, id: \.self) { status in
                            filterButton(status.title, status: status)
                        }
                    }
                }

                ForEach(document.volumes) { volume in
                    let stories = filtered(document.stories(in: volume))
                    if !stories.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(String(format: "卷 %02d", volume.number))
                                        .font(.caption.weight(.bold).monospacedDigit())
                                        .foregroundColor(.secondary)
                                    Text(volume.title).font(.title2.weight(.bold))
                                }
                                Spacer()
                                NavigationLink("查看本卷") {
                                    EcologicalVolumeView(volume: volume, document: document)
                                }
                                .font(.caption.weight(.semibold))
                            }
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 270), spacing: 14)],
                                spacing: 14
                            ) {
                                ForEach(stories) { story in
                                    NavigationLink(
                                        destination: EcologicalStoryView(
                                            story: story,
                                            document: document
                                        )
                                    ) {
                                        EcologicalStoryCard(story: story, compact: true)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("ecology.library.\(story.id)")
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, WorkbenchDesign.compactHorizontalPadding)
            .padding(.vertical, WorkbenchDesign.sectionSpacing)
            .frame(maxWidth: WorkbenchDesign.regularContentWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("专题库")
        .accessibilityIdentifier("ecology.library.root")
    }

    private func filtered(_ stories: [EcologicalStory]) -> [EcologicalStory] {
        guard let selectedStatus else { return stories }
        return stories.filter { $0.epistemicStatus == selectedStatus }
    }

    private func filterButton(
        _ title: String,
        status: EcologicalEpistemicStatus?
    ) -> some View {
        Button(title) { selectedStatus = status }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .tint(selectedStatus == status ? .accentColor : .secondary)
    }
}

struct EcologicalVolumeView: View {
    let volume: EcologicalVolume
    let document: EcologicalAtlasDocument

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                EcologicalVolumeHeader(volume: volume)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 285), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(document.stories(in: volume)) { story in
                        NavigationLink(
                            destination: EcologicalStoryView(story: story, document: document)
                        ) {
                            EcologicalStoryCard(story: story)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("ecology.volume-story.\(story.id)")
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 1_100)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(volume.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("ecology.volume.root.\(volume.id)")
    }
}

struct EcologicalCaseStudiesView: View {
    let document: EcologicalAtlasDocument

    private var stories: [EcologicalStory] {
        document.caseStudyStoryIDs.compactMap { document.storiesByID[$0] }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                Text("具体系统案例")
                    .font(.largeTitle.weight(.bold))
                Text("案例不是“例子”附录。每个案例把地球系统状态、物质流、劳动、权力和制度选择放进同一页面。")
                    .foregroundColor(.secondary)
                ForEach(Array(stories.enumerated()), id: \.element.id) { index, story in
                    NavigationLink(
                        destination: EcologicalStoryView(story: story, document: document)
                    ) {
                        EcologicalCaseStudyCard(
                            story: story, imageOnLeadingEdge: index.isMultiple(of: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("案例集")
        .accessibilityIdentifier("ecology.cases.root")
    }
}

/// 案例卡交替图文方向以覆盖宽/窄窗口重排；图片 revision 在卡片生命周期内稳定。
private struct EcologicalCaseStudyCard: View {
    let story: EcologicalStory
    let imageOnLeadingEdge: Bool
    @State private var revision = UUID()

    private var asset: WorkbenchRemoteAsset {
        WorkbenchRemoteAssetCatalog.asset(id: story.heroAssetID)
            ?? WorkbenchRemoteAssetCatalog.featured
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 0)], spacing: 0) {
            if imageOnLeadingEdge { image }
            copy
            if !imageOnLeadingEdge { image }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private var image: some View {
        WorkbenchImageSurface(
            configuration: WorkbenchImageSurfaceConfiguration(
                aspectRatio: 4 / 3,
                contentMode: .fill,
                cornerRadius: 0
            )
        ) {
            WorkbenchRemoteAssetImage(
                asset: asset,
                revision: revision,
                contentMode: .fill,
                accessibilityIdentifier: "ecology.case.image.\(story.id)"
            )
        }
        .frame(minHeight: 230)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(story.eyebrow).font(.caption.weight(.bold)).foregroundColor(.secondary)
            Text(story.title).font(.title2.weight(.bold))
            Text(story.summary).foregroundColor(.secondary)
            EcologicalStatusBadge(status: story.epistemicStatus)
            Label(story.imageScenario.name, systemImage: "photo.on.rectangle.angled")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .leading)
    }
}

struct EcologicalSystemsMapView: View {
    let document: EcologicalAtlasDocument

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(document.volumes) { volume in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(format: "%02d", volume.number))
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundColor(.secondary)
                        Text(volume.title)
                            .font(.headline)
                            .frame(width: 210, alignment: .leading)
                        Text(volume.subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 210, alignment: .leading)
                        ForEach(document.stories(in: volume)) { story in
                            NavigationLink(
                                destination: EcologicalStoryView(story: story, document: document)
                            ) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(story.title).font(.subheadline.weight(.semibold))
                                    Text(story.epistemicStatus.title)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(10)
                                .frame(width: 210, alignment: .leading)
                                .background(
                                    Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 12)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(14)
                    .background(
                        Color(.systemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18)
                    )
                }
            }
            .padding(18)
        }
        .background(Color(.secondarySystemGroupedBackground).ignoresSafeArea())
        .navigationTitle("系统地图")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("ecology.map.root")
    }
}

struct EcologicalGlossaryView: View {
    let document: EcologicalAtlasDocument

    var body: some View {
        List(document.glossary) { entry in
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.term).font(.headline)
                Text(entry.definition).font(.subheadline).foregroundColor(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(entry.relatedStoryIDs, id: \.self) { storyID in
                            if let story = document.storiesByID[storyID] {
                                NavigationLink(story.title) {
                                    EcologicalStoryView(story: story, document: document)
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .frame(minHeight: 44)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 5)
        }
        .navigationTitle("概念索引")
        .accessibilityIdentifier("ecology.glossary.root")
    }
}

struct EcologicalSearchResultsView: View {
    let query: String
    let document: EcologicalAtlasDocument

    private var matches: [EcologicalStory] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return document.stories.filter { story in
            [
                story.title, story.summary, story.mechanism, story.distribution,
                story.debate.proposition, story.debate.challenge, story.debate.synthesis,
            ]
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("搜索结果 · \(matches.count)")
                    .font(.title2.weight(.bold))
                ForEach(matches) { story in
                    NavigationLink(
                        destination: EcologicalStoryView(story: story, document: document)
                    ) {
                        EcologicalStoryCard(story: story, compact: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ecology.search.\(story.id)")
                }
                if matches.isEmpty {
                    ContentUnavailableFallback(
                        title: "没有匹配专题",
                        detail: "尝试搜索资源、战争、动物、适应、城市、人工智能、增长或转型。"
                    )
                }
            }
            .padding(18)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("ecology.search.results")
    }
}

private struct ContentUnavailableFallback: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}
