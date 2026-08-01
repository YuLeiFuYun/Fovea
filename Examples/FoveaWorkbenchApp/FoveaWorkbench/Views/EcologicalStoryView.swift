import SwiftUI

/// 单专题阅读容器：内容证据与图片实验共享滚动生命周期，但来源身份和重载 token 保持分离。
struct EcologicalStoryView: View {
    @EnvironmentObject private var model: WorkbenchAppModel

    let story: EcologicalStory
    let document: EcologicalAtlasDocument
    let contractFirstForUITesting: Bool

    @State private var reloadToken = UUID()
    @State private var contentMode = WorkbenchContentMode.fill
    @State private var showsImageContract = false
    @State private var imageActionMessage = "尚未执行专题图片操作"

    init(
        story: EcologicalStory,
        document: EcologicalAtlasDocument,
        contractFirstForUITesting: Bool = false
    ) {
        self.story = story
        self.document = document
        self.contractFirstForUITesting = contractFirstForUITesting
    }

    private var sources: [EcologicalSource] {
        let identifiers = Set(
            story.claims.flatMap(\.sourceIDs)
                + story.metrics.flatMap(\.sourceIDs)
                + story.timeline.flatMap(\.sourceIDs)
        )
        return document.sources.filter { identifiers.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if contractFirstForUITesting {
                    imageContract
                }

                EcologicalStoryMediaSurface(
                    story: story,
                    reloadToken: reloadToken,
                    selectedContentMode: contentMode
                )

                header
                metricGrid
                mechanismAndDistribution
                debate
                claims
                timeline
                questions
                if !contractFirstForUITesting {
                    imageContract
                }
                sourceCatalog
                mediaCredits
            }
            .padding(18)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(story.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("ecology.story.\(story.id)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(story.eyebrow)
                    .font(.caption.weight(.bold))
                    .foregroundColor(.secondary)
                Spacer()
                Label("\(story.readingMinutes) 分钟", systemImage: "clock")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(story.title)
                .font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                EcologicalStatusBadge(status: story.epistemicStatus)
                Label(story.layout.title, systemImage: "rectangle.3.group")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(story.epistemicStatus.explanation)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(story.summary)
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var metricGrid: some View {
        if !story.metrics.isEmpty {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 210), spacing: 12)],
                spacing: 12
            ) {
                ForEach(story.metrics) { metric in
                    EcologicalMetricCard(metric: metric, sourcesByID: document.sourcesByID)
                }
            }
        }
    }

    private var mechanismAndDistribution: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 310), spacing: 14)],
            spacing: 14
        ) {
            WorkbenchSectionCard(title: "因果机制") {
                Text(story.mechanism)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WorkbenchSectionCard(title: "权力与分配") {
                Text(story.distribution)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("ecology.story.mechanism-distribution.\(story.id)")
    }

    private var debate: some View {
        WorkbenchSectionCard(title: "不要把争论压成赞成或反对") {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240), spacing: 12)],
                spacing: 12
            ) {
                debatePanel("主张", story.debate.proposition, symbol: "quote.bubble")
                debatePanel("质疑", story.debate.challenge, symbol: "exclamationmark.bubble")
                debatePanel("综合判断", story.debate.synthesis, symbol: "arrow.triangle.merge")
            }
        }
        .accessibilityIdentifier("ecology.story.debate.\(story.id)")
    }

    private var claims: some View {
        WorkbenchSectionCard(title: "可追踪声明") {
            ForEach(story.claims) { claim in
                VStack(alignment: .leading, spacing: 8) {
                    Text(claim.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if claim.sourceIDs.isEmpty {
                        Label(
                            "规范性或综合判断：不以来源数量伪装成经验事实",
                            systemImage: "person.crop.circle.badge.checkmark"
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    } else {
                        ForEach(claim.sourceIDs, id: \.self) { sourceID in
                            if let source = document.sourcesByID[sourceID] {
                                Link(destination: source.url) {
                                    Label(
                                        "\(source.organization) · \(source.year) · \(source.sourceClass.title)",
                                        systemImage: "arrow.up.right.square"
                                    )
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }
                .accessibilityIdentifier("ecology.claim.\(claim.id)")
                if claim.id != story.claims.last?.id { Divider() }
            }
        }
    }

    @ViewBuilder
    private var timeline: some View {
        if !story.timeline.isEmpty {
            WorkbenchSectionCard(title: "时间与证据节点") {
                ForEach(story.timeline) { event in
                    HStack(alignment: .top, spacing: 12) {
                        Text(event.marker)
                            .font(.caption.weight(.bold).monospacedDigit())
                            .frame(width: 52, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title).font(.headline)
                            Text(event.body).font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                    .accessibilityIdentifier("ecology.timeline.\(event.id)")
                    if event.id != story.timeline.last?.id { Divider() }
                }
            }
        }
    }

    private var questions: some View {
        WorkbenchSectionCard(title: "继续追问") {
            ForEach(Array(story.questions.enumerated()), id: \.offset) { index, question in
                Label(question, systemImage: "questionmark.circle")
                    .accessibilityIdentifier("ecology.question.\(story.id).\(index)")
            }
        }
    }

    // UI 测试仅可调整契约区块的出现顺序；重载、清理和显示模式仍通过正式模型与管线执行。
    private var imageContract: some View {
        WorkbenchSectionCard(title: "这一页如何测试 Fovea") {
            Label(story.imageScenario.name, systemImage: "photo.on.rectangle.angled")
                .font(.headline)
            Text(story.imageScenario.sourceMix)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)

            WorkbenchActionStatus(
                message: imageActionMessage,
                identifier: "ecology.image-action-status.\(story.id)"
            )

            Picker("主图显示方式", selection: $contentMode) {
                ForEach(WorkbenchContentMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("ecology.content-mode.\(story.id)")

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160), spacing: 10)],
                spacing: 10
            ) {
                Button("重建全部图片") {
                    reloadToken = UUID()
                    imageActionMessage = "全部专题图片已使用新身份重建"
                }
                .buttonStyle(WorkbenchActionButtonStyle(.secondary))
                .accessibilityIdentifier("ecology.reload.\(story.id)")

                Button("清内存后重载") {
                    Task {
                        await model.purgeMemory()
                        reloadToken = UUID()
                        imageActionMessage = "内存图片已清空并重新加载"
                    }
                }
                .buttonStyle(WorkbenchActionButtonStyle(.secondary))
                .disabled(!model.isReady)
                .accessibilityIdentifier("ecology.purge.\(story.id)")

                Button(showsImageContract ? "收起契约" : "展开契约") {
                    showsImageContract.toggle()
                    imageActionMessage = showsImageContract ? "图片契约已展开" : "图片契约已收起"
                }
                .buttonStyle(WorkbenchActionButtonStyle(.quiet))
                .accessibilityIdentifier("ecology.contract.\(story.id)")
            }

            if showsImageContract {
                contractGroup("目标变体", story.imageScenario.targetVariants, symbol: "aspectratio")
                contractGroup("交互脚本", story.imageScenario.interactions, symbol: "hand.tap")
                contractGroup(
                    "预期行为", story.imageScenario.expectedBehaviors, symbol: "checkmark.circle")
            }
        }
    }

    private var sourceCatalog: some View {
        WorkbenchSectionCard(title: "本专题来源") {
            ForEach(sources) { source in
                EcologicalSourceRow(source: source)
                if source.id != sources.last?.id { Divider() }
            }
        }
    }

    private var mediaCredits: some View {
        WorkbenchSectionCard(title: "页面图片来源") {
            ForEach(storyAssetIDs, id: \.self) { assetID in
                if let asset = WorkbenchRemoteAssetCatalog.asset(id: assetID) {
                    NavigationLink(destination: WorkbenchRemoteAssetDetailView(asset: asset)) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: asset.sourceKind.symbol)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(asset.title).font(.subheadline.weight(.semibold))
                                Text("\(asset.author) · \(asset.license)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    if assetID != storyAssetIDs.last { Divider() }
                }
            }
        }
    }

    private var storyAssetIDs: [String] {
        [story.heroAssetID] + story.galleryAssetIDs
    }

    private func debatePanel(_ title: String, _ text: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func contractGroup(_ title: String, _ items: [String], symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
            ForEach(items, id: \.self) { item in
                Text("• \(item)").font(.caption).foregroundColor(.secondary)
            }
        }
    }
}
