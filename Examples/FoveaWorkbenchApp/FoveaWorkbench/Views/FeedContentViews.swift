import FoveaCore
import FoveaSwiftUI
import SwiftUI

/// 可重复的滚动轨迹，用于区分平缓往返与快速反向突发下的取消、复用和预取行为。
enum FeedScrollScript {
    case slowRoundTrip
    case fastReverseBurst

    struct Step {
        let target: Int
        let anchor: UnitPoint
        let pauseNanoseconds: UInt64
    }

    var identifier: String {
        switch self {
        case .slowRoundTrip: "slow-round-trip"
        case .fastReverseBurst: "fast-reverse-burst"
        }
    }

    var title: String {
        switch self {
        case .slowRoundTrip: "慢速往返"
        case .fastReverseBurst: "快速反向"
        }
    }

    func steps(itemCount: Int) -> [Step] {
        let last = max(0, itemCount - 1)
        switch self {
        case .slowRoundTrip:
            return [
                Step(target: last / 3, anchor: .center, pauseNanoseconds: 350_000_000),
                Step(target: (last * 2) / 3, anchor: .center, pauseNanoseconds: 350_000_000),
                Step(target: last, anchor: .bottom, pauseNanoseconds: 450_000_000),
                Step(target: last / 2, anchor: .center, pauseNanoseconds: 350_000_000),
                Step(target: 0, anchor: .top, pauseNanoseconds: 0),
            ]
        case .fastReverseBurst:
            return [
                Step(target: last, anchor: .bottom, pauseNanoseconds: 80_000_000),
                Step(target: 0, anchor: .top, pauseNanoseconds: 80_000_000),
                Step(target: last, anchor: .bottom, pauseNanoseconds: 80_000_000),
                Step(target: 0, anchor: .top, pauseNanoseconds: 0),
            ]
        }
    }
}

struct FeedListRow: View {
    let item: WorkbenchFeedItem
    let revision: String
    let configuration: WorkbenchConfiguration
    let pipeline: FoveaPipeline?

    var body: some View {
        HStack(spacing: 12) {
            FeedImage(
                item: item,
                revision: revision,
                configuration: configuration,
                pipeline: pipeline
            )
            .frame(width: 132, height: 88)

            VStack(alignment: .leading, spacing: 5) {
                Text("项目 \(item.id)")
                    .font(.headline.monospacedDigit())
                Text("素材 \(item.assetID) · \(item.expectedVariantTitle)")
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                Text("延迟 \(item.delayMilliseconds) 毫秒")
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("feed.cell.\(item.id)")
    }
}

struct FeedGridCell: View {
    let item: WorkbenchFeedItem
    let revision: String
    let configuration: WorkbenchConfiguration
    let pipeline: FoveaPipeline?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            FeedImage(
                item: item,
                revision: revision,
                configuration: configuration,
                pipeline: pipeline
            )
            .aspectRatio(3 / 2, contentMode: .fit)

            Text("项目 \(item.id) · 素材 \(item.assetID)")
                .font(.caption.monospaced())
                .lineLimit(1)
        }
        .padding(8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("feed.cell.\(item.id)")
    }
}

struct FeedImage: View {
    let item: WorkbenchFeedItem
    let revision: String
    let configuration: WorkbenchConfiguration
    let pipeline: FoveaPipeline?

    var body: some View {
        Group {
            if let pipeline {
                FoveaResponsiveImage(
                    loader: pipeline,
                    accessibility: .label(Text("项目 \(item.id)，预期显示\(item.expectedVariantTitle)图片")),
                    contentMode: configuration.contentMode.value,
                    geometryIsStable: true,
                    loadingPolicy: FoveaImageLoadingPolicy(
                        placeholderDelayNanoseconds: 220_000_000,
                        retention: .retainSuccessfulImageUntilReplacement
                    ),
                    transitionPolicy: FoveaImageTransitionPolicy(
                        opacityDuration: configuration.transitionDuration
                    )
                ) { target in
                    try WorkbenchRequestFactory.makeFeedRequest(
                        item: item,
                        resolvedTarget: target,
                        configuration: configuration,
                        identityRevision: revision
                    )
                } placeholder: {
                    ZStack {
                        Color.secondary.opacity(0.08)
                        Image(systemName: "photo")
                            .foregroundColor(.secondary.opacity(0.4))
                    }
                } failure: { context in
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("图片暂时不可用")
                            .font(.caption.weight(.semibold))
                        Text(context.failure.reasonCode)
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                        if context.recoveryAction == .retry {
                            Button("重试") { context.retry() }
                                .font(.caption2)
                        }
                    }
                    .padding(4)
                }
                .id("\(item.id):\(revision)")
            } else {
                ZStack {
                    Color.secondary.opacity(0.1)
                    Text("图片管线尚未就绪").font(.caption2)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }
}
