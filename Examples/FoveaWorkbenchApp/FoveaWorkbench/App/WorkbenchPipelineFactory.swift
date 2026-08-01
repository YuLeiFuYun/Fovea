import Foundation
import FoveaCore
import FoveaHTTP
import FoveaSystem

struct WorkbenchPipelineRuntime: Sendable {
    let system: FoveaSystemPipeline

    var pipeline: FoveaPipeline { system.pipeline }
    var storageGenerationIdentifier: String { system.storageGenerationIdentifier }

    func invalidateAndCancel() async {
        await system.invalidateAndCancel()
    }
}

enum WorkbenchPipelineRole: String, CaseIterable {
    case interactive
    case evidence
}

/// 组合 Workbench 的正式管线、精确目的地白名单和隔离持久化根。
/// 确定性实验与交互体验使用物理分离的角色目录，避免暖缓存污染证据。
enum WorkbenchPipelineFactory {
    static func open(
        cacheRoot: URL,
        configuration: WorkbenchConfiguration,
        diagnostics: any DiagnosticsSink
    ) async throws -> WorkbenchPipelineRuntime {
        try await open(
            cacheRoot: cacheRoot,
            configuration: configuration,
            diagnostics: diagnostics,
            role: .interactive
        )
    }

    static func openEvidence(
        cacheRoot: URL,
        configuration: WorkbenchConfiguration,
        diagnostics: any DiagnosticsSink
    ) async throws -> WorkbenchPipelineRuntime {
        try await open(
            cacheRoot: cacheRoot,
            configuration: configuration,
            diagnostics: diagnostics,
            role: .evidence
        )
    }

    private static func open(
        cacheRoot: URL,
        configuration: WorkbenchConfiguration,
        diagnostics: any DiagnosticsSink,
        role: WorkbenchPipelineRole
    ) async throws -> WorkbenchPipelineRuntime {
        let roleRoot = cacheRoot.appendingPathComponent(role.rawValue, isDirectory: true)
        let storeRoot = roleRoot.appendingPathComponent(
            configuration.storageProfileIdentifier,
            isDirectory: true
        )

        var allowedOrigins: Set<HTTPOrigin> = [
            try HTTPOrigin(url: WorkbenchRequestFactory.demoOriginURL())
        ]
        if configuration.externalNetworkingEnabled {
            for url in WorkbenchScenarioCatalog.livePresetURLs
                + WorkbenchScenarioCatalog.additionalLiveRedirectOrigins
                + WorkbenchRemoteAssetCatalog.allowedOriginURLs
            {
                allowedOrigins.insert(try HTTPOrigin(url: url))
            }
            if let customURL = URL(string: configuration.customURL),
                customURL.scheme?.lowercased() == "https",
                customURL.host != nil,
                customURL.user == nil,
                customURL.password == nil
            {
                allowedOrigins.insert(try HTTPOrigin(url: customURL))
            }
        }
        let destinationPolicy = try HTTPDestinationPolicy.allowOnly(allowedOrigins)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        let existingClasses = sessionConfiguration.protocolClasses ?? []
        sessionConfiguration.protocolClasses =
            [DemoURLProtocol.self]
            + existingClasses.filter { $0 != DemoURLProtocol.self }

        let transportPolicy = URLSessionTransportPolicy(
            waitsForConnectivity: configuration.waitsForConnectivity,
            requestTimeoutSeconds: configuration.requestTimeoutSeconds,
            resourceTimeoutSeconds: configuration.resourceTimeoutSeconds,
            maximumConnectionsPerHost: configuration.maximumConnectionsPerHost,
            proxyPolicy: configuration.proxyMode == .system
                ? .system : .requireNoProxyInTaskMetrics,
            destinationPolicy: destinationPolicy
        )
        let pipelineConfiguration = PipelineConfiguration(
            memoryCostLimit: configuration.memoryLimitMegabytes * 1024 * 1024,
            staleFallbackPolicy: configuration.staleFallbackEnabled
                ? .networkResilient(
                    maximumStalenessSeconds: UInt64(configuration.maximumStalenessSeconds)
                )
                : .disabled,
            maximumTransportBytes: configuration.transportLimitMegabytes * 1024 * 1024,
            transportMemoryThreshold: configuration.transportMemoryThresholdKilobytes * 1024,
            maximumConcurrentFetches: configuration.maximumConcurrentFetches,
            maximumConcurrentDecodes: configuration.maximumConcurrentDecodes,
            maximumDecodeWorkingSetBytes: configuration.decodeWorkingSetMegabytes * 1024 * 1024,
            maximumQueuedFetches: configuration.maximumQueuedFetches,
            maximumQueuedDecodes: configuration.maximumQueuedDecodes,
            maximumTrackedNamespaces: configuration.maximumTrackedNamespaces
        )
        let scopes: Set<ProfileAccessScope> = [
            ProfileAccessScope(namespace: workbenchPublicNamespace, authorizationContext: .public),
            ProfileAccessScope(
                namespace: workbenchPrivateNamespace,
                authorizationContext: workbenchPrivateAuthorizationContext
            ),
            ProfileAccessScope(
                namespace: workbenchPrivateNamespaceB,
                authorizationContext: workbenchPrivateAuthorizationContextB
            ),
        ]
        let reuseContext = [
            "fovea-workbench-v2",
            role.rawValue,
            configuration.externalNetworkingEnabled ? "external" : "deterministic",
            configuration.proxyMode.rawValue,
        ].joined(separator: ":")
        let system = try await FoveaSystemPipeline.open(
            cacheRoot: storeRoot,
            configuration: pipelineConfiguration,
            diagnostics: diagnostics,
            profileAccessPolicy: ProfileAccessPolicy.allowOnly(scopes),
            transportPolicy: transportPolicy,
            encodedSoftTotalBytes: configuration.encodedSoftLimitMegabytes * 1024 * 1024,
            maximumEncodedBlobBytes: configuration.encodedBlobLimitMegabytes * 1024 * 1024,
            automaticallyPurgesMemoryOnPressure: role == .interactive,
            sessionConfiguration: sessionConfiguration,
            stagingDirectory:
                cacheRoot
                .appendingPathComponent("transport-staging", isDirectory: true)
                .appendingPathComponent(role.rawValue, isDirectory: true),
            transportReusePolicy: .reusable(contextIdentifier: reuseContext)
        )
        return WorkbenchPipelineRuntime(system: system)
    }

}
