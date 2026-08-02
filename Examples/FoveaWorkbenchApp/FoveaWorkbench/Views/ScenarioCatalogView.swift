import SwiftUI

/// 以可搜索问题域组织验证任务，并公开各能力的证据覆盖情况。
/// 目录使用稳定 Lab ID；分组标题和说明可自由重写而不破坏自动化。
struct ScenarioCatalogView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var query = ""
    @State private var selectedLabID = WorkbenchLabCatalog.all.first?.id

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationView {
                    catalog
                    destination(for: selectedLab)
                }
                .navigationViewStyle(.columns)
            } else {
                NavigationView { catalog }
                    .navigationViewStyle(.stack)
            }
        }
    }

    private var catalog: some View {
        List {
            introduction

            if query.isEmpty {
                recommendedPaths
            }

            ForEach(WorkbenchLabCategory.allCases) { category in
                let labs = filteredLabs(in: category)
                if !labs.isEmpty {
                    Section {
                        ForEach(labs) { lab in
                            labNavigation(lab)
                        }
                    } header: {
                        Label(category.title, systemImage: category.symbol)
                    } footer: {
                        if category == .environment {
                            Text("真实网络用于验证 DNS、TLS、代理、重定向和 CDN；第三方服务故障不会自动判为核心回归。")
                        }
                    }
                }
            }

            if filteredLabs.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text("没有匹配的验证场景")
                            .font(.headline)
                        Text("可搜索产品任务、协议名称、失败类型或能力关键词。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("验证中心")
        .searchable(text: $query, prompt: "搜索任务、协议或失败场景")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink(destination: WorkbenchCoverageMatrixView()) {
                    Image(systemName: "checklist")
                }
                .accessibilityLabel("查看覆盖矩阵")
            }
        }
    }

    private var introduction: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("从问题出发，而不是从内部类型出发。")
                    .font(.headline)
                Text("选择你要验证的用户行为：图片是否正确显示、缓存是否可信、滚动是否浪费资源、账户是否隔离，或失败是否可以解释。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 5)
        }
    }

    private var recommendedPaths: some View {
        Section("推荐路径") {
            validationPath(
                title: "第一次了解 Fovea",
                detail: "真实界面 → 单图几何 → 滚动 Feed",
                symbol: "sparkles",
                labID: "product-patterns"
            )
            validationPath(
                title: "检查缓存是否正确",
                detail: "冷载、复用、304、Vary 与 no-store",
                symbol: "externaldrive.badge.checkmark",
                labID: "cache-identity"
            )
            validationPath(
                title: "检查隐私与账户隔离",
                detail: "双账户、错误凭证、撤销和清理",
                symbol: "person.2.badge.key",
                labID: "authentication-isolation"
            )
        }
    }

    @ViewBuilder
    private func validationPath(
        title: String,
        detail: String,
        symbol: String,
        labID: String
    ) -> some View {
        if let lab = WorkbenchLabCatalog.lab(id: labID) {
            if horizontalSizeClass == .regular {
                Button {
                    selectedLabID = lab.id
                } label: {
                    pathLabel(title: title, detail: detail, symbol: symbol)
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(destination: destination(for: lab)) {
                    pathLabel(title: title, detail: detail, symbol: symbol)
                }
            }
        }
    }

    private func pathLabel(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func labNavigation(_ lab: WorkbenchLab) -> some View {
        if horizontalSizeClass == .regular {
            Button {
                selectedLabID = lab.id
            } label: {
                WorkbenchLabRow(lab: lab, isSelected: selectedLabID == lab.id)
            }
            .buttonStyle(.plain)
            .listRowBackground(
                selectedLabID == lab.id ? Color.accentColor.opacity(0.10) : Color.clear
            )
            .accessibilityIdentifier("lab.\(lab.id)")
        } else {
            NavigationLink(destination: destination(for: lab)) {
                WorkbenchLabRow(lab: lab, isSelected: false)
            }
            .accessibilityIdentifier("lab.\(lab.id)")
        }
    }

    @ViewBuilder
    private func destination(for lab: WorkbenchLab?) -> some View {
        if let lab {
            switch lab.presentation {
            case .productPatterns:
                ProductPatternsLabView(lab: lab)
            case .singleImage:
                SingleImageLabView(lab: lab)
            case .cacheIdentity:
                CacheIdentityLabView(lab: lab)
            case .authentication:
                AuthenticationLabView(lab: lab)
            case .concurrency:
                ConcurrencyLabView(lab: lab)
            case .feed:
                FeedStressView(
                    scenario: lab.scenarios.first ?? WorkbenchScenarioCatalog.fallback,
                    initialLayout: .list
                )
            case .failureMatrix:
                FailureMatrixLabView(lab: lab)
            case .liveNetwork:
                LiveNetworkLabView(lab: lab)
            }
        } else {
            CatalogPlaceholderView()
        }
    }

    private var selectedLab: WorkbenchLab? {
        selectedLabID.flatMap(WorkbenchLabCatalog.lab(id:)) ?? WorkbenchLabCatalog.all.first
    }

    private var filteredLabs: [WorkbenchLab] {
        WorkbenchLabCatalog.all.filter(matchesQuery)
    }

    private func filteredLabs(in category: WorkbenchLabCategory) -> [WorkbenchLab] {
        filteredLabs.filter { $0.category == category }
    }

    private func matchesQuery(_ lab: WorkbenchLab) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        let content = [
            lab.title,
            lab.summary,
            lab.category.title,
            lab.capabilities.joined(separator: " "),
            lab.scenarios.map(\.title).joined(separator: " "),
            lab.scenarios.flatMap(\.tags).joined(separator: " "),
        ].joined(separator: " ").lowercased()
        return content.contains(normalized)
    }
}

private struct CatalogPlaceholderView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 42))
                .foregroundColor(.accentColor)
            Text("选择一个验证任务")
                .font(.title2.weight(.semibold))
            Text("每个页面都包含目标、操作、视觉结果和可复查证据。")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .navigationTitle("验证详情")
        .accessibilityIdentifier("catalog.detail-placeholder")
    }
}

private struct WorkbenchLabRow: View {
    let lab: WorkbenchLab
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: lab.symbol)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(lab.title).font(.headline)
                    Spacer(minLength: 8)
                    Text("\(lab.scenarios.count) 场景")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Text(lab.summary)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct WorkbenchCoverageMatrixView: View {
    @State private var query = ""

    var body: some View {
        List {
            ForEach(filteredLabs) { lab in
                Section {
                    ForEach(lab.scenarios) { scenario in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(scenario.title)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: outcomeSymbol(scenario.expectedOutcome))
                                    .foregroundColor(outcomeColor(scenario.expectedOutcome))
                            }
                            Text(scenario.summary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(scenario.expectedOutcome.title)
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                } header: {
                    Label(lab.title, systemImage: lab.symbol)
                }
            }
        }
        .navigationTitle("覆盖矩阵")
        .searchable(text: $query, prompt: "搜索覆盖场景")
    }

    private var filteredLabs: [WorkbenchLab] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return WorkbenchLabCatalog.all }
        return WorkbenchLabCatalog.all.compactMap { lab in
            let scenarios = lab.scenarios.filter {
                [$0.title, $0.summary, $0.tags.joined(separator: " ")]
                    .joined(separator: " ")
                    .lowercased()
                    .contains(normalized)
            }
            guard !scenarios.isEmpty else { return nil }
            return WorkbenchLab(
                id: lab.id,
                title: lab.title,
                summary: lab.summary,
                category: lab.category,
                symbol: lab.symbol,
                scenarioIDs: scenarios.map(\.id),
                presentation: lab.presentation,
                capabilities: lab.capabilities
            )
        }
    }

    private func outcomeSymbol(_ outcome: WorkbenchExpectedOutcome) -> String {
        switch outcome {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        case .environmentDependent: "globe"
        }
    }

    private func outcomeColor(_ outcome: WorkbenchExpectedOutcome) -> Color {
        switch outcome {
        case .success: .green
        case .failure: .orange
        case .environmentDependent: .blue
        }
    }
}
