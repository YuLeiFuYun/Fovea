import Foundation
import FoveaHTTP

/// Pipeline 可访问的 namespace 与授权上下文组合。
public struct ProfileAccessScope: Codable, Hashable, Sendable {
    public let namespace: SecurityNamespaceID
    public let authorizationContext: AuthorizationContextID

    public init(
        namespace: SecurityNamespaceID,
        authorizationContext: AuthorizationContextID
    ) {
        self.namespace = namespace
        self.authorizationContext = authorizationContext
    }
}

/// 不依赖宿主回调、可在发网与缓存访问前同步判定的 Profile ACL。
///
/// Fovea 不推断业务角色或租户关系；宿主必须把已经裁决的 namespace 与
/// authorization context 组合传入 allowlist。默认 unrestricted 用于保持底层
/// `FoveaPipeline` 的组合自由；面向多账户或插件边界的 composition root 应显式收紧。
public struct ProfileAccessPolicy: Sendable {
    private enum Rule: Sendable {
        case unrestricted
        case publicOnly
        case allowlisted(Set<ProfileAccessScope>)
    }

    private let rule: Rule
    private let destinationPolicy: HTTPDestinationPolicy

    private init(
        rule: Rule,
        destinationPolicy: HTTPDestinationPolicy = .secureDefault
    ) {
        self.rule = rule
        self.destinationPolicy = destinationPolicy
    }

    public static let unrestricted = ProfileAccessPolicy(rule: .unrestricted)

    /// 仅允许不携带主体授权语义的 public 请求。
    public static let publicOnly = ProfileAccessPolicy(rule: .publicOnly)

    public static func allowOnly(_ scopes: Set<ProfileAccessScope>) -> ProfileAccessPolicy {
        ProfileAccessPolicy(rule: .allowlisted(scopes))
    }

    /// 在现有 profile 规则之外增加精确 destination policy。
    /// 官方系统组合根会自动使用 transport 的同一策略，确保缓存前检查与 redirect 一致。
    public func restrictingDestinations(
        _ destinationPolicy: HTTPDestinationPolicy
    ) -> ProfileAccessPolicy {
        ProfileAccessPolicy(rule: rule, destinationPolicy: destinationPolicy)
    }

    package func permits(_ request: ImageRequest) -> Bool {
        guard destinationPolicy.permits(request.url) else { return false }
        switch rule {
        case .unrestricted:
            return true
        case .publicOnly:
            return request.namespace.isPublicNamespace
                && request.authorizationContext == .public
                && !request.containsCredentialHeaders
        case .allowlisted(let scopes):
            return scopes.contains(
                ProfileAccessScope(
                    namespace: request.namespace,
                    authorizationContext: request.authorizationContext
                )
            )
        }
    }
}
