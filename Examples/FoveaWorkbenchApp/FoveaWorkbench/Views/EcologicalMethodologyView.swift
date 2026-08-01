import SwiftUI

struct EcologicalMethodologyView: View {
    let document: EcologicalAtlasDocument

    var body: some View {
        List {
            Section("编辑原则") {
                ForEach(document.editorialPrinciples, id: \.self) { principle in
                    Label(principle, systemImage: "checkmark.circle")
                }
            }
            Section("证据标签") {
                ForEach(EcologicalEpistemicStatus.allCases, id: \.self) { status in
                    VStack(alignment: .leading, spacing: 5) {
                        EcologicalStatusBadge(status: status)
                        Text(status.explanation).font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
            Section("困难图像的情境审查") {
                Text(document.mediaPolicy.principle)
                Text("可进入审查：" + document.mediaPolicy.contextualTopics.joined(separator: "、"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach(document.mediaPolicy.requiredChecks, id: \.self) { item in
                    Label(item, systemImage: "checkmark.shield")
                }
            }
            Section("始终禁止") {
                ForEach(document.mediaPolicy.prohibitedUses, id: \.self) { item in
                    Label(item, systemImage: "xmark.octagon")
                }
            }
            Section("来源目录 · \(document.sources.count)") {
                ForEach(document.sources) { source in
                    EcologicalSourceRow(source: source)
                }
            }
            Section("内容边界") {
                Text("本应用不是新的综合评估，也不替代原始报告。理论框架用于组织问题，不因数学形式或引用数量自动获得共识地位。")
                Text("所有数字都必须保留统计口径、情景条件和复核日期。页面中的规范性判断明确标注，不以科学术语隐藏价值选择。")
            }
        }
        .navigationTitle("方法与来源")
        .accessibilityIdentifier("ecology.methodology.root")
    }
}
