import UIKit

@main
@MainActor
final class AsyncImageBenchmarkAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool { true }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "AsyncImage Benchmark",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = AsyncImageBenchmarkSceneDelegate.self
        return configuration
    }
}

@MainActor
final class AsyncImageBenchmarkSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var task: Task<Void, Never>?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        task = Task { @MainActor in
            do {
                let arguments = try AsyncImageBenchmarkArguments(
                    arguments: ProcessInfo.processInfo.arguments
                )
                try await AsyncImageBenchmarkCoordinator.run(
                    arguments: arguments,
                    window: window
                )
                fflush(stdout)
                exit(EXIT_SUCCESS)
            } catch {
                NSLog("FOVEA_ASYNCIMAGE_FAILURE=%@", String(describing: error))
                print("FOVEA_ASYNCIMAGE_FAILURE=\(String(describing: error))")
                fflush(stdout)
                exit(EXIT_FAILURE)
            }
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        task?.cancel()
        task = nil
    }
}
