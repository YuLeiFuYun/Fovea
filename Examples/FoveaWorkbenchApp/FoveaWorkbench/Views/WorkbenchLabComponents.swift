import FoveaCore
import FoveaSwiftUI
import ImageCraftCore
import SwiftUI

/// 验证页面共享的标题、失败、期望和证据组件。
/// 显示文案可本地化，自动化标识与证据字段保持稳定且彼此独立。
struct WorkbenchLabHeader: View {
    let lab: WorkbenchLab
    @State private var showsTechnicalContracts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(lab.title, systemImage: lab.symbol)
                .font(.title2.weight(.bold))
            Text(lab.summary)
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("技术契约", isExpanded: $showsTechnicalContracts) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                    ForEach(lab.capabilities, id: \.self) { capability in
                        Text(capability)
                            .font(.caption2.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
        }
    }
}

struct WorkbenchScenarioPicker: View {
    let title: String
    let scenarios: [WorkbenchScenario]
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(scenarios) { scenario in
                Text(scenario.title).tag(scenario.id)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("lab.scenario-picker")
    }
}

struct WorkbenchActionStatus: View {
    let message: String
    let identifier: String

    var body: some View {
        Label(message, systemImage: "info.circle")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(message)
            .accessibilityIdentifier(identifier)
    }
}

struct WorkbenchImagePreview: View {
    @EnvironmentObject private var model: WorkbenchAppModel

    let scenario: WorkbenchScenario
    let configuration: WorkbenchConfiguration
    let revision: UUID
    var aspectRatio: CGFloat = 4 / 3
    var cornerRadius: CGFloat = 16
    var accessibilityIdentifier = "lab.preview"

    var body: some View {
        Group {
            if let pipeline = model.pipeline, !isUnavailableLiveScenario {
                FoveaResponsiveImage(
                    loader: pipeline,
                    accessibility: .label(Text(scenario.title)),
                    contentMode: configuration.contentMode.value,
                    geometryIsStable: true,
                    loadingPolicy: FoveaImageLoadingPolicy(
                        placeholderDelayNanoseconds: 16_000_000,
                        retention: configuration.retentionMode.value
                    ),
                    transitionPolicy: FoveaImageTransitionPolicy(
                        opacityDuration: configuration.transitionDuration
                    )
                ) { target in
                    try WorkbenchRequestFactory.makeRequest(
                        scenario: scenario,
                        resolvedTarget: target,
                        configuration: configuration,
                        identityRevision: identityRevision
                    )
                } placeholder: {
                    ZStack {
                        Color.secondary.opacity(0.10)
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("等待布局或加载中")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .accessibilityIdentifier("\(accessibilityIdentifier).loading")
                } failure: { context in
                    WorkbenchFailureCard(context: context)
                }
                .id(identityRevision)
            } else {
                ZStack {
                    Color.secondary.opacity(0.08)
                    VStack(spacing: 8) {
                        Image(systemName: isUnavailableLiveScenario ? "wifi.slash" : "hourglass")
                            .font(.title)
                        Text(isUnavailableLiveScenario ? "外部网络未启用" : "Pipeline 尚未就绪")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var identityRevision: String {
        "\(model.identityRevision.uuidString.lowercased()):\(revision.uuidString.lowercased())"
    }

    private var isUnavailableLiveScenario: Bool {
        scenario.category == .live && !configuration.externalNetworkingEnabled
    }
}

struct WorkbenchFailureCard: View {
    let context: FoveaImageFailureContext

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundColor(.orange)
            Text(failureTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(failureGuidance)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Text(
                "\(context.failure.reasonCode) · \(context.failure.stage.rawValue) · \(context.failure.disposition.rawValue)"
            )
            .font(.caption2.monospaced())
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            if context.recoveryAction == .retry {
                Button("按同一请求身份重试") { context.retry() }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .accessibilityIdentifier("lab.preview.retry")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.orange.opacity(0.08))
        .accessibilityIdentifier("lab.preview.failure")
    }

    private var failureTitle: String {
        switch context.failure.category {
        case .transport, .http: "图片暂时无法下载"
        case .securityLimit, .securityPolicy: "图片被安全策略拒绝"
        case .probe, .decode: "图片内容无法读取"
        case .transform: "图片处理失败"
        case .cancelled: "加载已取消"
        case .authorization, .namespaceRevoked: "账户内容已失效"
        case .cacheRead, .cacheWrite: "缓存暂时不可用"
        case .resourceLimit: "设备资源暂时不足"
        case .internalFailure: "图片管线遇到内部错误"
        }
    }

    private var failureGuidance: String {
        switch context.recoveryAction {
        case .retry: "可重试；旧请求的迟到结果不会覆盖当前图片。"
        case .reauthenticate: "需要重新登录或更新账户权限后再加载。"
        case .none: "显示稳定错误状态，不把失败内容写入可复用缓存。"
        }
    }
}

struct WorkbenchLatestRunCard: View {
    let record: WorkbenchRunRecord?
    let expected: [WorkbenchExpectation]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("预期与实际")
                    .font(.headline)
                Spacer()
                HStack(spacing: 5) {
                    if let record {
                        Image(systemName: statusSymbol(record.state))
                            .foregroundColor(statusColor(record.state))
                            .accessibilityHidden(true)
                    }
                    Text(record?.state.title ?? "尚未运行")
                        .foregroundColor(record.map { statusColor($0.state) } ?? .secondary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier(statusIdentifier)
                        .accessibilityValue(accessibilityState)
                }
                .font(.caption.weight(.semibold))
            }

            ForEach(expected) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(
                        systemName: item.isSatisfied(by: record)
                            ? "checkmark.circle.fill" : "circle"
                    )
                    .foregroundColor(item.isSatisfied(by: record) ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline.weight(.semibold))
                        Text(item.detail(record))
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("expectation.\(item.id)")
                .accessibilityValue(item.isSatisfied(by: record) ? "passed" : "pending-or-failed")
            }

            if let record {
                Divider()
                WorkbenchEvidenceGrid(evidence: record.evidence)
                if record.evidence.cacheDegraded {
                    Label(
                        "图像已显示，但缓存写入发生降级；这不是加载失败。",
                        systemImage: "externaldrive.badge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundColor(.orange)
                }
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private var statusIdentifier: String {
        "lab.latest-result.\(expected.first?.id ?? "default")"
    }

    private var accessibilityState: String {
        guard let record else { return "not-run:none" }
        let phase = record.state.isFinished ? "finished" : "running"
        return "\(phase):\(record.id.uuidString.lowercased())"
    }

    private func statusSymbol(_ state: WorkbenchRunRecord.State) -> String {
        state.isUnexpected ? "xmark.octagon.fill" : "checkmark.circle.fill"
    }

    private func statusColor(_ state: WorkbenchRunRecord.State) -> Color {
        state.isUnexpected ? .red : .green
    }
}

struct WorkbenchEvidenceGrid: View {
    let evidence: WorkbenchRunEvidence

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
            metric(id: "origin", title: "源站请求", value: evidence.originRequests)
            metric(id: "fetch-started", title: "网络开始", value: evidence.count(.fetchStarted))
            metric(id: "fetch-joined", title: "网络共享", value: evidence.count(.fetchJoined))
            metric(id: "decode-joined", title: "解码共享", value: evidence.count(.decodeJoined))
            metric(id: "memory-hit", title: "内存命中", value: evidence.count(.renderedMemoryHit))
            metric(id: "disk-hit", title: "磁盘命中", value: evidence.count(.originalEncodedHit))
            metric(id: "http-304", title: "HTTP 304", value: evidence.count(statusCode: 304))
            metric(
                id: "cancelled", title: "取消",
                value: evidence.count(.fetchCancelled) + evidence.count(.decodeCancelled))
            metric(id: "cache-errors", title: "缓存降级", value: evidence.count(.cacheWriteFailed))
        }
    }

    private func metric(id: String, title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(String(value))
                .font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
        .accessibilityIdentifier("evidence.metric.\(id)")
    }
}

struct WorkbenchExpectation: Identifiable {
    enum Rule {
        case completed
        case expectedFailure(String)
        case originAtMost(Int)
        case originAtLeast(Int)
        case fetchJoinedAtLeast(Int)
        case statusAtLeast(code: Int, count: Int)
        case noCacheWriteFailure
    }

    let id: String
    let title: String
    let rule: Rule

    init(_ id: String, title: String, rule: Rule) {
        self.id = id
        self.title = title
        self.rule = rule
    }

    func isSatisfied(by record: WorkbenchRunRecord?) -> Bool {
        guard let record, record.state.isFinished else { return false }
        switch rule {
        case .completed:
            return !record.state.isUnexpected && record.state != .cancelled
        case .expectedFailure(let reason):
            if case .expectedFailure(let actual) = record.state { return actual == reason }
            return false
        case .originAtMost(let maximum):
            return record.evidence.originRequests <= maximum
        case .originAtLeast(let minimum):
            return record.evidence.originRequests >= minimum
        case .fetchJoinedAtLeast(let minimum):
            return record.evidence.count(.fetchJoined) >= minimum
        case .statusAtLeast(let code, let count):
            return record.evidence.count(statusCode: code) >= count
        case .noCacheWriteFailure:
            return !record.evidence.cacheDegraded
        }
    }

    func detail(_ record: WorkbenchRunRecord?) -> String {
        switch rule {
        case .completed:
            return record?.state.title ?? "等待执行"
        case .expectedFailure(let reason):
            return "预期 \(reason) · 实际 \(record?.evidence.finalReasonCode ?? "—")"
        case .originAtMost(let maximum):
            return "预期不超过 \(maximum) · 实际 \(record?.evidence.originRequests ?? 0)"
        case .originAtLeast(let minimum):
            return "预期至少 \(minimum) · 实际 \(record?.evidence.originRequests ?? 0)"
        case .fetchJoinedAtLeast(let minimum):
            return "预期至少 \(minimum) · 实际 \(record?.evidence.count(.fetchJoined) ?? 0)"
        case .statusAtLeast(let code, let count):
            return
                "HTTP \(code) 预期至少 \(count) · 实际 \(record?.evidence.count(statusCode: code) ?? 0)"
        case .noCacheWriteFailure:
            return "缓存写入失败 \(record?.evidence.count(.cacheWriteFailed) ?? 0)"
        }
    }
}

struct WorkbenchSectionCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}
