import SwiftUI

/// 生态图谱跨页面共享的视觉原语。组件只呈现稳定内容身份，不拥有导航、搜索或加载生命周期。
struct EcologicalStatusBadge: View {
    let status: EcologicalEpistemicStatus

    var body: some View {
        Text(status.title)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(background, in: Capsule())
            .foregroundColor(foreground)
            .accessibilityLabel("证据性质：\(status.title)")
    }

    private var background: Color {
        switch status {
        case .assessedConsensus: .green.opacity(0.16)
        case .observedSynthesis: .blue.opacity(0.16)
        case .modelledScenario: .orange.opacity(0.18)
        case .interpretiveLens: .purple.opacity(0.16)
        case .normativePosition: .pink.opacity(0.16)
        case .contestedEvidence: .yellow.opacity(0.22)
        }
    }

    private var foreground: Color {
        switch status {
        case .assessedConsensus: .green
        case .observedSynthesis: .blue
        case .modelledScenario: .orange
        case .interpretiveLens: .purple
        case .normativePosition: .pink
        case .contestedEvidence: .orange
        }
    }
}

struct EcologicalMetricCard: View {
    let metric: EcologicalMetric
    let sourcesByID: [String: EcologicalSource]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(metric.value)
                .font(.title2.weight(.bold).monospacedDigit())
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(metric.label)
                .font(.subheadline.weight(.semibold))
            Text(metric.context)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let source = metric.sourceIDs.compactMap({ sourcesByID[$0] }).first {
                Link("\(source.organization) · \(source.year)", destination: source.url)
                    .font(.caption2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .accessibilityIdentifier("ecology.metric.\(metric.id)")
    }
}

struct EcologicalStoryCard: View {
    let story: EcologicalStory
    var compact = false

    @State private var revision = UUID()

    private var asset: WorkbenchRemoteAsset {
        WorkbenchRemoteAssetCatalog.asset(id: story.heroAssetID)
            ?? WorkbenchRemoteAssetCatalog.featured
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkbenchImageSurface(
                configuration: WorkbenchImageSurfaceConfiguration(
                    aspectRatio: compact ? 16 / 9 : 4 / 3,
                    contentMode: .fill,
                    cornerRadius: 0
                )
            ) {
                WorkbenchRemoteAssetImage(
                    asset: asset,
                    revision: revision,
                    contentMode: .fill,
                    accessibilityIdentifier: "ecology.card.image.\(story.id)"
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(story.eyebrow)
                        .font(.caption.weight(.bold))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 8)
                    Text("\(story.readingMinutes) 分钟")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Text(story.title)
                    .font((compact ? Font.headline : Font.title3).weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                if !compact {
                    Text(story.summary)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(4)
                }
                HStack {
                    EcologicalStatusBadge(status: story.epistemicStatus)
                    Spacer()
                    Label(story.layout.title, systemImage: "rectangle.3.group")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(14)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct EcologicalSourceRow: View {
    let source: EcologicalSource

    var body: some View {
        Link(destination: source.url) {
            VStack(alignment: .leading, spacing: 4) {
                Text(source.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Text("\(source.organization) · \(source.year) · \(source.sourceClass.title)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("ecology.source.\(source.id)")
    }
}

struct EcologicalVolumeHeader: View {
    let volume: EcologicalVolume

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(String(format: "卷 %02d", volume.number))
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundColor(.secondary)
            Text(volume.title)
                .font(.largeTitle.weight(.bold))
            Text(volume.subtitle)
                .font(.title3.weight(.semibold))
            Text(volume.summary)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
