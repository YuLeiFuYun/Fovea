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
                status.loadViewIfNeeded()
                status.update("FAILED\n\(String(describing: error))")
                NSLog("FOVEA_COMPARATIVE_FAILURE=%@", String(describing: error))
                print("FOVEA_COMPARATIVE_FAILURE=\(String(describing: error))")
                fflush(stdout)
                exit(EXIT_FAILURE)
            }
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        benchmarkTask?.cancel()
        benchmarkTask = nil
    }
}
