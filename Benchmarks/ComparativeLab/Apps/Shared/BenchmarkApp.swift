import Darwin
import UIKit

@main
@MainActor
final class ComparativeBenchmarkAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Comparative Benchmark",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = ComparativeBenchmarkSceneDelegate.self
        return configuration
    }
}

@MainActor
final class ComparativeBenchmarkSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var benchmarkTask: Task<Void, Never>?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let status = BenchmarkStatusViewController()
        window.rootViewController = status
        window.makeKeyAndVisible()
        self.window = window
        benchmarkTask = Task { @MainActor in
            do {
                let arguments = try BenchmarkArguments(arguments: ProcessInfo.processInfo.arguments)
                status.loadViewIfNeeded()
                status.update(
                    "\(BenchmarkAdapterFactory.comparatorName)\n\(arguments.workload.rawValue)\n\(arguments.cacheState.rawValue)"
                )
                try await BenchmarkCoordinator.run(arguments: arguments, window: window)
                fflush(stdout)
                exit(EXIT_SUCCESS)
            } catch {
                let message = String(describing: error)
                status.loadViewIfNeeded()
                status.update("FAILED\n\(message)")
                Self.writeFailureArtifact(message)
                NSLog("FOVEA_COMPARATIVE_FAILURE=%@", message)
                print("FOVEA_COMPARATIVE_FAILURE=\(message)")
                fflush(stdout)
                exit(EXIT_FAILURE)
            }
        }
    }

    private static func writeFailureArtifact(_ message: String) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let outputIndex = arguments.firstIndex(of: "--output"),
            arguments.indices.contains(outputIndex + 1)
        else { return }
        let outputName = arguments[outputIndex + 1]
        guard !outputName.contains("/"), outputName.hasSuffix(".json") else { return }
        guard
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first
        else { return }
        let failureURL = documents.appendingPathComponent(outputName + ".failure")
        try? Data(message.utf8).write(to: failureURL, options: .atomic)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        benchmarkTask?.cancel()
        benchmarkTask = nil
    }
}
