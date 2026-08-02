import SwiftUI

@main
struct FoveaWorkbenchApp: App {
    @StateObject private var model = WorkbenchAppModel()

    var body: some Scene {
        WindowGroup {
            WorkbenchAppHost {
                launchContent
            }
            .environmentObject(model)
        }
    }

    @ViewBuilder
    private var launchContent: some View {
        #if DEBUG
            if let destination = WorkbenchUITestRoute.destination {
                switch destination {
                case .story(let story, let contractFirst):
                    NavigationView {
                        EcologicalStoryView(
                            story: story,
                            document: .current,
                            contractFirstForUITesting: contractFirst
                        )
                    }
                    .navigationViewStyle(.stack)
                case .studio:
                    NavigationView {
                        WorkbenchScenarioStudioView()
                    }
                    .navigationViewStyle(.stack)
                }
            } else {
                WorkbenchRootView()
            }
        #else
            WorkbenchRootView()
        #endif
    }
}

private struct WorkbenchAppHost<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: WorkbenchAppModel

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .overlay(alignment: .topLeading) {
                Text(runtimeAccessibilityValue)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("图片管线状态")
                    .accessibilityValue(runtimeAccessibilityValue)
                    .accessibilityIdentifier("runtime.state")
            }
            .task { await model.start() }
            .onChange(of: scenePhase) { phase in
                model.setApplicationActive(phase == .active)
            }
            .alert(
                "Fovea Workbench 操作失败",
                isPresented: Binding(
                    get: { model.presentedErrorMessage != nil },
                    set: { presented in
                        if !presented { model.dismissPresentedError() }
                    }
                )
            ) {
                if model.pipeline == nil {
                    Button("重试") { Task { await model.applyConfiguration() } }
                }
                Button("关闭", role: .cancel) { model.dismissPresentedError() }
            } message: {
                if let message = model.presentedErrorMessage {
                    Text(message)
                }
            }
    }

    private var runtimeAccessibilityValue: String {
        switch model.runtimeState {
        case .idle: "idle"
        case .opening: "opening"
        case .ready: "ready"
        case .failed: "failed"
        }
    }
}

#if DEBUG
    /// UI 自动化可直接进入目标专题或场景工坊，避免把不相关的导航长尾混入行为验证。
    /// 整个路由从 Release 编译中移除，启动参数不能在发布构建中暴露隐藏导航。
    private enum WorkbenchUITestRoute {
        enum Destination {
            case story(EcologicalStory, contractFirst: Bool)
            case studio
        }

        static var destination: Destination? {
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("--ui-testing") else { return nil }
            if arguments.contains("--ui-studio") {
                return .studio
            }
            guard let marker = arguments.firstIndex(of: "--ui-story"),
                arguments.indices.contains(marker + 1),
                let story = EcologicalAtlasDocument.current.storiesByID[arguments[marker + 1]]
            else { return nil }
            return .story(
                story,
                contractFirst: arguments.contains("--ui-contract-first")
            )
        }
    }
#endif
