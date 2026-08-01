import FoveaCore
import FoveaSwiftUI
import ImageCraftCore

/// Workbench 可编辑配置的持久快照，区分管线级与请求级语义。
/// 自定义 URL 和其他可能含敏感信息的会话字段不会进入 Codable 表面。
struct WorkbenchConfiguration: Codable, Equatable {
    var externalNetworkingEnabled = true
    var waitsForConnectivity = false
    var proxyMode = WorkbenchProxyMode.system
    var requestTimeoutSeconds = 20
    var resourceTimeoutSeconds = 60
    var maximumConnectionsPerHost = 4

    var memoryLimitMegabytes = 96
    var transportLimitMegabytes = 8
    var transportMemoryThresholdKilobytes = 512
    var maximumConcurrentFetches = 4
    var maximumConcurrentDecodes = 2
    var decodeWorkingSetMegabytes = 160
    var maximumQueuedFetches = 128
    var maximumQueuedDecodes = 128
    var maximumTrackedNamespaces = 4_096
    var encodedSoftLimitMegabytes = 128
    var encodedBlobLimitMegabytes = 32

    var staleFallbackEnabled = false
    var maximumStalenessSeconds = 300
    var requestPriority = WorkbenchRequestPriority.userInitiated
    var networkMode = WorkbenchNetworkMode.interactive
    var cacheMode = WorkbenchCacheMode.automatic
    var contentMode = WorkbenchContentMode.fit
    var retentionMode = WorkbenchRetentionMode.retainUntilReplacement
    var transitionDuration = 0.2
    var burstCount = 8
    var customURL = "https://raw.githubusercontent.com/github/explore/main/topics/swift/swift.png"
    var varyLanguage = WorkbenchVaryLanguage.english
    var credentialGeneration = 1

    static let defaults = WorkbenchConfiguration()

    static var deterministicDefaults: WorkbenchConfiguration {
        var value = WorkbenchConfiguration()
        value.externalNetworkingEnabled = false
        return value
    }

    var pipelineSettings: WorkbenchPipelineSettings {
        WorkbenchPipelineSettings(
            externalNetworkingEnabled: externalNetworkingEnabled,
            waitsForConnectivity: waitsForConnectivity,
            proxyMode: proxyMode,
            requestTimeoutSeconds: requestTimeoutSeconds,
            resourceTimeoutSeconds: resourceTimeoutSeconds,
            maximumConnectionsPerHost: maximumConnectionsPerHost,
            memoryLimitMegabytes: memoryLimitMegabytes,
            transportLimitMegabytes: transportLimitMegabytes,
            transportMemoryThresholdKilobytes: transportMemoryThresholdKilobytes,
            maximumConcurrentFetches: maximumConcurrentFetches,
            maximumConcurrentDecodes: maximumConcurrentDecodes,
            decodeWorkingSetMegabytes: decodeWorkingSetMegabytes,
            maximumQueuedFetches: maximumQueuedFetches,
            maximumQueuedDecodes: maximumQueuedDecodes,
            maximumTrackedNamespaces: maximumTrackedNamespaces,
            encodedSoftLimitMegabytes: encodedSoftLimitMegabytes,
            encodedBlobLimitMegabytes: encodedBlobLimitMegabytes,
            staleFallbackEnabled: staleFallbackEnabled,
            maximumStalenessSeconds: maximumStalenessSeconds,
            customURL: externalNetworkingEnabled ? customURL : nil
        )
    }

    var requestSettings: WorkbenchRequestSettings {
        WorkbenchRequestSettings(
            requestPriority: requestPriority,
            networkMode: networkMode,
            cacheMode: cacheMode,
            contentMode: contentMode,
            retentionMode: retentionMode,
            transitionDuration: transitionDuration,
            burstCount: burstCount,
            varyLanguage: varyLanguage,
            credentialGeneration: credentialGeneration
        )
    }

    func normalized() -> WorkbenchConfiguration {
        var value = self
        value.requestTimeoutSeconds = min(120, max(1, requestTimeoutSeconds))
        value.resourceTimeoutSeconds = min(
            300, max(value.requestTimeoutSeconds, resourceTimeoutSeconds))
        value.maximumConnectionsPerHost = min(16, max(1, maximumConnectionsPerHost))
        value.memoryLimitMegabytes = min(512, max(8, memoryLimitMegabytes))
        value.transportLimitMegabytes = min(32, max(1, transportLimitMegabytes))
        value.transportMemoryThresholdKilobytes = min(
            4_096, max(64, transportMemoryThresholdKilobytes))
        value.maximumConcurrentFetches = min(16, max(1, maximumConcurrentFetches))
        value.maximumConcurrentDecodes = min(8, max(1, maximumConcurrentDecodes))
        value.decodeWorkingSetMegabytes = min(512, max(16, decodeWorkingSetMegabytes))
        value.maximumQueuedFetches = min(1_024, max(0, maximumQueuedFetches))
        value.maximumQueuedDecodes = min(1_024, max(0, maximumQueuedDecodes))
        value.maximumTrackedNamespaces = min(16_384, max(1, maximumTrackedNamespaces))
        value.encodedSoftLimitMegabytes = min(1_024, max(16, encodedSoftLimitMegabytes))
        value.encodedBlobLimitMegabytes = min(
            min(128, value.encodedSoftLimitMegabytes),
            max(1, encodedBlobLimitMegabytes)
        )
        value.maximumStalenessSeconds = min(86_400, max(1, maximumStalenessSeconds))
        value.transitionDuration =
            transitionDuration.isFinite
            ? min(1, max(0, transitionDuration))
            : WorkbenchConfiguration.defaults.transitionDuration
        value.burstCount = min(32, max(2, burstCount))
        value.credentialGeneration = min(999, max(0, credentialGeneration))
        return value
    }

    // 自定义 URL 只在当前会话中存在。签名查询参数和私有主机名不得随可复现实验配置写入 UserDefaults。
    private enum CodingKeys: String, CodingKey {
        case externalNetworkingEnabled
        case waitsForConnectivity
        case proxyMode
        case requestTimeoutSeconds
        case resourceTimeoutSeconds
        case maximumConnectionsPerHost
        case memoryLimitMegabytes
        case transportLimitMegabytes
        case transportMemoryThresholdKilobytes
        case maximumConcurrentFetches
        case maximumConcurrentDecodes
        case decodeWorkingSetMegabytes
        case maximumQueuedFetches
        case maximumQueuedDecodes
        case maximumTrackedNamespaces
        case encodedSoftLimitMegabytes
        case encodedBlobLimitMegabytes
        case staleFallbackEnabled
        case maximumStalenessSeconds
        case requestPriority
        case networkMode
        case cacheMode
        case contentMode
        case retentionMode
        case transitionDuration
        case burstCount
        case varyLanguage
        case credentialGeneration
    }

    var storageProfileIdentifier: String {
        "store-v2-\(encodedSoftLimitMegabytes)-\(encodedBlobLimitMegabytes)-\(maximumTrackedNamespaces)"
    }
}

struct WorkbenchPipelineSettings: Equatable {
    let externalNetworkingEnabled: Bool
    let waitsForConnectivity: Bool
    let proxyMode: WorkbenchProxyMode
    let requestTimeoutSeconds: Int
    let resourceTimeoutSeconds: Int
    let maximumConnectionsPerHost: Int
    let memoryLimitMegabytes: Int
    let transportLimitMegabytes: Int
    let transportMemoryThresholdKilobytes: Int
    let maximumConcurrentFetches: Int
    let maximumConcurrentDecodes: Int
    let decodeWorkingSetMegabytes: Int
    let maximumQueuedFetches: Int
    let maximumQueuedDecodes: Int
    let maximumTrackedNamespaces: Int
    let encodedSoftLimitMegabytes: Int
    let encodedBlobLimitMegabytes: Int
    let staleFallbackEnabled: Bool
    let maximumStalenessSeconds: Int
    let customURL: String?
}

struct WorkbenchRequestSettings: Equatable {
    let requestPriority: WorkbenchRequestPriority
    let networkMode: WorkbenchNetworkMode
    let cacheMode: WorkbenchCacheMode
    let contentMode: WorkbenchContentMode
    let retentionMode: WorkbenchRetentionMode
    let transitionDuration: Double
    let burstCount: Int
    let varyLanguage: WorkbenchVaryLanguage
    let credentialGeneration: Int
}

enum WorkbenchProxyMode: String, CaseIterable, Codable, Identifiable {
    case system
    case verifyNoProxy

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "遵循系统代理"
        case .verifyNoProxy: "响应前验证无代理"
        }
    }
}

enum WorkbenchRequestPriority: String, CaseIterable, Codable, Identifiable {
    case background
    case low
    case normal
    case high
    case userInitiated

    var id: String { rawValue }
    var title: String {
        switch self {
        case .background: "后台"
        case .low: "低"
        case .normal: "普通"
        case .high: "高"
        case .userInitiated: "用户发起"
        }
    }

    var value: ImageRequestPriority {
        switch self {
        case .background: .background
        case .low: .low
        case .normal: .normal
        case .high: .high
        case .userInitiated: .userInitiated
        }
    }
}

enum WorkbenchNetworkMode: String, CaseIterable, Codable, Identifiable {
    case interactive
    case conservative
    case wifiOnly

    var id: String { rawValue }
    var title: String {
        switch self {
        case .interactive: "交互"
        case .conservative: "节流"
        case .wifiOnly: "禁用蜂窝"
        }
    }

    var value: ImageRequestNetworkPolicy {
        switch self {
        case .interactive:
            .interactive
        case .conservative:
            .conservative
        case .wifiOnly:
            ImageRequestNetworkPolicy(
                allowsCellularAccess: false,
                allowsConstrainedNetworkAccess: true,
                allowsExpensiveNetworkAccess: true
            )
        }
    }
}

enum WorkbenchCacheMode: String, CaseIterable, Codable, Identifiable {
    case automatic
    case onlyIfCached

    var id: String { rawValue }
    var title: String { self == .automatic ? "自动" : "仅缓存" }
    var value: ImageRequestCachePolicy { self == .automatic ? .automatic : .onlyIfCached }
}

enum WorkbenchContentMode: String, CaseIterable, Codable, Identifiable {
    case fit
    case fill

    var id: String { rawValue }
    var title: String { self == .fit ? "完整显示" : "裁切填充" }
    var value: ImageContentMode { self == .fit ? .fit : .fill }
}

enum WorkbenchRetentionMode: String, CaseIterable, Codable, Identifiable {
    case clearImmediately
    case retainUntilReplacement

    var id: String { rawValue }
    var title: String {
        self == .clearImmediately ? "身份变化立即清除" : "保留至替代图到达"
    }

    var value: FoveaImageRetentionPolicy {
        self == .clearImmediately ? .clearImmediately : .retainSuccessfulImageUntilReplacement
    }
}

enum WorkbenchVaryLanguage: String, CaseIterable, Codable, Identifiable {
    case english = "en"
    case chinese = "zh-CN"

    var id: String { rawValue }
    var title: String { self == .english ? "English" : "简体中文" }
}
