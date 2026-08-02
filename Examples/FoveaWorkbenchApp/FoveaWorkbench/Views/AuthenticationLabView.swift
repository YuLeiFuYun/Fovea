import SwiftUI

/// 以账户切换、错误凭证和退出登录步骤验证认证内容隔离。
/// 页面只显示授权代际与结构化结果，不回显凭证值或敏感请求头。
struct AuthenticationLabView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var model: WorkbenchAppModel
    let lab: WorkbenchLab

    @State private var revisionA = UUID()
    @State private var revisionB = UUID()
    @State private var showsDeveloperIdentity = false
    @State private var actionMessage = "尚未执行账户操作"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                WorkbenchLabHeader(lab: lab)
                isolationBanner
                accountComparison
                userJourney
                resultCards
            }
            .padding(20)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(lab.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("lab.authentication")
    }

    private var isolationBanner: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "person.2.badge.key.fill")
                .font(.title2)
                .foregroundColor(.green)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("相同图片地址，也不能跨账户串图")
                    .font(.headline)
                Text("账户、权限和登录代际共同决定安全身份。退出登录后，旧账户图片必须立即不可达；物理文件可以稍后清理。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(17)
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var accountComparison: some View {
        if horizontalSizeClass == .regular {
            HStack(alignment: .top, spacing: 14) {
                accountAView
                accountBView
            }
        } else {
            VStack(spacing: 14) {
                accountAView
                accountBView
            }
        }
    }

    private var accountAView: some View {
        accountCard(
            title: "账户 A",
            subtitle: "个人空间 · 橙色私有图片",
            scenario: accountA,
            revision: revisionA,
            identifier: "auth.account-a",
            tint: .orange
        )
    }

    private var accountBView: some View {
        accountCard(
            title: "账户 B",
            subtitle: "工作空间 · 蓝色私有图片",
            scenario: accountB,
            revision: revisionB,
            identifier: "auth.account-b",
            tint: .blue
        )
    }

    private func accountCard(
        title: String,
        subtitle: String,
        scenario: WorkbenchScenario,
        revision: UUID,
        identifier: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(tint.opacity(0.15))
                    Image(systemName: "person.fill")
                        .foregroundColor(tint)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
            }

            WorkbenchImagePreview(
                scenario: scenario,
                configuration: model.activeConfiguration,
                revision: revision,
                aspectRatio: 1,
                accessibilityIdentifier: identifier
            )

            Button {
                if model.run(scenario) != nil {
                    actionMessage = "已提交\(title)的加载验证，等待证据结果"
                }
            } label: {
                Label("以 \(title) 登录并加载", systemImage: "person.crop.circle.badge.checkmark")
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .disabled(!model.isReady)
            .accessibilityIdentifier(identifier + ".run")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var userJourney: some View {
        WorkbenchSectionCard(title: "账户切换与退出") {
            WorkbenchActionStatus(message: actionMessage, identifier: "auth.action-status")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                journeyButton(
                    title: "测试错误凭证",
                    detail: "应得到明确的认证失败，不能显示 A 或 B 的私有像素。",
                    symbol: "key.slash",
                    identifier: "auth.invalid-token"
                ) {
                    if model.run(invalidAuth) != nil {
                        actionMessage = "错误凭证验证已提交，等待稳定失败证据"
                    }
                }

                journeyButton(
                    title: "退出账户 A",
                    detail: "立即撤销账户 A 的可达缓存和在途任务。",
                    symbol: "rectangle.portrait.and.arrow.right",
                    identifier: "auth.revoke-a"
                ) {
                    Task {
                        await model.revokePrivateNamespace()
                        revisionA = UUID()
                        actionMessage = "账户 A 的私有命名空间已撤销"
                    }
                }

                journeyButton(
                    title: "退出账户 B",
                    detail: "只清理账户 B，不应影响账户 A。",
                    symbol: "rectangle.portrait.and.arrow.right",
                    identifier: "auth.revoke-b"
                ) {
                    Task {
                        await model.revokePrivateNamespaceB()
                        revisionB = UUID()
                        actionMessage = "账户 B 的私有命名空间已撤销"
                    }
                }
            }

            DisclosureGroup("开发者身份代际", isExpanded: $showsDeveloperIdentity) {
                VStack(alignment: .leading, spacing: 9) {
                    Stepper(
                        "凭证代际：\(model.draftConfiguration.credentialGeneration)",
                        value: $model.draftConfiguration.credentialGeneration,
                        in: 0...999
                    )
                    Text("代际变化表示凭证已经轮换。它改变精确网络执行身份，但不会把凭证明文写入缓存键或日志。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("应用身份代际") {
                        Task {
                            await model.applyConfiguration()
                            actionMessage = "凭证代际已应用到请求身份"
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.hasUnappliedConfiguration)
                    .accessibilityIdentifier("auth.apply-generation")
                }
                .padding(.top, 8)
            }
        }
    }

    private func journeyButton(
        title: String,
        detail: String,
        symbol: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        }
        .buttonStyle(.bordered)
        .disabled(!model.isReady)
        .accessibilityIdentifier(identifier)
    }

    private var resultCards: some View {
        VStack(spacing: 14) {
            WorkbenchLatestRunCard(
                record: model.latestRun(for: accountA.id),
                expected: [
                    WorkbenchExpectation("a", title: "账户 A 加载成功", rule: .completed),
                    WorkbenchExpectation(
                        "a-cache", title: "账户 A 缓存写入正常", rule: .noCacheWriteFailure),
                ]
            )
            WorkbenchLatestRunCard(
                record: model.latestRun(for: accountB.id),
                expected: [
                    WorkbenchExpectation("b", title: "账户 B 加载成功且不串图", rule: .completed),
                    WorkbenchExpectation(
                        "b-cache", title: "账户 B 缓存写入正常", rule: .noCacheWriteFailure),
                ]
            )
            WorkbenchLatestRunCard(
                record: model.latestRun(for: invalidAuth.id),
                expected: [
                    WorkbenchExpectation(
                        "invalid",
                        title: "错误凭证按预期失败",
                        rule: .expectedFailure("unsupported-http-status")
                    )
                ]
            )
        }
    }

    private var accountA: WorkbenchScenario {
        WorkbenchScenarioCatalog.scenario(id: "authenticated-private")
            ?? WorkbenchScenarioCatalog.fallback
    }

    private var accountB: WorkbenchScenario {
        WorkbenchScenarioCatalog.scenario(id: "authenticated-account-b")
            ?? WorkbenchScenarioCatalog.fallback
    }

    private var invalidAuth: WorkbenchScenario {
        WorkbenchScenarioCatalog.scenario(id: "authenticated-invalid")
            ?? WorkbenchScenarioCatalog.fallback
    }
}
