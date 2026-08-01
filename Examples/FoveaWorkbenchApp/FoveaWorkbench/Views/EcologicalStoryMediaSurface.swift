import SwiftUI

/// 八种媒体表面保留不同信息结构，但图片均在布局前获得有限且可审查的容器。
struct EcologicalStoryMediaSurface: View {
    let story: EcologicalStory
    let reloadToken: UUID
    let selectedContentMode: WorkbenchContentMode

    private var assets: [WorkbenchRemoteAsset] {
        ([story.heroAssetID] + story.galleryAssetIDs).compactMap {
            WorkbenchRemoteAssetCatalog.asset(id: $0)
        }
    }

    var body: some View {
        Group {
            switch story.layout {
            case .editorial: editorial
            case .mosaic: mosaic
            case .timeline: timeline
            case .comparison: comparison
            case .atlas: atlas
            case .dossier: dossier
            case .fieldNotes: fieldNotes
            case .immersive: immersive
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("专题媒体")
        .accessibilityIdentifier("ecology.media-surface.\(story.layout.rawValue).\(story.id)")
        .accessibilityValue("images:\(assets.count)")
    }

    private var editorial: some View {
        VStack(spacing: 12) {
            assetImage(assets.first, mode: selectedContentMode, aspectRatio: 16 / 9)
            HStack(alignment: .top, spacing: 12) {
                assetImage(assets[safe: 1], mode: .fill, aspectRatio: 4 / 3)
                assetImage(assets[safe: 2], mode: .fit, aspectRatio: 4 / 3)
            }
        }
    }

    private var mosaic: some View {
        VStack(spacing: 12) {
            assetImage(assets.first, mode: selectedContentMode, aspectRatio: 16 / 9)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Array(assets.dropFirst().enumerated()), id: \.element.id) { index, asset in
                    assetImage(
                        asset,
                        mode: index.isMultiple(of: 3) ? .fit : .fill,
                        aspectRatio: 1
                    )
                }
            }
        }
    }

    private var timeline: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                    VStack(alignment: .leading, spacing: 8) {
                        assetImage(
                            asset,
                            mode: index == 0 ? selectedContentMode : .fill,
                            aspectRatio: 4 / 3
                        )
                        Text(index == 0 ? "主叙事图" : "证据节点 \(index)")
                            .font(.caption.weight(.semibold))
                    }
                    .frame(width: 300)
                }
            }
        }
    }

    private var comparison: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                assetImage(assets.first, mode: .fit, aspectRatio: 4 / 3)
                Label("完整保留画面", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.caption)
            }
            VStack(alignment: .leading, spacing: 8) {
                assetImage(assets[safe: 1], mode: .fill, aspectRatio: 4 / 3)
                Label("裁切填满容器", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
            }
        }
    }

    private var atlas: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                assetImage(
                    asset,
                    mode: index.isMultiple(of: 4) ? .fit : .fill,
                    aspectRatio: index == 0 ? 4 / 3 : 1
                )
            }
        }
    }

    private var dossier: some View {
        VStack(spacing: 12) {
            assetImage(assets.first, mode: selectedContentMode, aspectRatio: 16 / 9)
            ForEach(Array(assets.dropFirst().enumerated()), id: \.element.id) { index, asset in
                HStack(spacing: 12) {
                    assetImage(asset, mode: .fill, aspectRatio: 4 / 3)
                        .frame(width: 112)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("档案条目 \(index + 1)").font(.headline)
                        Text(asset.title).font(.caption).foregroundColor(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .workbenchCard()
            }
        }
    }

    private var fieldNotes: some View {
        LazyVStack(spacing: 14) {
            assetImage(assets.first, mode: .fit, aspectRatio: 16 / 9)
            ForEach(Array(assets.dropFirst().enumerated()), id: \.element.id) { index, asset in
                VStack(alignment: .leading, spacing: 10) {
                    assetImage(asset, mode: .fill, aspectRatio: 16 / 10)
                    Text("田野札记 \(index + 1)").font(.headline)
                    Text(asset.subtitle).font(.subheadline).foregroundColor(.secondary)
                    Text("来源：\(asset.author)").font(.caption).foregroundColor(.secondary)
                }
                .workbenchCard()
            }
        }
    }

    private var immersive: some View {
        LazyVStack(spacing: 14) {
            ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                assetImage(
                    asset,
                    mode: index == 0 ? selectedContentMode : .fill,
                    aspectRatio: index.isMultiple(of: 2) ? 16 / 9 : 4 / 3
                )
            }
        }
    }

    // 布局可以改变裁切与排列，但 asset ID、reload token 和可访问性身份必须沿所有表面保持稳定。
    @ViewBuilder
    private func assetImage(
        _ asset: WorkbenchRemoteAsset?,
        mode: WorkbenchContentMode,
        aspectRatio: CGFloat
    ) -> some View {
        if let asset {
            WorkbenchImageSurface(
                configuration: WorkbenchImageSurfaceConfiguration(
                    aspectRatio: aspectRatio,
                    contentMode: mode,
                    cornerRadius: 18
                )
            ) {
                WorkbenchRemoteAssetImage(
                    asset: asset,
                    revision: reloadToken,
                    contentMode: mode,
                    accessibilityIdentifier: "ecology.story-image.\(story.id).\(asset.id)"
                )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            }
        }
    }
}

extension Collection {
    fileprivate subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
