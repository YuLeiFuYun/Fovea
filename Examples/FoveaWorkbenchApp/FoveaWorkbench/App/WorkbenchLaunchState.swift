import Foundation

/// 解析一次启动所需的配置和缓存根，避免把环境探测塞进主状态容器。
struct WorkbenchLaunchState {
    let configuration: WorkbenchConfiguration
    let cacheRoot: URL

    static func resolve(
        configurationStore: UserDefaults,
        configurationKey: String,
        overrideCacheRoot: URL?
    ) -> WorkbenchLaunchState {
        let isUITesting = isUITestLaunch
        if isUITesting {
            configurationStore.removeObject(forKey: configurationKey)
        }

        let configuration: WorkbenchConfiguration
        if let data = configurationStore.data(forKey: configurationKey),
            let decoded = try? JSONDecoder().decode(WorkbenchConfiguration.self, from: data)
        {
            configuration = decoded.normalized()
        } else {
            configuration = isUITesting ? .deterministicDefaults : .defaults
        }

        if let overrideCacheRoot {
            return WorkbenchLaunchState(configuration: configuration, cacheRoot: overrideCacheRoot)
        }

        let caches =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        if isUITesting {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("FoveaWorkbenchUITests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            return WorkbenchLaunchState(configuration: configuration, cacheRoot: root)
        }
        return WorkbenchLaunchState(
            configuration: configuration,
            cacheRoot: caches.appendingPathComponent("FoveaWorkbench", isDirectory: true)
        )
    }
    private static var isUITestLaunch: Bool {
        #if DEBUG
            ProcessInfo.processInfo.arguments.contains("--ui-testing")
        #else
            false
        #endif
    }
}
