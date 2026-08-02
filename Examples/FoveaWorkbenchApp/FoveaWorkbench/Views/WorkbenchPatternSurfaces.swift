import SwiftUI

/// 根据真实产品任务保留不同信息层级，但所有内容图片共享同一容器语义。
/// 每个容器在创建时就确定比例、完整显示或裁切填充，以及裁切边界。
struct WorkbenchPatternSurface: View {
    let pattern: WorkbenchExperiencePattern
    let assets: [WorkbenchRemoteAsset]
    let columnCount: Int
    let contentMode: WorkbenchContentMode
    let revision: UUID

    @ViewBuilder
    var body: some View {
        switch pattern {
        case .socialFeed: socialFeed
        case .chat: chat
        case .commerce: commerce
        case .article: article
        case .stories: stories
        case .photoLibrary: photoLibrary
        case .searchResults: searchResults
        case .travel: travel
        case .profile: profile
        case .notifications: notifications
        case .offlineHybrid: offlineHybrid
        }
    }

    private var socialFeed: some View {
        LazyVStack(spacing: 18) {
            ForEach(Array(assets.prefix(20).enumerated()), id: \.element.id) { index, asset in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        circularImage(
                            cycledAsset(at: index + 1),
                            diameter: 44,
                            identifier: "studio.social.avatar.\(index)"
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("创作者 \(index + 1)")
                                .font(.subheadline.weight(.semibold))
                            Text(index.isMultiple(of: 2) ? "刚刚" : "今天")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "ellipsis")
                            .foregroundColor(.secondary)
                            .frame(width: 44, height: 44)
                    }
                    Text(
                        index.isMultiple(of: 2)
                            ? "记录一段真实内容，并观察滚动回屏时图片是否立即复用。"
                            : asset.subtitle
                    )
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                    surfaceImage(
                        asset,
                        mode: contentMode,
                        aspectRatio: index.isMultiple(of: 3) ? 4 / 3 : 16 / 10,
                        identifier: "studio.social.image.\(index)",
                        cornerRadius: 16
                    )

                    HStack(spacing: 22) {
                        Label("喜欢", systemImage: "heart")
                        Label("评论", systemImage: "bubble.right")
                        Label("分享", systemImage: "paperplane")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .workbenchCard(emphasized: true)
            }
        }
    }

    private var chat: some View {
        LazyVStack(spacing: 14) {
            ForEach(Array(assets.prefix(28).enumerated()), id: \.element.id) { index, asset in
                HStack(alignment: .bottom, spacing: 9) {
                    if !index.isMultiple(of: 2) { Spacer(minLength: 44) }
                    if index.isMultiple(of: 2) {
                        circularImage(
                            cycledAsset(at: index + 3),
                            diameter: 36,
                            identifier: "studio.chat.avatar.\(index)"
                        )
                    }
                    VStack(alignment: index.isMultiple(of: 2) ? .leading : .trailing, spacing: 6) {
                        Text(index.isMultiple(of: 3) ? "你看这张图片" : "这条附件在回屏时不应重新闪烁")
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                index.isMultiple(of: 2)
                                    ? Color(.secondarySystemBackground)
                                    : Color.accentColor.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                            )
                        surfaceImage(
                            asset,
                            mode: .fill,
                            aspectRatio: index.isMultiple(of: 4) ? 1 : 4 / 3,
                            identifier: "studio.chat.attachment.\(index)",
                            cornerRadius: 15
                        )
                        .frame(maxWidth: 260)
                    }
                    if index.isMultiple(of: 2) { Spacer(minLength: 44) }
                }
            }
        }
    }

    private var commerce: some View {
        LazyVGrid(columns: gridColumns, spacing: 14) {
            ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                NavigationLink(destination: WorkbenchZoomableAssetView(asset: asset)) {
                    VStack(alignment: .leading, spacing: 9) {
                        surfaceImage(
                            asset,
                            mode: .fill,
                            aspectRatio: 1,
                            identifier: "studio.commerce.image.\(index)",
                            cornerRadius: 14
                        )
                        Text(asset.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(asset.sourceKind == .bundled ? "离线可用" : "可缓存网络资源")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Label("查看细节", systemImage: "plus.magnifyingglass")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.accentColor)
                    }
                    .workbenchCard()
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var article: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            if let hero = assets.first {
                surfaceImage(
                    hero,
                    mode: .fill,
                    aspectRatio: 16 / 9,
                    identifier: "studio.article.hero",
                    cornerRadius: 18
                )
            }
            Text("一篇包含真实图片的长文章")
                .font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("头图先建立内容语境，正文图片随阅读顺序出现。不同宽度下目标像素会变化，但同一稳定几何不应反复创建新身份。")
                .font(.title3)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(assets.dropFirst().prefix(12).enumerated()), id: \.element.id) {
                index, asset in
                Text(articleParagraph(index))
                    .font(.body)
                surfaceImage(
                    asset,
                    mode: contentMode,
                    aspectRatio: index.isMultiple(of: 2) ? 3 / 2 : 4 / 3,
                    identifier: "studio.article.inline.\(index)",
                    cornerRadius: 14
                )
                Text("图 \(index + 1) · \(asset.title)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var stories: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Array(assets.prefix(20).enumerated()), id: \.element.id) {
                        index, asset in
                        VStack(spacing: 6) {
                            circularImage(
                                asset,
                                diameter: 68,
                                identifier: "studio.story.avatar.\(index)"
                            )
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: 3))
                            Text("故事 \(index + 1)")
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                }
            }
            TabView {
                ForEach(Array(assets.prefix(12).enumerated()), id: \.element.id) { index, asset in
                    captionedImage(
                        asset,
                        aspectRatio: 9 / 16,
                        identifier: "studio.story.page.\(index)",
                        title: asset.title,
                        detail: "下一项会在用户翻页前进入预取窗口。"
                    )
                    .padding(.horizontal, 2)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .frame(height: 430)
        }
    }

    private var photoLibrary: some View {
        LazyVGrid(columns: gridColumns, spacing: 4) {
            ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                NavigationLink(destination: WorkbenchZoomableAssetView(asset: asset)) {
                    surfaceImage(
                        asset,
                        mode: .fill,
                        aspectRatio: index % 7 == 0 && columnCount == 1 ? 16 / 9 : 1,
                        identifier: "studio.library.image.\(index)",
                        cornerRadius: 4
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var searchResults: some View {
        LazyVStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                Text("真实图片搜索结果")
                Spacer()
                Text("\(assets.count) 项").foregroundColor(.secondary)
            }
            .workbenchCard()

            ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                HStack(spacing: 12) {
                    surfaceImage(
                        asset,
                        mode: .fill,
                        aspectRatio: 112 / 82,
                        identifier: "studio.search.image.\(index)",
                        cornerRadius: 11
                    )
                    .frame(width: 112)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(asset.title).font(.headline).lineLimit(2)
                        Text(asset.subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                        Label(asset.sourceTitle, systemImage: asset.sourceKind.symbol)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .workbenchCard()
            }
        }
    }

    private var travel: some View {
        LazyVStack(spacing: 16) {
            ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                captionedImage(
                    asset,
                    aspectRatio: index.isMultiple(of: 4) ? 2 : 16 / 10,
                    identifier: "studio.travel.image.\(index)",
                    title: asset.title,
                    detail: index.isMultiple(of: 2) ? "已保存到离线行程" : "探索附近内容"
                )
            }
        }
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let cover = assets.first {
                surfaceImage(
                    cover,
                    mode: .fill,
                    aspectRatio: 3,
                    identifier: "studio.profile.cover",
                    cornerRadius: 18
                )
            }
            HStack(alignment: .center, spacing: 14) {
                circularImage(
                    cycledAsset(at: 1),
                    diameter: 86,
                    identifier: "studio.profile.avatar"
                )
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 4))
                VStack(alignment: .leading, spacing: 6) {
                    Text("示例创作者").font(.title2.weight(.bold))
                    Text("封面、头像和作品墙共享缓存基础设施，但分别使用适合其容器的目标像素。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LazyVGrid(columns: gridColumns, spacing: 4) {
                ForEach(Array(assets.dropFirst(2).enumerated()), id: \.element.id) { index, asset in
                    surfaceImage(
                        asset,
                        mode: .fill,
                        aspectRatio: 1,
                        identifier: "studio.profile.work.\(index)",
                        cornerRadius: 4
                    )
                }
            }
        }
    }

    private var notifications: some View {
        LazyVStack(spacing: 10) {
            ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                HStack(spacing: 11) {
                    circularImage(
                        cycledAsset(at: index + 2),
                        diameter: 44,
                        identifier: "studio.notification.avatar.\(index)"
                    )
                    Text(index.isMultiple(of: 3) ? "有人收藏了你的图片" : "新的内容已加入你关注的集合")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    surfaceImage(
                        asset,
                        mode: .fill,
                        aspectRatio: 1,
                        identifier: "studio.notification.preview.\(index)",
                        cornerRadius: 8
                    )
                    .frame(width: 54)
                }
                .workbenchCard()
            }
        }
    }

    private var offlineHybrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 12) {
            ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                VStack(alignment: .leading, spacing: 7) {
                    WorkbenchImageSurface(
                        configuration: WorkbenchImageSurfaceConfiguration(
                            aspectRatio: 4 / 3,
                            contentMode: contentMode,
                            cornerRadius: 13
                        )
                    ) {
                        assetImage(
                            asset,
                            mode: contentMode,
                            identifier: "studio.hybrid.image.\(index)"
                        )
                    } overlay: {
                        Label(asset.sourceKind.title, systemImage: asset.sourceKind.symbol)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(7)
                    }
                    Text(asset.title).font(.caption.weight(.semibold)).lineLimit(2)
                }
                .workbenchCard()
            }
        }
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 70), spacing: 10),
            count: max(1, min(4, columnCount))
        )
    }

    private func cycledAsset(at index: Int) -> WorkbenchRemoteAsset {
        guard !assets.isEmpty else { return WorkbenchRemoteAssetCatalog.featured }
        return assets[index % assets.count]
    }

    private func assetImage(
        _ asset: WorkbenchRemoteAsset,
        mode: WorkbenchContentMode,
        identifier: String
    ) -> some View {
        WorkbenchRemoteAssetImage(
            asset: asset,
            revision: revision,
            contentMode: mode,
            accessibilityIdentifier: identifier
        )
    }

    private func surfaceImage(
        _ asset: WorkbenchRemoteAsset,
        mode: WorkbenchContentMode,
        aspectRatio: CGFloat,
        identifier: String,
        cornerRadius: CGFloat
    ) -> some View {
        WorkbenchImageSurface(
            configuration: WorkbenchImageSurfaceConfiguration(
                aspectRatio: aspectRatio,
                contentMode: mode,
                cornerRadius: cornerRadius
            )
        ) {
            assetImage(asset, mode: mode, identifier: identifier)
        }
    }

    private func circularImage(
        _ asset: WorkbenchRemoteAsset,
        diameter: CGFloat,
        identifier: String
    ) -> some View {
        assetImage(asset, mode: .fill, identifier: identifier)
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
    }

    private func captionedImage(
        _ asset: WorkbenchRemoteAsset,
        aspectRatio: CGFloat,
        identifier: String,
        title: String,
        detail: String
    ) -> some View {
        WorkbenchImageSurface(
            configuration: WorkbenchImageSurfaceConfiguration(
                aspectRatio: aspectRatio,
                contentMode: .fill,
                cornerRadius: 18
            )
        ) {
            assetImage(asset, mode: .fill, identifier: identifier)
        } overlay: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.76)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.bold))
                    Text(detail).font(.caption)
                }
                .foregroundColor(.white)
                .padding(16)
            }
        }
    }

    private func articleParagraph(_ index: Int) -> String {
        index.isMultiple(of: 2)
            ? "当图片进入阅读区域时，加载器应使用可见几何生成目标像素，并在用户回读时复用已有结果。"
            : "真正的体验验证不仅看图片是否出现，还要观察占位时机、滚动稳定性、缓存来源和失败恢复。"
    }
}
