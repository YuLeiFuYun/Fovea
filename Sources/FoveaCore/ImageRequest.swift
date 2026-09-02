import Foundation
import FoveaHTTP
import FoveaStorage
import ImageCraftCore

/// 控制图像请求在查询缓存后是否可以访问网络。

public enum ImageRequestCachePolicy: String, Codable, Hashable, Sendable {
    /// 使用新鲜缓存，并在必要时允许网络工作。
    case automatic
    /// 不启动网络工作，直接返回稳定的缓存未命中。
    case onlyIfCached
}

/// 控制请求在可重试失败后是否可以使用有界陈旧内容。

public enum ImageRequestStalePolicy: String, Codable, Hashable, Sendable {
    /// 可重试失败时沿用管线的陈旧回退策略。
    case inheritPipelinePolicy
    /// 为当前请求禁用陈旧回退。
    case disallow
}

/// 构造图像请求时产生的验证失败。

public enum ImageRequestError: Error, Equatable, Sendable {
    case duplicateHeaderName(String)
    case invalidHeaderName(String)
    case invalidHeaderValue(String)
    case unsupportedURLScheme(String?)
    case insecureRemoteHTTP
    case missingURLHost
    case embeddedURLCredentials
    case invalidURL
    case urlTooLong
    case headerCollectionTooLarge
    case invalidIdentityComponent(String)
    case identityComponentTooLarge(String)
    case fingerprintForNonCredentialHeader(String)
}

/// 包含身份、安全、几何与资源策略的不可变图像请求。

public struct ImageRequest: Sendable {
    /// 当前获取使用的已验证 HTTP 或 HTTPS 定位符。
    public let url: URL
    /// 稳定的业务资源身份。未显式提供时使用包含 query 的规范化完整 URL。
    /// 轮换签名 URL 必须由调用者传入稳定 asset ID，库不会猜测并剥离 query 字段。
    public let logicalSource: LogicalSourceID
    /// 要求的解码像素目标。
    public let target: TargetPixels
    /// 完整显示或裁切填充的解码几何。
    public let contentMode: ImageContentMode
    /// 几何解析策略的稳定身份。
    public let geometryPolicyFingerprint: String
    /// 解码时应用的色彩转换策略。
    public let colorPolicy: ImageColorPolicy
    /// 渲染结果是否可以进入共享内存缓存。
    public let renderCacheAdmission: RenderCacheAdmission
    /// 缓存与撤销状态使用的隔离命名空间。
    public let namespace: SecurityNamespaceID
    /// 获准提供凭证的授权上下文。
    public let authorizationContext: AuthorizationContextID
    /// 用于阻止旧认证执行被复用的凭证版本。
    public let credentialGeneration: CredentialGeneration?
    /// 初始调度优先级。
    public let priority: ImageRequestPriority
    /// 请求的缓存与网络准入策略。
    public let cachePolicy: ImageRequestCachePolicy
    /// 请求专属的陈旧回退策略。
    public let stalePolicy: ImageRequestStalePolicy
    /// 对蜂窝网络、高成本路径与受限路径的权限。
    public let networkPolicy: ImageRequestNetworkPolicy
    /// 按小写字段名索引的归一化请求头。
    public let headers: [String: String]
    /// 额外包含凭证材料的请求头名称。
    public let credentialHeaderNames: Set<String>
    /// 敏感请求头参与 Vary 时使用的不可逆指纹。
    public let headerVariantFingerprints: [String: HeaderVariantFingerprint]

    /// 仅供基准测试传输记账使用、不会参与请求/缓存身份的传输元数据。
    /// 只有 `FoveaBenchmarking` SPI 可以写入，且只接受 `x-benchmark-request-id`。
    var benchmarkTransportHeaders: [String: String] = [:]

    private let cachedStorageNamespaceFingerprint: StorageNamespaceFingerprint
    private let cachedFetchBaseKey: FetchBaseKey
    private let cachedFetchBaseDigest: String
    private let cachedFetchVariantKey: FetchVariantKey
    private let cachedDefaultFetchExecutionKey: FetchExecutionKey
    private let cachedDefaultFetchExecutionDigest: String
    private let cachedExactRequestHeaderFingerprint: String
    private let cachedCredentialExecutionFingerprint: String
    private let cachedRenderAliasIdentity: String
    private let cachedDisplayIdentity: String

    private struct ValidatedComponents {
        let url: URL
        let logicalSource: LogicalSourceID
        let headers: [String: String]
        let credentialHeaderNames: Set<String>
        let headerVariantFingerprints: [String: HeaderVariantFingerprint]
        let storageNamespaceFingerprint: StorageNamespaceFingerprint
        let fetchBaseKey: FetchBaseKey
        let fetchBaseDigest: String
        let defaultFetchExecutionKey: FetchExecutionKey
        let defaultFetchExecutionDigest: String
        let exactRequestHeaderFingerprint: String
        let credentialExecutionFingerprint: String
    }

    /// 从显式目标创建请求，并验证 URL、身份、请求头与安全元数据。
    public init(
        url: URL,
        logicalSource: LogicalSourceID? = nil,
        target: TargetPixels,
        contentMode: ImageContentMode = .fit,
        geometryPolicyFingerprint: String = "exact-v1",
        colorPolicy: ImageColorPolicy = .preserveSource,
        renderCacheAdmission: RenderCacheAdmission = .stable,
        namespace: SecurityNamespaceID,
        authorizationContext: AuthorizationContextID = .public,
        credentialGeneration: CredentialGeneration? = nil,
        priority: ImageRequestPriority = .normal,
        cachePolicy: ImageRequestCachePolicy = .automatic,
        stalePolicy: ImageRequestStalePolicy = .inheritPipelinePolicy,
        networkPolicy: ImageRequestNetworkPolicy = .interactive,
        headers: [String: String] = [:],
        credentialHeaderNames: Set<String> = [],
        headerVariantFingerprints: [String: HeaderVariantFingerprint] = [:]
    ) throws {
        let components = try Self.validatedComponents(
            url: url,
            logicalSource: logicalSource,
            namespace: namespace,
            authorizationContext: authorizationContext,
            credentialGeneration: credentialGeneration,
            networkPolicy: networkPolicy,
            headers: headers,
            credentialHeaderNames: credentialHeaderNames,
            headerVariantFingerprints: headerVariantFingerprints,
            geometryPolicyFingerprint: geometryPolicyFingerprint
        )
        let renderAliasIdentity = [
            components.defaultFetchExecutionDigest,
            "\(target.width)x\(target.height)",
            contentMode.rawValue,
            geometryPolicyFingerprint,
            colorPolicy.rawValue,
        ].joined(separator: "|")
        let displayIdentity = [
            renderAliasIdentity,
            renderCacheAdmission.rawValue,
            cachePolicy.rawValue,
            stalePolicy.rawValue,
            networkPolicy.executionFingerprint,
        ].joined(separator: "|")
        self.url = components.url
        self.logicalSource = components.logicalSource
        self.target = target
        self.contentMode = contentMode
        self.geometryPolicyFingerprint = geometryPolicyFingerprint
        self.colorPolicy = colorPolicy
        self.renderCacheAdmission = renderCacheAdmission
        self.namespace = namespace
        self.authorizationContext = authorizationContext
        self.credentialGeneration = credentialGeneration
        self.priority = priority
        self.cachePolicy = cachePolicy
        self.stalePolicy = stalePolicy
        self.networkPolicy = networkPolicy
        self.headers = components.headers
        self.credentialHeaderNames = components.credentialHeaderNames
        self.headerVariantFingerprints = components.headerVariantFingerprints
        self.cachedStorageNamespaceFingerprint = components.storageNamespaceFingerprint
        self.cachedFetchBaseKey = components.fetchBaseKey
        self.cachedFetchBaseDigest = components.fetchBaseDigest
        self.cachedFetchVariantKey = FetchVariantKey(baseDigest: components.fetchBaseDigest)
        self.cachedDefaultFetchExecutionKey = components.defaultFetchExecutionKey
        self.cachedDefaultFetchExecutionDigest = components.defaultFetchExecutionDigest
        self.cachedExactRequestHeaderFingerprint = components.exactRequestHeaderFingerprint
        self.cachedCredentialExecutionFingerprint = components.credentialExecutionFingerprint
        self.cachedRenderAliasIdentity = renderAliasIdentity
        self.cachedDisplayIdentity = displayIdentity
    }

    private static func validatedComponents(
        url: URL,
        logicalSource: LogicalSourceID?,
        namespace: SecurityNamespaceID,
        authorizationContext: AuthorizationContextID,
        credentialGeneration: CredentialGeneration?,
        networkPolicy: ImageRequestNetworkPolicy,
        headers: [String: String],
        credentialHeaderNames: Set<String>,
        headerVariantFingerprints: [String: HeaderVariantFingerprint],
        geometryPolicyFingerprint: String
    ) throws -> ValidatedComponents {
        let normalizedURL = try ImageRequestValidation.normalizedHTTPURL(url)
        let resolvedLogicalSource =
            logicalSource ?? LogicalSourceID(normalizedHTTPURL: normalizedURL)
        try Self.validateIdentityComponents(
            logicalSource: resolvedLogicalSource,
            namespace: namespace,
            authorizationContext: authorizationContext,
            geometryPolicyFingerprint: geometryPolicyFingerprint
        )
        let normalizedHeaders = try ImageRequestValidation.normalizedHeaders(headers)
        let normalizedCredentialNames = try ImageRequestValidation.normalizedHeaderNames(
            credentialHeaderNames
        )
        let normalizedFingerprints = try ImageRequestValidation.normalizedFingerprints(
            headerVariantFingerprints
        )
        for name in normalizedFingerprints.keys
        where !CredentialHeaderPolicy.isSensitiveHeaderName(
            name,
            additionalSensitiveNames: normalizedCredentialNames
        ) {
            throw ImageRequestError.fingerprintForNonCredentialHeader(name)
        }
        let storageNamespaceFingerprint = StorageNamespaceFingerprint(
            namespace: namespace.value
        )
        let fetchBaseKey = FetchBaseKey(
            source: resolvedLogicalSource,
            namespace: namespace,
            authorizationContext: authorizationContext
        )
        let exactRequestHeaderFingerprint = Self.exactRequestHeaderFingerprint(
            headers: normalizedHeaders,
            credentialHeaderNames: normalizedCredentialNames,
            headerVariantFingerprints: normalizedFingerprints
        )
        let credentialExecutionFingerprint = Self.credentialExecutionFingerprint(
            headers: normalizedHeaders,
            credentialHeaderNames: normalizedCredentialNames
        )
        let fetchBaseDigest = fetchBaseKey.digestHex
        let defaultFetchExecutionKey = FetchExecutionKey(
            baseDigest: fetchBaseDigest,
            selectedVariantDigest: nil,
            resolvedLocator: normalizedURL.absoluteString,
            requestHeaderFingerprint: exactRequestHeaderFingerprint,
            credentialGeneration: credentialGeneration,
            revalidationFingerprint: "unconditional",
            transportPolicyFingerprint:
                "\(credentialExecutionFingerprint)|\(networkPolicy.executionFingerprint)|request-default-v1"
        )
        return ValidatedComponents(
            url: normalizedURL,
            logicalSource: resolvedLogicalSource,
            headers: normalizedHeaders,
            credentialHeaderNames: normalizedCredentialNames,
            headerVariantFingerprints: normalizedFingerprints,
            storageNamespaceFingerprint: storageNamespaceFingerprint,
            fetchBaseKey: fetchBaseKey,
            fetchBaseDigest: fetchBaseDigest,
            defaultFetchExecutionKey: defaultFetchExecutionKey,
            defaultFetchExecutionDigest: defaultFetchExecutionKey.digestHex,
            exactRequestHeaderFingerprint: exactRequestHeaderFingerprint,
            credentialExecutionFingerprint: credentialExecutionFingerprint
        )
    }

    private static func validateIdentityComponents(
        logicalSource: LogicalSourceID,
        namespace: SecurityNamespaceID,
        authorizationContext: AuthorizationContextID,
        geometryPolicyFingerprint: String
    ) throws {
        try ImageRequestValidation.validateIdentityComponent(
            logicalSource.value,
            name: "logical-source",
            maximumBytes: ImageRequestValidation.maximumLogicalSourceBytes
        )
        try ImageRequestValidation.validateIdentityComponent(
            namespace.value,
            name: "namespace",
            maximumBytes: ImageRequestValidation.maximumNamespaceBytes
        )
        try ImageRequestValidation.validateIdentityComponent(
            authorizationContext.value,
            name: "authorization-context",
            maximumBytes: ImageRequestValidation.maximumAuthorizationContextBytes
        )
        try ImageRequestValidation.validateIdentityComponent(
            geometryPolicyFingerprint,
            name: "geometry-policy-fingerprint",
            maximumBytes: ImageRequestValidation.maximumGeometryFingerprintBytes
        )
    }

    /// 从已解析的响应式目标创建请求。
    public init(
        url: URL,
        logicalSource: LogicalSourceID? = nil,
        resolvedTarget: ResolvedImageTarget,
        colorPolicy: ImageColorPolicy = .preserveSource,
        namespace: SecurityNamespaceID,
        authorizationContext: AuthorizationContextID = .public,
        credentialGeneration: CredentialGeneration? = nil,
        priority: ImageRequestPriority = .normal,
        cachePolicy: ImageRequestCachePolicy = .automatic,
        stalePolicy: ImageRequestStalePolicy = .inheritPipelinePolicy,
        networkPolicy: ImageRequestNetworkPolicy = .interactive,
        headers: [String: String] = [:],
        credentialHeaderNames: Set<String> = [],
        headerVariantFingerprints: [String: HeaderVariantFingerprint] = [:]
    ) throws {
        try self.init(
            url: url,
            logicalSource: logicalSource,
            target: resolvedTarget.pixels,
            contentMode: resolvedTarget.contentMode,
            geometryPolicyFingerprint: resolvedTarget.geometryPolicyFingerprint,
            colorPolicy: colorPolicy,
            renderCacheAdmission: resolvedTarget.cacheAdmission,
            namespace: namespace,
            authorizationContext: authorizationContext,
            credentialGeneration: credentialGeneration,
            priority: priority,
            cachePolicy: cachePolicy,
            stalePolicy: stalePolicy,
            networkPolicy: networkPolicy,
            headers: headers,
            credentialHeaderNames: credentialHeaderNames,
            headerVariantFingerprints: headerVariantFingerprints
        )
    }

    /// 复用已验证的 URL、安全域、请求头与获取身份，只替换响应式目标几何。
    ///
    /// 适合列表和可调整布局：调用方可在数据准备阶段创建请求原型，布局阶段只解析
    /// `ResolvedImageTarget`，避免在主线程重复规范化 URL 和计算 HTTP 身份摘要。
    public func retargeted(to resolvedTarget: ResolvedImageTarget) throws -> Self {
        try ImageRequestValidation.validateIdentityComponent(
            resolvedTarget.geometryPolicyFingerprint,
            name: "geometry-policy-fingerprint",
            maximumBytes: ImageRequestValidation.maximumGeometryFingerprintBytes
        )
        return Self(prevalidated: self, resolvedTarget: resolvedTarget)
    }

    package func reprioritized(_ priority: ImageRequestPriority) -> Self {
        Self(prevalidated: self, priority: priority)
    }

    /// 附加仅用于实验仪器记账的非语义传输头。
    ///
    /// 普通请求头继续参与精确执行身份；这里只允许唯一的 request-id 测量字段、
    /// 非敏感且不与已有语义头重名，避免该 SPI 成为绕过缓存身份或 Vary 的通用后门。
    @_spi(FoveaBenchmarking)
    public func withBenchmarkTransportHeaders(_ headers: [String: String]) throws -> Self {
        let normalized = try ImageRequestValidation.normalizedHeaders(headers)
        for name in normalized.keys {
            guard name == "x-benchmark-request-id", self.headers[name] == nil,
                !CredentialHeaderPolicy.isSensitiveHeaderName(
                    name,
                    additionalSensitiveNames: credentialHeaderNames
                )
            else {
                throw ImageRequestError.invalidHeaderName(name)
            }
        }
        var copy = self
        copy.benchmarkTransportHeaders = normalized
        return copy
    }

    private init(prevalidated source: Self, resolvedTarget: ResolvedImageTarget) {
        self.url = source.url
        self.logicalSource = source.logicalSource
        self.target = resolvedTarget.pixels
        self.contentMode = resolvedTarget.contentMode
        self.geometryPolicyFingerprint = resolvedTarget.geometryPolicyFingerprint
        self.colorPolicy = source.colorPolicy
        self.renderCacheAdmission = resolvedTarget.cacheAdmission
        self.namespace = source.namespace
        self.authorizationContext = source.authorizationContext
        self.credentialGeneration = source.credentialGeneration
        self.priority = source.priority
        self.cachePolicy = source.cachePolicy
        self.stalePolicy = source.stalePolicy
        self.networkPolicy = source.networkPolicy
        self.headers = source.headers
        self.credentialHeaderNames = source.credentialHeaderNames
        self.headerVariantFingerprints = source.headerVariantFingerprints
        self.benchmarkTransportHeaders = source.benchmarkTransportHeaders
        self.cachedStorageNamespaceFingerprint = source.cachedStorageNamespaceFingerprint
        self.cachedFetchBaseKey = source.cachedFetchBaseKey
        self.cachedFetchBaseDigest = source.cachedFetchBaseDigest
        self.cachedFetchVariantKey = source.cachedFetchVariantKey
        self.cachedDefaultFetchExecutionKey = source.cachedDefaultFetchExecutionKey
        self.cachedDefaultFetchExecutionDigest = source.cachedDefaultFetchExecutionDigest
        self.cachedExactRequestHeaderFingerprint = source.cachedExactRequestHeaderFingerprint
        self.cachedCredentialExecutionFingerprint = source.cachedCredentialExecutionFingerprint
        self.cachedRenderAliasIdentity = [
            source.cachedDefaultFetchExecutionDigest,
            "\(resolvedTarget.pixels.width)x\(resolvedTarget.pixels.height)",
            resolvedTarget.contentMode.rawValue,
            resolvedTarget.geometryPolicyFingerprint,
            source.colorPolicy.rawValue,
        ].joined(separator: "|")
        self.cachedDisplayIdentity = [
            cachedRenderAliasIdentity,
            resolvedTarget.cacheAdmission.rawValue,
            source.cachePolicy.rawValue,
            source.stalePolicy.rawValue,
            source.networkPolicy.executionFingerprint,
        ].joined(separator: "|")
    }

    private init(prevalidated source: Self, priority: ImageRequestPriority) {
        self.url = source.url
        self.logicalSource = source.logicalSource
        self.target = source.target
        self.contentMode = source.contentMode
        self.geometryPolicyFingerprint = source.geometryPolicyFingerprint
        self.colorPolicy = source.colorPolicy
        self.renderCacheAdmission = source.renderCacheAdmission
        self.namespace = source.namespace
        self.authorizationContext = source.authorizationContext
        self.credentialGeneration = source.credentialGeneration
        self.priority = priority
        self.cachePolicy = source.cachePolicy
        self.stalePolicy = source.stalePolicy
        self.networkPolicy = source.networkPolicy
        self.headers = source.headers
        self.credentialHeaderNames = source.credentialHeaderNames
        self.headerVariantFingerprints = source.headerVariantFingerprints
        self.benchmarkTransportHeaders = source.benchmarkTransportHeaders
        self.cachedStorageNamespaceFingerprint = source.cachedStorageNamespaceFingerprint
        self.cachedFetchBaseKey = source.cachedFetchBaseKey
        self.cachedFetchBaseDigest = source.cachedFetchBaseDigest
        self.cachedFetchVariantKey = source.cachedFetchVariantKey
        self.cachedDefaultFetchExecutionKey = source.cachedDefaultFetchExecutionKey
        self.cachedDefaultFetchExecutionDigest = source.cachedDefaultFetchExecutionDigest
        self.cachedExactRequestHeaderFingerprint = source.cachedExactRequestHeaderFingerprint
        self.cachedCredentialExecutionFingerprint = source.cachedCredentialExecutionFingerprint
        self.cachedRenderAliasIdentity = source.cachedRenderAliasIdentity
        self.cachedDisplayIdentity = source.cachedDisplayIdentity
    }

    /// 从显式像素目标创建公开且无需认证的请求。
    public static func publicImage(
        url: URL,
        logicalSource: LogicalSourceID? = nil,
        target: TargetPixels,
        colorPolicy: ImageColorPolicy = .preserveSource,
        appID: String,
        priority: ImageRequestPriority = .normal,
        cachePolicy: ImageRequestCachePolicy = .automatic,
        stalePolicy: ImageRequestStalePolicy = .inheritPipelinePolicy,
        networkPolicy: ImageRequestNetworkPolicy = .interactive
    ) throws -> Self {
        try ImageRequest(
            url: url,
            logicalSource: logicalSource,
            target: target,
            colorPolicy: colorPolicy,
            namespace: .publicNamespace(appID: appID),
            priority: priority,
            cachePolicy: cachePolicy,
            stalePolicy: stalePolicy,
            networkPolicy: networkPolicy
        )
    }

    /// 从已解析的响应式目标创建公开且无需认证的请求。
    public static func publicImage(
        url: URL,
        logicalSource: LogicalSourceID? = nil,
        resolvedTarget: ResolvedImageTarget,
        colorPolicy: ImageColorPolicy = .preserveSource,
        appID: String,
        priority: ImageRequestPriority = .normal,
        cachePolicy: ImageRequestCachePolicy = .automatic,
        stalePolicy: ImageRequestStalePolicy = .inheritPipelinePolicy,
        networkPolicy: ImageRequestNetworkPolicy = .interactive
    ) throws -> Self {
        try ImageRequest(
            url: url,
            logicalSource: logicalSource,
            resolvedTarget: resolvedTarget,
            colorPolicy: colorPolicy,
            namespace: .publicNamespace(appID: appID),
            priority: priority,
            cachePolicy: cachePolicy,
            stalePolicy: stalePolicy,
            networkPolicy: networkPolicy
        )
    }

    /// 当前请求安全命名空间的已验证持久化分区指纹。
    package var storageNamespaceFingerprint: StorageNamespaceFingerprint {
        cachedStorageNamespaceFingerprint
    }

    /// 此来源所有 HTTP 变体共享的持久基础身份。
    public var fetchBaseKey: FetchBaseKey { cachedFetchBaseKey }

    /// 请求构造时预计算的持久基础身份摘要。
    package var fetchBaseDigest: String { cachedFetchBaseDigest }

    /// 尚未得知 Vary 选择时使用的无条件表征身份。
    public var fetchVariantKey: FetchVariantKey { cachedFetchVariantKey }

    package func fetchVariantKey(for selection: HTTPVarySelection) -> FetchVariantKey {
        FetchVariantKey(
            baseDigest: cachedFetchVariantKey.baseDigest,
            requestVariants: selection.canonicalRequestVariants
        )
    }

    /// 无条件请求的默认执行身份。
    public var fetchExecutionKey: FetchExecutionKey { cachedDefaultFetchExecutionKey }

    package func fetchExecutionKey(
        selectedVariant: FetchVariantKey?,
        revalidationFingerprint: String,
        transportPolicyFingerprint: String = "request-default-v1"
    ) -> FetchExecutionKey {
        FetchExecutionKey(
            baseDigest: cachedFetchVariantKey.baseDigest,
            selectedVariantDigest: selectedVariant?.digestHex,
            resolvedLocator: url.absoluteString,
            requestHeaderFingerprint: cachedExactRequestHeaderFingerprint,
            credentialGeneration: credentialGeneration,
            revalidationFingerprint: revalidationFingerprint,
            transportPolicyFingerprint:
                "\(cachedCredentialExecutionFingerprint)|\(networkPolicy.executionFingerprint)|\(transportPolicyFingerprint)"
        )
    }

    /// 用于 UI 订阅替换与重试代际的稳定身份。
    package var renderAliasIdentity: String { cachedRenderAliasIdentity }

    public var displayIdentity: String { cachedDisplayIdentity }

    /// 归一化请求头是否包含已知或调用方声明的凭证。
    public var containsCredentialHeaders: Bool {
        CredentialHeaderPolicy.containsSensitiveHeader(
            headers,
            additionalSensitiveNames: credentialHeaderNames
        )
    }

    package func varySelection(fieldNames: [String]) -> HTTPVarySelection? {
        HTTPCachePolicy.varySelection(
            fieldNames: fieldNames,
            requestHeaders: headers,
            additionalSensitiveNames: credentialHeaderNames,
            sensitiveFingerprints: headerVariantFingerprints
        )
    }

    private static let emptyExactRequestHeaderFingerprint =
        Data("fovea-exact-request-headers-v1\u{0}".utf8).sha256Hex
    private static let emptyCredentialExecutionFingerprint =
        Data("fovea-credential-header-set-v2\u{0}".utf8).sha256Hex

    private static func exactRequestHeaderFingerprint(
        headers: [String: String],
        credentialHeaderNames: Set<String>,
        headerVariantFingerprints: [String: HeaderVariantFingerprint]
    ) -> String {
        guard !headers.isEmpty else { return emptyExactRequestHeaderFingerprint }
        let sensitiveNames = CredentialHeaderPolicy.sensitiveNamesPresent(
            in: headers,
            additionalSensitiveNames: credentialHeaderNames
        )
        var material = Data("fovea-exact-request-headers-v1\u{0}".utf8)
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            material.append(contentsOf: name.utf8)
            material.append(0)
            if sensitiveNames.contains(name) {
                let fingerprint =
                    headerVariantFingerprints[name]?.sha256Hex ?? "credential-generation"
                material.append(contentsOf: fingerprint.utf8)
            } else {
                material.append(contentsOf: value.utf8)
            }
            material.append(0)
        }
        return material.sha256Hex
    }

    private static func credentialExecutionFingerprint(
        headers: [String: String],
        credentialHeaderNames: Set<String>
    ) -> String {
        guard !headers.isEmpty, !credentialHeaderNames.isEmpty else {
            return emptyCredentialExecutionFingerprint
        }
        let names = CredentialHeaderPolicy.sensitiveNamesPresent(
            in: headers,
            additionalSensitiveNames: credentialHeaderNames
        ).sorted()
        var material = Data("fovea-credential-header-set-v2\u{0}".utf8)
        for name in names {
            material.append(contentsOf: name.utf8)
            material.append(0)
        }
        return material.sha256Hex
    }

}
