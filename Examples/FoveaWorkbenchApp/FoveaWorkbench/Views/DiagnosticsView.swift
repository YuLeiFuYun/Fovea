import FoveaCore
import SwiftUI
import UIKit

/// 将有界结构化诊断转换为过滤、汇总和时间线，而不展示自由文本错误。
/// 丢弃计数单独可见，避免环形缓冲区覆盖被误认为“没有事件”。
struct DiagnosticsView: View {
    var body: some View {
        NavigationView {
            DiagnosticsContentView()
        }
        .navigationViewStyle(.stack)
    }
}

struct DiagnosticsContentView: View {
    @EnvironmentObject private var model: WorkbenchAppModel
    @State private var filter = DiagnosticFilter.all
    @State private var actionMessage = "尚未执行诊断维护操作"

    var body: some View {
        List {
            Section {
                DiagnosticSummary(
                    events: model.diagnosticEvents, dropped: model.droppedDiagnosticEvents)
            } footer: {
                Text("先查看失败、缓存命中和共享任务摘要；只有定位问题时才需要逐条阅读时间线。")
            }

            Section("操作结果") {
                WorkbenchActionStatus(
                    message: actionMessage,
                    identifier: "diagnostics.action-status"
                )
            }

            Section("筛选") {
                Picker("事件", selection: $filter) {
                    ForEach(DiagnosticFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("diagnostics.filter")
            }

            Section("时间线") {
                if filteredEvents.isEmpty {
                    Text("当前筛选下没有事件")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(filteredEvents.reversed(), id: \.sequence) { item in
                        DiagnosticEventRow(item: item)
                    }
                }
            }

            Section("确定性源站") {
                if model.originRequestCounts.isEmpty {
                    Text("尚无确定性源站请求；真实公网请求只通过脱敏管线事件呈现。")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(model.originRequestCounts.keys.sorted(), id: \.self) { path in
                        HStack {
                            Text(path).font(.caption.monospaced())
                            Spacer()
                            Text(String(model.originRequestCounts[path, default: 0]))
                                .font(.caption.monospaced().weight(.semibold))
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("管线诊断")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = model.diagnosticsJSON()
                    actionMessage = "已复制\(model.diagnosticEvents.count)条诊断事件"
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("复制诊断 JSON")
                .accessibilityIdentifier("diagnostics.copy")

                Button(role: .destructive) {
                    Task {
                        await model.clearDiagnostics()
                        actionMessage = "诊断时间线已清空"
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("清空诊断")
                .accessibilityIdentifier("diagnostics.clear")
            }
        }
    }

    private var filteredEvents: [RecordedDiagnosticEvent] {
        model.diagnosticEvents.filter { filter.includes($0.event) }
    }
}

private enum DiagnosticFilter: String, CaseIterable, Identifiable {
    case all
    case failures
    case network
    case cache
    case decode

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部"
        case .failures: "失败"
        case .network: "网络"
        case .cache: "缓存"
        case .decode: "解码"
        }
    }

    func includes(_ event: DiagnosticEvent) -> Bool {
        switch self {
        case .all:
            return true
        case .failures:
            return event.failureCategory != nil
                || [
                    .fetchFailed, .decodeFailed, .pipelineFailed, .cacheReadFailed,
                    .cacheWriteFailed,
                ]
                .contains(event.kind)
        case .network:
            return [
                .fetchQueued, .fetchStarted, .fetchJoined, .fetchCompleted, .fetchRetryScheduled,
                .fetchCancelled, .fetchFailed, .responseAnomaly,
            ].contains(event.kind)
        case .cache:
            return [
                .originalEncodedHit, .renderedMemoryHit, .renderedMemoryPurged, .cacheReadFailed,
                .cacheWriteFailed, .staleFallbackUsed,
            ].contains(event.kind)
        case .decode:
            return [
                .decodeQueued, .decodeJoined, .decodeStarted, .decodeWorkingSetReserved,
                .decodeAdmissionRejected, .decodeCompleted, .decodeCancelled, .decodeFailed,
            ].contains(event.kind)
        }
    }
}

private struct DiagnosticSummary: View {
    let events: [RecordedDiagnosticEvent]
    let dropped: Int

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                MetricCard(
                    title: "事件", value: String(events.count), symbol: "list.bullet.rectangle")
                MetricCard(
                    title: "失败", value: String(failureCount), symbol: "exclamationmark.triangle")
            }
            HStack(spacing: 12) {
                MetricCard(
                    title: "网络共享", value: String(kindCount(.fetchJoined)),
                    symbol: "arrow.triangle.merge")
                MetricCard(title: "丢弃", value: String(dropped), symbol: "trash.slash")
            }
        }
        .padding(.vertical, 4)
    }

    private var failureCount: Int {
        events.filter { $0.event.failureCategory != nil }.count
    }

    private func kindCount(_ kind: DiagnosticEventKind) -> Int {
        events.filter { $0.event.kind == kind }.count
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack {
            Image(systemName: symbol).foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.title3.monospacedDigit().weight(.bold))
                Text(title).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct DiagnosticEventRow: View {
    let item: RecordedDiagnosticEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(eventTitle)
                        .font(.callout.weight(.semibold))
                    Text(item.event.kind.rawValue)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(elapsed)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                if let reason = item.event.reason {
                    Label(reason, systemImage: "exclamationmark.circle")
                }
                if let status = item.event.statusCode {
                    Label(String(status), systemImage: "123.rectangle")
                }
                if let duration = item.event.durationNanoseconds {
                    Label("\(duration / 1_000_000) 毫秒", systemImage: "timer")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            if let digest = item.event.keyDigest {
                Text(String(digest.prefix(16)))
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var eventTitle: String {
        switch item.event.kind {
        case .fetchQueued: "等待网络许可"
        case .fetchStarted: "开始下载图片"
        case .fetchJoined: "加入已有下载"
        case .fetchRetryScheduled: "安排有限重试"
        case .fetchCompleted: "图片下载完成"
        case .fetchCancelled: "图片下载已取消"
        case .fetchFailed: "图片下载失败"
        case .decodeQueued: "等待解码许可"
        case .decodeJoined: "加入已有解码"
        case .decodeStarted: "开始解码图片"
        case .containerInspectionCompleted: "容器安全检查完成"
        case .imageSourceCreationCompleted: "图像源创建完成"
        case .imageSourceTypeCompleted: "图像格式识别完成"
        case .imageFrameCountCompleted: "图像帧数检查完成"
        case .imagePropertiesReadCompleted: "图像属性读取完成"
        case .probeValidationCompleted: "图像探测验证完成"
        case .probeCompleted: "图像探测完成"
        case .decodeWorkingSetReserved: "已预留解码内存"
        case .decodeAdmissionRejected: "解码资源不足"
        case .rasterSourceCreationCompleted: "栅格图像源创建完成"
        case .rasterSourceTypeCompleted: "栅格图像格式检查完成"
        case .rasterFrameCountCompleted: "栅格帧数检查完成"
        case .rasterImageCreationCompleted: "栅格像素创建完成"
        case .rasterPostProcessingCompleted: "栅格后处理完成"
        case .rasterDecodeCompleted: "栅格解码完成"
        case .decodeCompleted: "图片解码完成"
        case .decodeCancelled: "图片解码已取消"
        case .decodeFailed: "图片解码失败"
        case .originalEncodedHit: "从磁盘读取原图"
        case .originalCommitPrepared: "原图提交已准备"
        case .originalCommitPublished: "原图提交已发布"
        case .renderedPublished: "渲染结果已发布"
        case .encodedHandoffStarted: "编码数据交接开始"
        case .encodedHandoffStored: "编码数据交接已存储"
        case .encodedHandoffHit: "命中编码数据交接"
        case .encodedHandoffRejected: "编码数据交接被拒绝"
        case .renderedMemoryHit: "从内存直接显示"
        case .renderedMemoryPurged: "已清理内存图片"
        case .cacheReadFailed: "缓存读取降级"
        case .cacheWriteFailed: "缓存写入降级"
        case .responseAnomaly: "服务器响应异常"
        case .staleFallbackUsed: "使用过期缓存回退"
        case .namespaceRevoked: "账户内容已撤销"
        case .pipelineSucceeded: "图片管线完成"
        case .pipelineFailed: "图片管线失败"
        case .diagnosticsDropped: "诊断事件被有界丢弃"
        }
    }

    private var elapsed: String {
        String(format: "+%.3fs", Double(item.elapsedNanoseconds) / 1_000_000_000)
    }
}
