import SwiftUI

struct WorkbenchRootView: View {
    @EnvironmentObject private var model: WorkbenchAppModel

    var body: some View {
        ZStack(alignment: .top) {
            TabView {
                EcologicalAtlasHomeView()
                    .tabItem {
                        Label("理解", systemImage: "globe.americas")
                            .accessibilityIdentifier("tab.ecology")
                    }

                ScenarioCatalogView()
                    .tabItem {
                        Label("验证", systemImage: "checkmark.seal")
                            .accessibilityIdentifier("tab.scenarios")
                    }

                ExperimentRunsView()
                    .tabItem {
                        Label("证据", systemImage: "waveform.path.ecg.rectangle")
                            .accessibilityIdentifier("tab.evidence")
                    }

                WorkbenchSettingsView()
                    .tabItem {
                        Label("设置", systemImage: "slider.horizontal.3")
                            .accessibilityIdentifier("tab.settings")
                    }
            }

            if model.runtimeState == .opening {
                RuntimeBanner(text: "正在构建 Fovea 管线…", symbol: "hourglass")
            }
        }
    }
}

private struct RuntimeBanner: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .overlay(Capsule().stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            .shadow(radius: 4, y: 2)
            .padding(.top, 8)
            .accessibilityIdentifier("runtime.banner")
    }
}
