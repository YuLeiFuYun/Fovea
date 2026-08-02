import SwiftUI

/// 将常用体验设置与高风险开发者资源参数分层呈现。
/// 只有影响组合身份的设置才重建管线，其余请求设置只刷新显示身份。
struct WorkbenchSettingsView: View {
    @EnvironmentObject private var model: WorkbenchAppModel
    @State private var actionMessage = "尚未应用设置或执行维护操作"

    var body: some View {
        NavigationView {
            Form {
                applySection
                experienceSection
                    .disabled(model.runtimeState == .opening)
                displaySection
                    .disabled(model.runtimeState == .opening)
                requestSection
                    .disabled(model.runtimeState == .opening)
                maintenanceSection
                    .disabled(!model.isReady)
                developerSection
                    .disabled(model.runtimeState == .opening)
                aboutSection
            }
            .navigationTitle("设置")
        }
        .navigationViewStyle(.stack)
    }

    private var applySection: some View {
        Section("操作结果") {
            WorkbenchActionStatus(
                message: actionMessage,
                identifier: "settings.action-status"
            )
            HStack {
                Label("图片管线状态", systemImage: "bolt.horizontal.circle")
                Spacer()
                Text(runtimeTitle)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("图片管线状态")
            .accessibilityValue(runtimeTitle)
            .accessibilityIdentifier("settings.runtime-state")

            Button {
                Task {
                    await model.applyConfiguration()
                    actionMessage = "设置已应用到当前图片管线"
                }
            } label: {
                Label("应用更改", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(WorkbenchActionButtonStyle(.primary))
            .disabled(!model.hasUnappliedConfiguration || model.runtimeState == .opening)
            .accessibilityIdentifier("settings.apply")
        }
    }

    private var experienceSection: some View {
        Section {
            Toggle("使用真实网络图片", isOn: $model.draftConfiguration.externalNetworkingEnabled)
                .accessibilityIdentifier("settings.external-network")

            if model.draftConfiguration.externalNetworkingEnabled {
                Label(
                    "画廊和 Feed 将访问 Wikimedia Commons 等真实 HTTPS origin。",
                    systemImage: "network"
                )
                .font(.caption)
                .foregroundColor(.secondary)
            } else {
                Label(
                    "使用内置确定性 origin，适合离线演示和可重复协议测试。",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundColor(.orange)
            }

            HStack {
                Label("当前网络", systemImage: "antenna.radiowaves.left.and.right")
                Spacer()
                Text("\(model.network.status) · \(model.network.interface)")
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("体验模式")
        } footer: {
            Text("真实网络结果受 DNS、代理、VPN、TLS、CDN 和第三方服务状态影响；确定性模式不代表真实网络质量。")
        }
    }

    private var displaySection: some View {
        Section("显示") {
            Picker("内容模式", selection: $model.draftConfiguration.contentMode) {
                ForEach(WorkbenchContentMode.allCases) { value in
                    Text(value.title).tag(value)
                }
            }

            Picker("身份替换", selection: $model.draftConfiguration.retentionMode) {
                ForEach(WorkbenchRetentionMode.allCases) { value in
                    Text(value.title).tag(value)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("淡入过渡")
                    Spacer()
                    Text(String(format: "%.2f 秒", model.draftConfiguration.transitionDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Slider(value: $model.draftConfiguration.transitionDuration, in: 0...1, step: 0.05)
            }
        }
    }

    private var requestSection: some View {
        Section {
            Picker("优先级", selection: $model.draftConfiguration.requestPriority) {
                ForEach(WorkbenchRequestPriority.allCases) { value in
                    Text(value.title).tag(value)
                }
            }

            Picker("网络权限", selection: $model.draftConfiguration.networkMode) {
                ForEach(WorkbenchNetworkMode.allCases) { value in
                    Text(value.title).tag(value)
                }
            }

            Picker("缓存策略", selection: $model.draftConfiguration.cacheMode) {
                ForEach(WorkbenchCacheMode.allCases) { value in
                    Text(value.title).tag(value)
                }
            }

            Toggle("网络失败时允许使用过期缓存", isOn: $model.draftConfiguration.staleFallbackEnabled)
        } header: {
            Text("常用请求策略")
        } footer: {
            Text("高级超时、并发、队列、磁盘预算和代理验证位于“开发者参数”。")
        }
    }

    private var maintenanceSection: some View {
        Section("缓存与账户") {
            Button {
                Task {
                    await model.purgeMemory()
                    actionMessage = "内存图片缓存已清空"
                }
            } label: {
                Label("清空内存图片", systemImage: "memorychip")
            }
            .accessibilityIdentifier("settings.purge-memory")

            Button {
                Task {
                    await model.garbageCollect()
                    actionMessage = "持久缓存整理已完成"
                }
            } label: {
                Label("整理持久缓存", systemImage: "externaldrive.badge.checkmark")
            }
            .accessibilityIdentifier("settings.garbage-collect")

            Button(role: .destructive) {
                Task {
                    await model.revokePrivateNamespace()
                    actionMessage = "演示账户 A 的私有命名空间已撤销"
                }
            } label: {
                Label("撤销演示账户 A", systemImage: "person.crop.circle.badge.xmark")
            }
            .accessibilityIdentifier("settings.revoke-account-a")
        }
    }

    private var developerSection: some View {
        Section("开发者") {
            NavigationLink(destination: WorkbenchAdvancedSettingsView()) {
                Label("高级管线参数", systemImage: "slider.horizontal.3")
            }
            NavigationLink(destination: DiagnosticsContentView()) {
                Label("管线诊断时间线", systemImage: "waveform.path.ecg")
            }
            Button("恢复推荐配置") {
                model.resetConfiguration()
                actionMessage = "推荐配置已载入，等待应用"
            }
            .accessibilityIdentifier("settings.reset-configuration")
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            SettingValueRow(label: "运行时", value: runtimeTitle)
            SettingValueRow(label: "存储代际", value: model.storageGenerationIdentifier)
            SettingValueRow(label: "最低系统", value: "iOS / iPadOS 15.0")
            Text("示例应用通过官方 Fovea 产品加载图片；真实素材来自明确标注许可的公开来源，测试适配器不会进入核心库。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var runtimeTitle: String {
        switch model.runtimeState {
        case .idle: "空闲"
        case .opening: "正在初始化"
        case .ready: "就绪"
        case .failed: "失败"
        }
    }
}

private struct WorkbenchAdvancedSettingsView: View {
    @EnvironmentObject private var model: WorkbenchAppModel

    var body: some View {
        Form {
            customURLSection
            transportSection
            resourceSection
            persistentCacheSection
            identitySection
        }
        .navigationTitle("开发者参数")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var customURLSection: some View {
        Section {
            TextField("自定义 HTTPS 图片 URL", text: $model.draftConfiguration.customURL)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .keyboardType(.URL)
            Text("自定义 URL 只在当前会话中存在，不写入系统偏好存储或导出证据。")
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text("自定义真实图片")
        }
    }

    private var transportSection: some View {
        Section("URLSession 与路由") {
            Toggle("等待网络恢复", isOn: $model.draftConfiguration.waitsForConnectivity)
            Picker("代理策略", selection: $model.draftConfiguration.proxyMode) {
                ForEach(WorkbenchProxyMode.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            Stepper(
                "请求超时：\(model.draftConfiguration.requestTimeoutSeconds) 秒",
                value: requestTimeoutBinding,
                in: 1...120
            )
            Stepper(
                "资源超时：\(model.draftConfiguration.resourceTimeoutSeconds) 秒",
                value: resourceTimeoutBinding,
                in: model.draftConfiguration.requestTimeoutSeconds...300
            )
            Stepper(
                "每主机连接：\(model.draftConfiguration.maximumConnectionsPerHost)",
                value: $model.draftConfiguration.maximumConnectionsPerHost,
                in: 1...16
            )
        }
    }

    private var resourceSection: some View {
        Section("内存与并发预算") {
            Stepper(
                "渲染内存：\(model.draftConfiguration.memoryLimitMegabytes) MiB",
                value: $model.draftConfiguration.memoryLimitMegabytes,
                in: 8...512,
                step: 8
            )
            Stepper(
                "传输正文：\(model.draftConfiguration.transportLimitMegabytes) MiB",
                value: $model.draftConfiguration.transportLimitMegabytes,
                in: 1...32
            )
            Stepper(
                "内存暂存：\(model.draftConfiguration.transportMemoryThresholdKilobytes) KiB",
                value: $model.draftConfiguration.transportMemoryThresholdKilobytes,
                in: 64...4_096,
                step: 64
            )
            Stepper(
                "并发网络获取：\(model.draftConfiguration.maximumConcurrentFetches)",
                value: $model.draftConfiguration.maximumConcurrentFetches,
                in: 1...16
            )
            Stepper(
                "并发解码：\(model.draftConfiguration.maximumConcurrentDecodes)",
                value: $model.draftConfiguration.maximumConcurrentDecodes,
                in: 1...8
            )
            Stepper(
                "解码工作集：\(model.draftConfiguration.decodeWorkingSetMegabytes) MiB",
                value: $model.draftConfiguration.decodeWorkingSetMegabytes,
                in: 16...512,
                step: 16
            )
            Stepper(
                "网络获取队列：\(model.draftConfiguration.maximumQueuedFetches)",
                value: $model.draftConfiguration.maximumQueuedFetches,
                in: 0...1_024,
                step: 16
            )
            Stepper(
                "解码队列：\(model.draftConfiguration.maximumQueuedDecodes)",
                value: $model.draftConfiguration.maximumQueuedDecodes,
                in: 0...1_024,
                step: 16
            )
        }
    }

    private var persistentCacheSection: some View {
        Section("持久缓存") {
            Stepper(
                "编码缓存软上限：\(model.draftConfiguration.encodedSoftLimitMegabytes) MiB",
                value: encodedSoftLimitBinding,
                in: 16...1_024,
                step: 16
            )
            Stepper(
                "单文件上限：\(model.draftConfiguration.encodedBlobLimitMegabytes) MiB",
                value: encodedBlobLimitBinding,
                in: 1...128
            )
            if model.draftConfiguration.staleFallbackEnabled {
                Stepper(
                    "最大过期回退时长：\(model.draftConfiguration.maximumStalenessSeconds) 秒",
                    value: $model.draftConfiguration.maximumStalenessSeconds,
                    in: 1...86_400
                )
            }
        }
    }

    private var identitySection: some View {
        Section("身份与实验") {
            Picker("Vary 语言", selection: $model.draftConfiguration.varyLanguage) {
                ForEach(WorkbenchVaryLanguage.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            Stepper(
                "凭证代际：\(model.draftConfiguration.credentialGeneration)",
                value: $model.draftConfiguration.credentialGeneration,
                in: 0...999
            )
            Stepper(
                "并发请求数量：\(model.draftConfiguration.burstCount)",
                value: $model.draftConfiguration.burstCount,
                in: 2...32
            )
            Stepper(
                "命名空间上限：\(model.draftConfiguration.maximumTrackedNamespaces)",
                value: $model.draftConfiguration.maximumTrackedNamespaces,
                in: 1...16_384,
                step: 128
            )
        }
    }

    private var requestTimeoutBinding: Binding<Int> {
        Binding(
            get: { model.draftConfiguration.requestTimeoutSeconds },
            set: { value in
                model.draftConfiguration.requestTimeoutSeconds = value
                model.draftConfiguration.resourceTimeoutSeconds = max(
                    value,
                    model.draftConfiguration.resourceTimeoutSeconds
                )
            }
        )
    }

    private var resourceTimeoutBinding: Binding<Int> {
        Binding(
            get: { model.draftConfiguration.resourceTimeoutSeconds },
            set: { value in
                model.draftConfiguration.resourceTimeoutSeconds = max(
                    model.draftConfiguration.requestTimeoutSeconds,
                    value
                )
            }
        )
    }

    private var encodedSoftLimitBinding: Binding<Int> {
        Binding(
            get: { model.draftConfiguration.encodedSoftLimitMegabytes },
            set: { value in
                model.draftConfiguration.encodedSoftLimitMegabytes = value
                model.draftConfiguration.encodedBlobLimitMegabytes = min(
                    value,
                    model.draftConfiguration.encodedBlobLimitMegabytes
                )
            }
        )
    }

    private var encodedBlobLimitBinding: Binding<Int> {
        Binding(
            get: { model.draftConfiguration.encodedBlobLimitMegabytes },
            set: { value in
                model.draftConfiguration.encodedBlobLimitMegabytes = min(
                    model.draftConfiguration.encodedSoftLimitMegabytes,
                    value
                )
            }
        )
    }
}

private struct SettingValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
