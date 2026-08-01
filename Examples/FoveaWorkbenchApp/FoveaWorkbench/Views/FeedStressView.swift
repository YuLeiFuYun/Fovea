import FoveaCore
import FoveaSwiftUI
import SwiftUI

/// 对 SwiftUI 与 UIKit 运行相同的数百至数千项目工作负载。
/// 脚本记录帧间隔和内存代理，但这些指标只用于同环境回归，不宣称真机上界。
struct FeedStressView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: WorkbenchAppModel
    @StateObject private var performanceMonitor = WorkbenchPerformanceMonitor()
    let scenario: WorkbenchScenario

    @State private var host = WorkbenchFeedHost.swiftUI
    @State private var layout: WorkbenchFeedLayout
    @State private var itemCount = 240
    @State private var uniqueAssetCount = 96
    @State private var delayedResponses = false
    @State private var prefetchEnabled = true
    @State private var workloadControlsExpanded = false
    @State private var items: [WorkbenchFeedItem]
    @State private var localRevision = UUID()
    @State private var actionMessage = "工作负载尚未启动；进入实验页面不会自动发起图片请求"
    @State private var scriptTask: Task<Void, Never>?
    @State private var uiKitScrollCommand: UIKitFeedScrollCommand?
    @State private var uiKitCommandGeneration = 0

    init(scenario: WorkbenchScenario, initialLayout: WorkbenchFeedLayout) {
        self.scenario = scenario
        _layout = State(initialValue: initialLayout)
        _items = State(initialValue: [])
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            hud
            Divider()
            feed
        }
        .navigationTitle("列表、网格与复用")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Text(actionMessage)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .overlay(alignment: .top) { Divider() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(actionMessage)
                .accessibilityIdentifier("feed.action-status")
        }
        .onChange(of: itemCount) { _ in rebuildItems() }
        .onChange(of: uniqueAssetCount) { _ in rebuildItems() }
        .onChange(of: delayedResponses) { _ in rebuildItems() }
        .onChange(of: prefetchEnabled) { enabled in
            if enabled { prefetchVisibleAssets() }
        }
        .onChange(of: host) { _ in cancelActiveMeasurement(reason: "宿主已切换") }
        .onChange(of: layout) { _ in cancelActiveMeasurement(reason: "布局已切换") }
        .onChange(of: scenePhase) { phase in
            guard phase != .active else { return }
            scriptTask?.cancel()
            scriptTask = nil
            cancelActiveMeasurement(reason: "应用进入后台")
        }
        .onDisappear {
            scriptTask?.cancel()
            scriptTask = nil
            performanceMonitor.cancel()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("真实宿主生命周期实验")
                        .font(.headline)
                        .accessibilityIdentifier("feed-lab")
                    Text("SwiftUI 惰性容器与 UIKit 集合视图共用同一工作负载。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(items.isEmpty ? itemCount : items.count) 项")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .accessibilityLabel("项目数量")
                        .accessibilityValue(String(items.isEmpty ? itemCount : items.count))
                        .accessibilityIdentifier("feed.workload-size")
                    workloadToggleButton
                }
            }

            Picker("宿主", selection: $host) {
                ForEach(WorkbenchFeedHost.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("feed.host")

            Picker("布局", selection: $layout) {
                ForEach(WorkbenchFeedLayout.allCases) { value in
                    Label(value.title, systemImage: value.symbol).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("feed.layout")

            DisclosureGroup("工作负载参数", isExpanded: $workloadControlsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Stepper("Cell 数量：\(itemCount)", value: $itemCount, in: 40...2_000, step: 40)
                    Stepper(
                        "唯一图片：\(uniqueAssetCount)",
                        value: $uniqueAssetCount,
                        in: 8...min(300, WorkbenchRemoteAssetCatalog.remoteAssets.count),
                        step: 8
                    )
                    Toggle("提前加载首批网络图片", isOn: $prefetchEnabled)
                    Toggle("确定性模式模拟首字节延迟", isOn: $delayedResponses)
                        .disabled(model.activeConfiguration.externalNetworkingEnabled)

                    Text(
                        model.activeConfiguration.externalNetworkingEnabled
                            ? "\(itemCount) 个项目使用 \(uniqueAssetCount) 张真实网络图片；重复出现的图片共享稳定身份。"
                            : "\(itemCount) 个项目复用 \(uniqueAssetCount) 个确定性测试素材；可注入不同首字节延迟。"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.top, 6)
            }
            .font(.subheadline)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
    }

    private var workloadToggleButton: some View {
        Button(items.isEmpty ? "启动" : "停止") {
            if items.isEmpty {
                activateWorkload()
            } else {
                scriptTask?.cancel()
                scriptTask = nil
                performanceMonitor.cancel()
                model.cancelPrefetches()
                items = []
                localRevision = UUID()
                actionMessage = "工作负载已停止；所有可见图片宿主将释放请求"
            }
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel(items.isEmpty ? "启动工作负载" : "停止工作负载")
        .accessibilityIdentifier("feed.workload-toggle")
    }

    private var hud: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                hudMetric("Origin", String(originRequests))
                hudMetric("Fetch", String(eventCount(.fetchStarted)))
                hudMetric("Join", String(eventCount(.fetchJoined) + eventCount(.decodeJoined)))
                hudMetric(
                    "Cancel", String(eventCount(.fetchCancelled) + eventCount(.decodeCancelled)))
                hudMetric("Memory", String(eventCount(.renderedMemoryHit)))
                hudMetric("Disk", String(eventCount(.originalEncodedHit)))
                hudMetric("Cache errors", String(eventCount(.cacheWriteFailed)))
                hudMetric("Hitch proxy", String(performanceMonitor.hitchCount))
                hudMetric(
                    "Max interval ms",
                    String(format: "%.1f", performanceMonitor.maximumFrameIntervalMilliseconds)
                )
                hudMetric("Footprint delta", peakRSSDeltaTitle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
        .accessibilityIdentifier("feed.hud")
    }

    private func hudMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
        .frame(minWidth: 72, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
        .accessibilityIdentifier(
            "feed.metric.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }

    private var feed: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                scriptControls(proxy: proxy)
                if items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "pause.circle")
                            .font(.largeTitle)
                        Text("工作负载未启动")
                            .font(.headline)
                        Text("先显式启动，再比较 SwiftUI 与 UIKit 的滚动、取消和复用行为。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
                    .accessibilityIdentifier("feed.workload-idle")
                } else {
                    switch host {
                    case .swiftUI:
                        swiftUIFeed
                    case .uiKit:
                        UIKitFeedView(
                            items: items,
                            layout: layout,
                            pipeline: model.pipeline,
                            configuration: model.activeConfiguration,
                            revision: revisionString,
                            scrollCommand: uiKitScrollCommand
                        )
                        .accessibilityIdentifier("feed.uikit-host")
                    }
                }
            }
        }
    }

    private func scriptControls(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button("顶部") {
                    scroll(to: items.first?.id, proxy: proxy, anchor: .top)
                }
                .accessibilityIdentifier("feed.scroll-top")
                .disabled(items.isEmpty)

                Button("底部") {
                    scroll(to: items.last?.id, proxy: proxy, anchor: .bottom)
                }
                .accessibilityIdentifier("feed.scroll-bottom")
                .disabled(items.isEmpty)

                Button("慢速脚本") {
                    runScript(.slowRoundTrip, proxy: proxy)
                }
                .accessibilityIdentifier("feed.script-slow")
                .disabled(items.isEmpty)

                Button("快速脚本") {
                    runScript(.fastReverseBurst, proxy: proxy)
                }
                .accessibilityIdentifier("feed.script-fast")
                .disabled(items.isEmpty)

                if performanceMonitor.isMeasuring {
                    Button("结束测量") {
                        finishMeasurement(prefix: "手动测量已完成")
                    }
                    .accessibilityIdentifier("feed.measure-stop")
                } else {
                    Button("开始测量") {
                        beginMeasurement(workloadID: "W1-manual")
                        actionMessage = "手动帧间隔与内存占用代理测量已开始"
                    }
                    .accessibilityIdentifier("feed.measure-start")
                }

                Button("重建身份") {
                    localRevision = UUID()
                    actionMessage = "已创建新的请求身份"
                }
                .accessibilityIdentifier("feed.rebuild")

                Button("清内存") {
                    Task {
                        await model.purgeMemory()
                        localRevision = UUID()
                        actionMessage = "内存缓存已清理并重建请求"
                    }
                }
                .accessibilityIdentifier("feed.purge-memory")

                Button("清证据") {
                    Task {
                        await model.resetEvidence()
                        actionMessage = "源站与诊断证据已清空"
                    }
                }
                .accessibilityIdentifier("feed.reset-evidence")
            }
            .buttonStyle(.bordered)
            .font(.caption)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var swiftUIFeed: some View {
        ScrollView {
            switch layout {
            case .list:
                LazyVStack(spacing: 12) {
                    ForEach(items) { item in
                        FeedListRow(
                            item: item,
                            revision: revisionString,
                            configuration: model.activeConfiguration,
                            pipeline: model.pipeline
                        )
                        .id(item.id)
                    }
                }
                .padding(12)
            case .grid:
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(items) { item in
                        FeedGridCell(
                            item: item,
                            revision: revisionString,
                            configuration: model.activeConfiguration,
                            pipeline: model.pipeline
                        )
                        .id(item.id)
                    }
                }
                .padding(12)
            }
        }
        .accessibilityIdentifier("feed.swiftui-host")
    }

    private var revisionString: String {
        "\(model.identityRevision.uuidString.lowercased()):\(localRevision.uuidString.lowercased())"
    }

    private var originRequests: Int {
        model.originRequestCounts.values.reduce(0, +)
    }

    private func eventCount(_ kind: DiagnosticEventKind) -> Int {
        model.diagnosticEvents.lazy.filter { $0.event.kind == kind }.count
    }

    private func rebuildItems() {
        guard !items.isEmpty else { return }
        cancelActiveMeasurement(reason: "工作负载参数已改变")
        items = WorkbenchFeedItem.makeItems(
            count: itemCount,
            uniqueAssetCount: uniqueAssetCount,
            delayed: delayedResponses
        )
        localRevision = UUID()
        prefetchVisibleAssets()
        actionMessage = "数据集已稳定重建：\(items.count) 个项目 / \(uniqueAssetCount) 张素材"
    }

    private func activateWorkload() {
        items = WorkbenchFeedItem.makeItems(
            count: itemCount,
            uniqueAssetCount: uniqueAssetCount,
            delayed: delayedResponses
        )
        localRevision = UUID()
        prefetchVisibleAssets()
        actionMessage = "工作负载已启动：\(items.count) 个项目 / \(uniqueAssetCount) 张素材"
    }

    private func prefetchVisibleAssets() {
        guard prefetchEnabled, model.activeConfiguration.externalNetworkingEnabled else { return }
        let assets = (0..<min(uniqueAssetCount, 300)).map {
            WorkbenchRemoteAssetCatalog.remoteAsset(forStableIndex: $0)
        }
        model.prefetchRemoteAssets(
            assets,
            estimatedConsumptionRate: 18,
            minimumCount: 16,
            maximumCount: 96
        )
    }

    private func scroll(
        to item: Int?,
        proxy: ScrollViewProxy,
        anchor: UnitPoint
    ) {
        guard let item else { return }
        switch host {
        case .swiftUI:
            proxy.scrollTo(item, anchor: anchor)
        case .uiKit:
            issueUIKitScroll(item: item, anchor: anchor)
        }
        actionMessage = item == items.first?.id ? "已滚动到顶部" : "已滚动到底部"
    }

    private func runScript(_ script: FeedScrollScript, proxy: ScrollViewProxy) {
        scriptTask?.cancel()
        performanceMonitor.cancel()
        scriptTask = Task { @MainActor in
            beginMeasurement(workloadID: "W1-\(script.identifier)")
            actionMessage = "脚本 \(script.title) 运行中"
            let steps = script.steps(itemCount: items.count)
            for step in steps {
                guard !Task.isCancelled else {
                    performanceMonitor.cancel()
                    return
                }
                switch host {
                case .swiftUI:
                    proxy.scrollTo(step.target, anchor: step.anchor)
                case .uiKit:
                    issueUIKitScroll(item: step.target, anchor: step.anchor)
                }
                try? await Task.sleep(nanoseconds: step.pauseNanoseconds)
            }
            guard !Task.isCancelled else {
                performanceMonitor.cancel()
                return
            }
            finishMeasurement(prefix: "脚本 \(script.title) 已完成")
        }
    }

    private func beginMeasurement(workloadID: String) {
        performanceMonitor.begin(
            workloadID: workloadID,
            host: host,
            layout: layout,
            itemCount: itemCount,
            uniqueAssetCount: uniqueAssetCount
        )
    }

    private func finishMeasurement(prefix: String) {
        guard let snapshot = performanceMonitor.finish() else {
            actionMessage = prefix
            return
        }
        model.recordPerformanceSnapshot(snapshot)
        let delta = snapshot.peakFootprintDeltaBytes.map(Self.formatBytes) ?? "无数据"
        actionMessage =
            "\(prefix) · 卡顿代理 \(snapshot.hitchCount) · 最长间隔 \(String(format: "%.1f", snapshot.maximumFrameIntervalMilliseconds)) 毫秒 · 内存占用 +\(delta)"
    }

    private func cancelActiveMeasurement(reason: String) {
        guard performanceMonitor.isMeasuring else { return }
        performanceMonitor.cancel()
        actionMessage = "测量已取消：\(reason)"
    }

    private var peakRSSDeltaTitle: String {
        guard let initial = performanceMonitor.initialPhysicalFootprintBytes,
            let peak = performanceMonitor.peakPhysicalFootprintBytes
        else { return "—" }
        return Self.formatBytes(peak >= initial ? peak - initial : 0)
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    private func issueUIKitScroll(item: Int, anchor: UnitPoint) {
        let mappedAnchor: UIKitFeedScrollCommand.Anchor
        if anchor == .top {
            mappedAnchor = .top
        } else if anchor == .bottom {
            mappedAnchor = .bottom
        } else {
            mappedAnchor = .center
        }
        uiKitCommandGeneration += 1
        uiKitScrollCommand = UIKitFeedScrollCommand(
            generation: uiKitCommandGeneration,
            item: item,
            anchor: mappedAnchor
        )
    }
}
