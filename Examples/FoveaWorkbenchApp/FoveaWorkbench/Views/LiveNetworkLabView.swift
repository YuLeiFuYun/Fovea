import FoveaCore
import SwiftUI

/// 显式启用真实 HTTPS 后展示多 origin、重定向和当前网络路径证据。
/// 第三方服务故障属于环境结果，不会伪装成确定性产品回归。
struct LiveNetworkLabView: View {
    @EnvironmentObject private var model: WorkbenchAppModel
    let lab: WorkbenchLab

    @State private var selectedScenarioID: String
    @State private var revision = UUID()

    init(lab: WorkbenchLab) {
        self.lab = lab
        _selectedScenarioID = State(initialValue: lab.scenarioIDs.first ?? "live-github-swift-png")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WorkbenchLabHeader(lab: lab)
                networkStatus
                realAssetStrip
                serviceProbe
                networkEvidence
                WorkbenchLatestRunCard(
                    record: model.latestRun(for: scenario.id),
                    expected: [
                        WorkbenchExpectation(
                            "environment",
                            title: "结果被标记为外部环境证据",
                            rule: .completed
                        )
                    ]
                )
            }
            .padding(20)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(lab.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("lab.live-network")
    }

    private var networkStatus: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(
                systemName: model.activeConfiguration.externalNetworkingEnabled
                    ? "network" : "wifi.slash"
            )
            .font(.title2)
            .foregroundColor(model.activeConfiguration.externalNetworkingEnabled ? .green : .orange)
            .frame(width: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text(
                    model.activeConfiguration.externalNetworkingEnabled
                        ? "真实 HTTPS 已启用" : "当前使用确定性离线替身"
                )
                .font(.headline)
                Text(statusDescription)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 12)
            if !model.activeConfiguration.externalNetworkingEnabled {
                Button("启用") {
                    model.draftConfiguration.externalNetworkingEnabled = true
                    Task { await model.applyConfiguration() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(17)
        .background(
            (model.activeConfiguration.externalNetworkingEnabled ? Color.green : Color.orange)
                .opacity(0.10),
            in: RoundedRectangle(cornerRadius: 18)
        )
    }

    private var realAssetStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("真实图片路径")
                    .font(.title3.weight(.bold))
                Text("同一官方管线加载公开许可图片，覆盖媒体库重定向、图片分发网络、目标像素和磁盘复用。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 13) {
                    ForEach(Array(WorkbenchRemoteAssetCatalog.remoteAssets.prefix(5))) { asset in
                        NavigationLink(destination: WorkbenchRemoteAssetDetailView(asset: asset)) {
                            VStack(alignment: .leading, spacing: 7) {
                                WorkbenchRemoteAssetImage(
                                    asset: asset,
                                    revision: revision,
                                    contentMode: .fill,
                                    accessibilityIdentifier: "live.asset.\(asset.id)"
                                )
                                .frame(width: 210, height: 138)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                Text(asset.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.primary)
                                Text(
                                    "\(asset.license) · \(asset.originalPixelWidth)×\(asset.originalPixelHeight)"
                                )
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                            }
                            .frame(width: 210, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }

    private var serviceProbe: some View {
        WorkbenchSectionCard(title: "多源站服务探针") {
            WorkbenchScenarioPicker(
                title: "网络目标",
                scenarios: lab.scenarios,
                selection: $selectedScenarioID
            )

            WorkbenchImagePreview(
                scenario: scenario,
                configuration: model.activeConfiguration,
                revision: revision,
                accessibilityIdentifier: "live.preview"
            )

            Text(scenario.summary)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Button {
                    revision = UUID()
                } label: {
                    Label("重新请求", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button {
                    _ = model.run(scenario)
                } label: {
                    Label("记录环境探针", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isReady || !model.activeConfiguration.externalNetworkingEnabled)
                .accessibilityIdentifier("live.run")
            }
        }
    }

    private var networkEvidence: some View {
        WorkbenchSectionCard(title: "当前会话网络摘要") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                metric("请求", eventCount(.fetchStarted))
                metric("共享", eventCount(.fetchJoined))
                metric("完成", eventCount(.fetchCompleted))
                metric("重定向异常", redirectOrAnomalyCount)
                metric("缓存命中", eventCount(.renderedMemoryHit) + eventCount(.originalEncodedHit))
                metric("失败", failureCount)
            }
            Text("这些数字只描述当前设备与当前网络路径。DNS、代理、VPN、TLS、CDN 或第三方维护造成的失败不会自动归咎于 Fovea。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text(String(value)).font(.title3.monospacedDigit().weight(.bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 11))
    }

    private var scenario: WorkbenchScenario {
        WorkbenchScenarioCatalog.scenario(id: selectedScenarioID)
            ?? lab.scenarios.first
            ?? WorkbenchScenarioCatalog.fallback
    }

    private var statusDescription: String {
        if model.activeConfiguration.externalNetworkingEnabled {
            return "\(model.network.status) · \(model.network.interface)。结果可能受代理、VPN、限流和服务维护影响。"
        }
        return "UI 自动化、离线演示和协议回归仍使用 fovea-demo.test，保证可重复。"
    }

    private func eventCount(_ kind: DiagnosticEventKind) -> Int {
        model.diagnosticEvents.lazy.filter { $0.event.kind == kind }.count
    }

    private var redirectOrAnomalyCount: Int {
        model.diagnosticEvents.lazy.filter {
            ($0.event.redirectCount ?? 0) > 0 || $0.event.kind == .responseAnomaly
        }.count
    }

    private var failureCount: Int {
        model.diagnosticEvents.lazy.filter { $0.event.failureCategory != nil }.count
    }
}
