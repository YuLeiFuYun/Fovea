import Foundation
import FoveaCore
import FoveaHTTP
import ImageCraftCore

private let workbenchAppIdentifier = "dev.fovea.workbench"
let workbenchPublicNamespace = SecurityNamespaceID.publicNamespace(appID: workbenchAppIdentifier)
let workbenchPrivateNamespace = SecurityNamespaceID("account:demo-user")
let workbenchPrivateAuthorizationContext = AuthorizationContextID("demo-user")
let workbenchPrivateNamespaceB = SecurityNamespaceID("account:demo-user-b")
let workbenchPrivateAuthorizationContextB = AuthorizationContextID("demo-user-b")

enum WorkbenchRequestFactoryError: Error, LocalizedError, Equatable {
    case externalNetworkingDisabled
    case invalidCustomURL
    case invalidScenarioURL
    case bundledAssetDoesNotUseNetworkPipeline

    var errorDescription: String? {
        switch self {
        case .externalNetworkingDisabled: "外部网络请求已在设置中关闭。"
        case .invalidCustomURL: "自定义地址必须是有效 HTTPS URL。"
        case .invalidScenarioURL: "实验场景生成了无效 URL。"
        case .bundledAssetDoesNotUseNetworkPipeline: "本地素材由宿主直接读取，不进入网络图片管线。"
        }
    }
}

enum WorkbenchRequestFactory {
    static func makeRequest(
        scenario: WorkbenchScenario,
        target: TargetPixels,
        configuration: WorkbenchConfiguration,
        identityRevision: String = "baseline",
        runIdentifier: String? = nil
    ) throws -> ImageRequest {
        let context = try requestContext(
            scenario: scenario,
            configuration: configuration,
            identityRevision: identityRevision,
            runIdentifier: runIdentifier
        )
        return try ImageRequest(
            url: context.url,
            logicalSource: context.logicalSource,
            target: target,
            contentMode: configuration.contentMode.value,
            geometryPolicyFingerprint: "fovea-workbench-responsive-v2",
            namespace: context.namespace,
            authorizationContext: context.authorizationContext,
            credentialGeneration: context.credentialGeneration,
            priority: configuration.requestPriority.value,
            cachePolicy: context.cachePolicy,
            stalePolicy: context.stalePolicy,
            networkPolicy: configuration.networkMode.value,
            headers: context.headers,
            credentialHeaderNames: context.credentialHeaderNames
        )
    }

    static func makeRequest(
        scenario: WorkbenchScenario,
        resolvedTarget: ResolvedImageTarget,
        configuration: WorkbenchConfiguration,
        identityRevision: String = "baseline",
        runIdentifier: String? = nil
    ) throws -> ImageRequest {
        let context = try requestContext(
            scenario: scenario,
            configuration: configuration,
            identityRevision: identityRevision,
            runIdentifier: runIdentifier
        )
        return try ImageRequest(
            url: context.url,
            logicalSource: context.logicalSource,
            resolvedTarget: resolvedTarget,
            namespace: context.namespace,
            authorizationContext: context.authorizationContext,
            credentialGeneration: context.credentialGeneration,
            priority: configuration.requestPriority.value,
            cachePolicy: context.cachePolicy,
            stalePolicy: context.stalePolicy,
            networkPolicy: configuration.networkMode.value,
            headers: context.headers,
            credentialHeaderNames: context.credentialHeaderNames
        )
    }

    static func makeRemoteAssetRequest(
        asset: WorkbenchRemoteAsset,
        target: TargetPixels,
        configuration: WorkbenchConfiguration
    ) throws -> ImageRequest {
        let locator = try remoteAssetLocator(
            asset: asset,
            target: target,
            configuration: configuration
        )
        return try ImageRequest(
            url: locator.url,
            logicalSource: locator.logicalSource,
            target: target,
            contentMode: configuration.contentMode.value,
            geometryPolicyFingerprint: "fovea-workbench-remote-v2",
            namespace: workbenchPublicNamespace,
            authorizationContext: .public,
            priority: configuration.requestPriority.value,
            cachePolicy: configuration.cacheMode.value,
            stalePolicy: configuration.staleFallbackEnabled ? .inheritPipelinePolicy : .disallow,
            networkPolicy: configuration.networkMode.value
        )
    }

    static func makeRemoteAssetRequest(
        asset: WorkbenchRemoteAsset,
        resolvedTarget: ResolvedImageTarget,
        configuration: WorkbenchConfiguration
    ) throws -> ImageRequest {
        let locator = try remoteAssetLocator(
            asset: asset,
            target: resolvedTarget.pixels,
            configuration: configuration
        )
        return try ImageRequest(
            url: locator.url,
            logicalSource: locator.logicalSource,
            resolvedTarget: resolvedTarget,
            namespace: workbenchPublicNamespace,
            authorizationContext: .public,
            priority: configuration.requestPriority.value,
            cachePolicy: configuration.cacheMode.value,
            stalePolicy: configuration.staleFallbackEnabled ? .inheritPipelinePolicy : .disallow,
            networkPolicy: configuration.networkMode.value
        )
    }

    static func makeFeedRequest(
        item: WorkbenchFeedItem,
        target: TargetPixels,
        configuration: WorkbenchConfiguration,
        identityRevision: String
    ) throws -> ImageRequest {
        let locator = try feedLocator(
            item: item,
            target: target,
            configuration: configuration,
            identityRevision: identityRevision
        )
        return try ImageRequest(
            url: locator.url,
            logicalSource: locator.logicalSource,
            target: target,
            contentMode: configuration.contentMode.value,
            geometryPolicyFingerprint: "fovea-workbench-feed-v2",
            namespace: workbenchPublicNamespace,
            authorizationContext: .public,
            priority: configuration.requestPriority.value,
            cachePolicy: configuration.cacheMode.value,
            stalePolicy: configuration.staleFallbackEnabled ? .inheritPipelinePolicy : .disallow,
            networkPolicy: configuration.networkMode.value
        )
    }

    static func makeFeedRequest(
        item: WorkbenchFeedItem,
        resolvedTarget: ResolvedImageTarget,
        configuration: WorkbenchConfiguration,
        identityRevision: String
    ) throws -> ImageRequest {
        let locator = try feedLocator(
            item: item,
            target: resolvedTarget.pixels,
            configuration: configuration,
            identityRevision: identityRevision
        )
        return try ImageRequest(
            url: locator.url,
            logicalSource: locator.logicalSource,
            resolvedTarget: resolvedTarget,
            namespace: workbenchPublicNamespace,
            authorizationContext: .public,
            priority: configuration.requestPriority.value,
            cachePolicy: configuration.cacheMode.value,
            stalePolicy: configuration.staleFallbackEnabled ? .inheritPipelinePolicy : .disallow,
            networkPolicy: configuration.networkMode.value
        )
    }

    static func requestURL(
        for scenario: WorkbenchScenario,
        configuration: WorkbenchConfiguration
    ) throws -> URL {
        let base = try demoOriginURL()
        switch scenario.behavior {
        case .cacheable:
            return base.appendingPathComponent("image/cacheable")
        case .noStore:
            return base.appendingPathComponent("image/no-store")
        case .revalidation:
            return base.appendingPathComponent("image/revalidate")
        case .vary:
            return base.appendingPathComponent("image/vary")
        case .varyWildcard:
            return base.appendingPathComponent("image/vary-star")
        case .slow:
            return try url(
                base: base, path: "image/slow",
                queryItems: [
                    URLQueryItem(name: "delay", value: "900")
                ])
        case .chunked:
            return try url(
                base: base, path: "image/chunked",
                queryItems: [
                    URLQueryItem(name: "chunks", value: "10"),
                    URLQueryItem(name: "interval", value: "70"),
                ])
        case .missingContentType:
            return base.appendingPathComponent("image/missing-content-type")
        case .sameOriginRedirect:
            return base.appendingPathComponent("redirect/image")
        case .authenticated, .authenticatedInvalid, .authenticatedAccountB:
            return base.appendingPathComponent("image/authenticated")
        case .onlyIfCachedMiss:
            return base.appendingPathComponent("image/cache-only-never-populated")
        case .status(let status):
            return base.appendingPathComponent("failure/status/\(status)")
        case .wrongMIME:
            return base.appendingPathComponent("failure/wrong-mime")
        case .corruptImage:
            return base.appendingPathComponent("failure/corrupt-image")
        case .emptyImage:
            return base.appendingPathComponent("failure/empty-image")
        case .oversized:
            let bytes = (max(1, configuration.transportLimitMegabytes) + 1) * 1024 * 1024
            return try url(
                base: base, path: "failure/oversized",
                queryItems: [
                    URLQueryItem(name: "bytes", value: String(bytes))
                ])
        case .incompleteBody:
            return base.appendingPathComponent("failure/incomplete")
        case .deniedDestination:
            guard let deniedURL = URL(string: "https://blocked.example.test/image.png") else {
                throw WorkbenchRequestFactoryError.invalidScenarioURL
            }
            return deniedURL
        case .livePreset(let rawURL):
            guard configuration.externalNetworkingEnabled else {
                throw WorkbenchRequestFactoryError.externalNetworkingDisabled
            }
            guard let url = URL(string: rawURL),
                url.scheme?.lowercased() == "https",
                url.host != nil,
                url.user == nil,
                url.password == nil
            else {
                throw WorkbenchRequestFactoryError.invalidScenarioURL
            }
            return url
        case .liveCustom:
            guard configuration.externalNetworkingEnabled else {
                throw WorkbenchRequestFactoryError.externalNetworkingDisabled
            }
            guard let url = URL(string: configuration.customURL),
                url.scheme?.lowercased() == "https",
                url.host != nil,
                url.user == nil,
                url.password == nil
            else {
                throw WorkbenchRequestFactoryError.invalidCustomURL
            }
            return url
        }
    }

    private static func requestContext(
        scenario: WorkbenchScenario,
        configuration: WorkbenchConfiguration,
        identityRevision: String,
        runIdentifier: String?
    ) throws -> RequestContext {
        let authentication = authenticationContext(for: scenario.behavior)
        var headers: [String: String] = [:]
        var credentialHeaderNames: Set<String> = []
        if let authentication {
            headers["Authorization"] = authentication.authorizationHeader
            credentialHeaderNames.insert("authorization")
        }
        if scenario.behavior == .vary {
            headers["Accept-Language"] = configuration.varyLanguage.rawValue
        }
        return RequestContext(
            url: try taggedDemoURL(
                requestURL(for: scenario, configuration: configuration),
                runIdentifier: runIdentifier
            ),
            logicalSource: logicalSource(for: scenario, identityRevision: identityRevision),
            namespace: authentication?.namespace ?? workbenchPublicNamespace,
            authorizationContext: authentication?.authorizationContext ?? .public,
            credentialGeneration: authentication.map { _ in
                CredentialGeneration(UInt64(max(0, configuration.credentialGeneration)))
            },
            cachePolicy: scenario.behavior == .onlyIfCachedMiss
                ? .onlyIfCached : configuration.cacheMode.value,
            stalePolicy: configuration.staleFallbackEnabled ? .inheritPipelinePolicy : .disallow,
            headers: headers,
            credentialHeaderNames: credentialHeaderNames
        )
    }

    private static func authenticationContext(
        for behavior: WorkbenchScenarioBehavior
    ) -> AuthenticationRequestContext? {
        switch behavior {
        case .authenticated:
            return AuthenticationRequestContext(
                namespace: workbenchPrivateNamespace,
                authorizationContext: workbenchPrivateAuthorizationContext,
                authorizationHeader: "Bearer workbench-token-a"
            )
        case .authenticatedInvalid:
            return AuthenticationRequestContext(
                namespace: workbenchPrivateNamespace,
                authorizationContext: workbenchPrivateAuthorizationContext,
                authorizationHeader: "Bearer invalid-workbench-token"
            )
        case .authenticatedAccountB:
            return AuthenticationRequestContext(
                namespace: workbenchPrivateNamespaceB,
                authorizationContext: workbenchPrivateAuthorizationContextB,
                authorizationHeader: "Bearer workbench-token-b"
            )
        default:
            return nil
        }
    }

    private static func logicalSource(
        for scenario: WorkbenchScenario,
        identityRevision: String
    ) -> LogicalSourceID? {
        if scenario.behavior == .liveCustom {
            // 自定义 URL 保留完整 URL 默认身份，避免更换地址后复用旧资源。
            return nil
        }
        return LogicalSourceID("workbench:\(scenario.id):\(identityRevision)")
    }

    private static func taggedDemoURL(_ url: URL, runIdentifier: String?) throws -> URL {
        guard let runIdentifier, url.host?.lowercased() == DemoURLProtocol.host else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw WorkbenchRequestFactoryError.invalidScenarioURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "workbench-run" }
        queryItems.append(URLQueryItem(name: "workbench-run", value: runIdentifier))
        components.queryItems = queryItems
        guard let tagged = components.url else {
            throw WorkbenchRequestFactoryError.invalidScenarioURL
        }
        return tagged
    }

    static func demoOriginURL() throws -> URL {
        guard let url = URL(string: "https://\(DemoURLProtocol.host)") else {
            throw WorkbenchRequestFactoryError.invalidScenarioURL
        }
        return url
    }

    private struct RemoteAssetLocator {
        let url: URL
        let logicalSource: LogicalSourceID
    }

    private static func remoteAssetLocator(
        asset: WorkbenchRemoteAsset,
        target: TargetPixels,
        configuration: WorkbenchConfiguration
    ) throws -> RemoteAssetLocator {
        guard asset.sourceKind == .remote else {
            throw WorkbenchRequestFactoryError.bundledAssetDoesNotUseNetworkPipeline
        }
        if configuration.externalNetworkingEnabled {
            let width = WorkbenchRemoteAssetCatalog.requestWidth(for: target)
            guard let url = asset.remoteImageURL(width: width) else {
                throw WorkbenchRequestFactoryError.invalidScenarioURL
            }
            // Commons 的 width 参数会改变实际编码表征，因此宽度桶属于来源身份；
            // 视图刷新 token 不属于业务资源身份，不能破坏滚动回屏复用。
            return RemoteAssetLocator(
                url: url,
                logicalSource: LogicalSourceID("workbench:remote:\(asset.id):width:\(width)")
            )
        }
        return RemoteAssetLocator(
            url: try url(
                base: demoOriginURL(),
                path: "image/cacheable",
                queryItems: [URLQueryItem(name: "asset", value: asset.id)]
            ),
            logicalSource: LogicalSourceID("workbench:deterministic-asset:\(asset.id)")
        )
    }

    private static func feedLocator(
        item: WorkbenchFeedItem,
        target: TargetPixels,
        configuration: WorkbenchConfiguration,
        identityRevision: String
    ) throws -> RemoteAssetLocator {
        if configuration.externalNetworkingEnabled {
            let asset = WorkbenchRemoteAssetCatalog.remoteAsset(forStableIndex: item.assetID)
            let width = WorkbenchRemoteAssetCatalog.requestWidth(for: target)
            guard let url = asset.remoteImageURL(width: width) else {
                throw WorkbenchRequestFactoryError.invalidScenarioURL
            }
            return RemoteAssetLocator(
                url: url,
                logicalSource: LogicalSourceID(
                    "workbench:feed:\(asset.id):width:\(width):revision:\(identityRevision)"
                )
            )
        }
        return RemoteAssetLocator(
            url: try url(
                base: demoOriginURL(),
                path: "feed/asset-\(item.assetID)",
                queryItems: [URLQueryItem(name: "delay", value: String(item.delayMilliseconds))]
            ),
            logicalSource: feedLogicalSource(item: item, identityRevision: identityRevision)
        )
    }

    private static func url(
        base: URL,
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        let pathURL = base.appendingPathComponent(path)
        guard var components = URLComponents(url: pathURL, resolvingAgainstBaseURL: false) else {
            throw WorkbenchRequestFactoryError.invalidScenarioURL
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw WorkbenchRequestFactoryError.invalidScenarioURL
        }
        return url
    }

    private static func feedLogicalSource(
        item: WorkbenchFeedItem,
        identityRevision: String
    ) -> LogicalSourceID {
        LogicalSourceID("workbench:feed:asset-\(item.assetID):\(identityRevision)")
    }
}

private struct RequestContext {
    let url: URL
    let logicalSource: LogicalSourceID?
    let namespace: SecurityNamespaceID
    let authorizationContext: AuthorizationContextID
    let credentialGeneration: CredentialGeneration?
    let cachePolicy: ImageRequestCachePolicy
    let stalePolicy: ImageRequestStalePolicy
    let headers: [String: String]
    let credentialHeaderNames: Set<String>
}

private struct AuthenticationRequestContext {
    let namespace: SecurityNamespaceID
    let authorizationContext: AuthorizationContextID
    let authorizationHeader: String
}
