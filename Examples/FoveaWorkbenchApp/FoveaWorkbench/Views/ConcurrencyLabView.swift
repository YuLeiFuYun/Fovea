import SwiftUI

/// 将单航班合并的并发机制转成可操作实验，并同时展示请求进度与证据闭环。
struct ConcurrencyLabView: View {
    @EnvironmentObject private var model: WorkbenchAppModel
    let lab: WorkbenchLab
    @State private var actionMessage = "尚未执行并发验证"

    private var scenario: WorkbenchScenario {
        lab.scenarios.first ?? WorkbenchScenarioCatalog.fallback
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WorkbenchLabHeader(lab: lab)
                convergenceDiagram
                experimentControls
                requestProgress
                WorkbenchLatestRunCard(
                    record: latestRecord,
                    expected: expectations
                )
            }
            .padding(20)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(lab.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("lab.single-flight")
    }

    private var convergenceDiagram: some View {
        WorkbenchSectionCard(title: "多个订阅者，只做一次昂贵工作") {
            HStack(alignment: .center, spacing: 10) {
                requestStack
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                VStack(spacing: 5) {
                    Image(systemName: "network")
                        .font(.title2)
                        .foregroundColor(.blue)
                    Text("1 次网络获取")
                        .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                VStack(spacing: 5) {
                    Image(systemName: "photo.stack")
                        .font(.title2)
                        .foregroundColor(.green)
                    Text("共享结果")
                        .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
            }

            Text("所有订阅者使用完全相同的请求身份。正确实现会合并网络获取与解码，同时保留每个订阅者独立取消的能力。")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var requestStack: some View {
        VStack(spacing: 3) {
            ForEach(0..<min(5, model.draftConfiguration.burstCount), id: \.self) { index in
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle")
                    Text("#\(index + 1)")
                }
                .font(.caption2.monospacedDigit())
            }
            if model.draftConfiguration.burstCount > 5 {
                Text("+\(model.draftConfiguration.burstCount - 5)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var experimentControls: some View {
        WorkbenchSectionCard(title: "实验规模") {
            WorkbenchActionStatus(message: actionMessage, identifier: "concurrency.action-status")

            Stepper(
                "并发订阅者：\(model.draftConfiguration.burstCount)",
                value: $model.draftConfiguration.burstCount,
                in: 2...32
            )
            .accessibilityIdentifier("concurrency.count")

            HStack(spacing: 10) {
                Button {
                    Task {
                        await model.resetEvidence()
                        actionMessage = "并发验证证据已清空"
                    }
                } label: {
                    Label("清空证据", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("concurrency.reset-evidence")

                Button {
                    if model.run(scenario, count: model.draftConfiguration.burstCount) != nil {
                        actionMessage = "并发请求已提交，等待共享任务证据"
                    }
                } label: {
                    Label("开始并发请求", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isReady || latestRecord?.state == .running)
                .accessibilityIdentifier("concurrency.run")

                if let record = latestRecord, record.state == .running {
                    Button(role: .destructive) {
                        model.cancelRun(record.id)
                        actionMessage = "当前并发验证已取消"
                    } label: {
                        Label("取消", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("concurrency.cancel")
                }
            }
        }
    }

    // 此视图只投影模型产生的运行记录；不得用本地计数或动画伪造 join、origin 或完成证据。
    @ViewBuilder
    private var requestProgress: some View {
        if let record = latestRecord {
            WorkbenchSectionCard(title: "订阅者完成情况") {
                HStack {
                    Text("\(record.completedCount) / \(record.requestCount)")
                        .font(.title2.monospacedDigit().weight(.bold))
                    Spacer()
                    Text(record.state.title)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(record.state.isUnexpected ? .red : .secondary)
                }

                ProgressView(
                    value: Double(record.completedCount),
                    total: Double(max(1, record.requestCount))
                )

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 38), spacing: 8)], spacing: 8) {
                    ForEach(0..<record.requestCount, id: \.self) { index in
                        Image(
                            systemName: index < record.completedCount
                                ? "checkmark.circle.fill" : "circle.dotted"
                        )
                        .font(.title3)
                        .foregroundColor(index < record.completedCount ? .green : .secondary)
                        .accessibilityLabel("订阅者 \(index + 1)")
                    }
                }
            }
        }
    }

    private var latestRecord: WorkbenchRunRecord? {
        model.latestRun(for: scenario.id)
    }

    private var expectations: [WorkbenchExpectation] {
        [
            WorkbenchExpectation("complete", title: "全部订阅者收到结果", rule: .completed),
            WorkbenchExpectation(
                "origin", title: "网络请求最多一次", rule: .originAtMost(1)),
            WorkbenchExpectation(
                "join",
                title: "其余订阅者加入共享网络获取",
                rule: .fetchJoinedAtLeast(max(1, model.draftConfiguration.burstCount - 1))
            ),
            WorkbenchExpectation("cache", title: "缓存写入未降级", rule: .noCacheWriteFailure),
        ]
    }
}
