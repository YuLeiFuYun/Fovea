# 鉴权上下文与 Cookie 集成契约

> **状态：Proposed，Phase 0a/Core v1 Candidate 规格。**

## 1. 目标

应用必须能够安全地把账户、权限语义和一次性凭证变化传给 Fovea，而不把 token、Cookie 或签名 URL 写入持久 key、日志和诊断。

稳定缓存身份与本次精确授权执行分开：

```text
SecurityNamespaceID
    隔离 account / tenant / profile

AuthorizationContextID
    表示 principal + scope/role/entitlement generation

CredentialGeneration
    表示 token/Cookie/signature material 的执行代际

CookieVariantFingerprint
    仅在 Vary: Cookie 或应用策略要求时表达安全的 Cookie 变体
```

## 2. 无鉴权公共资源默认路径

请求不包含 `Authorization`、Cookie、TLS client identity 或其他主体相关凭证时，默认使用：

```text
SecurityNamespaceID = app-scoped public namespace
AuthorizationContextID = public
CredentialGeneration = absent
CookieVariantFingerprint = absent
```

- 不要求应用提供 `AuthorizationContextProvider` 或 `RequestAuthorizer`；
- FetchExecutionKey 不加入 credential generation；
- 可否持久化只由 HTTP/cache/security policy 决定；
- public namespace 仍是 app/store scoped，不与其他应用或不可信 store 全局共享；
- 如果 redirect/response 触发了主体相关状态，必须重新分类或 fail closed，不能继续按 public 身份复用。

Phase 0a demo 与 W1/W2 主路径使用此模式。

## 3. 最小集成接口

推荐把稳定身份元数据与敏感请求修改分成两个接口：

```swift
public protocol AuthorizationContextProvider: Sendable {
    func identity(for source: URLSource) async throws -> AuthorizationIdentity
}

public protocol RequestAuthorizer: Sendable {
    func authorize(
        _ request: URLRequest,
        identity: AuthorizationIdentity
    ) async throws -> AuthorizedRequest
}

public struct AuthorizationIdentity: Sendable, Hashable {
    // 在 FetchVariantKey 冻结前确定；不随普通 token refresh 变化。
    public let securityNamespaceID: SecurityNamespaceID
    public let authorizationContextID: AuthorizationContextID
    public let cookiePartitionGeneration: UInt64?
    public let cookieVariantFingerprint: StableFingerprint?
}

public struct AuthorizationExecutionMetadata: Sendable, Hashable {
    // RequestAuthorizer 应用本次凭证后确定，只进入 FetchExecutionKey。
    public let credentialGeneration: UInt64
}

public struct AuthorizedRequest /* transport-isolated */ {
    // 仅在传输热路径中存在，包含敏感 header；不得持久化或诊断输出。
    public let request: URLRequest
    public let identity: AuthorizationIdentity
    public let execution: AuthorizationExecutionMetadata
}
```

`AuthorizationContextProvider` 必须在 FetchVariantKey 冻结前给出稳定 `AuthorizationIdentity`；`RequestAuthorizer` 只应用本次凭证并返回 execution metadata，不能静默修改 namespace/auth context/cookie variant。FetchExecutionKey 只能在授权完成后冻结。`AuthorizedRequest` 应被限制在 Transport actor/隔离域中；不要为了跨域传递而直接标记 `@unchecked Sendable`。敏感 `URLRequest` 不得实现持久序列化、公开 `description` 或稳定哈希。

## 4. 事件矩阵

| 事件 | SecurityNamespaceID | AuthorizationContextID | CredentialGeneration | 动作 |
|---|---|---|---:|---|
| access token 刷新，主体和权限不变 | 不变 | 不变 | +1 | 可复用 record；不加入旧凭证在途 fetch |
| token 刷新后 scope/role 改变 | 不变 | 新值 | +1 | 旧授权语义 record 不再命中 |
| Cookie 内容变化但同一登录会话 | 不变 | 通常不变 | +1 | 精确 fetch 分离；Vary: Cookie 时更新安全 fingerprint |
| 会话重新登录/rotation 改变隔离语义 | 不变或新 namespace | 新值 | 重置或 +1 | 旧 generation 撤销 |
| 切换账户 | 新值 | 新值 | 新值 | revoke 旧 namespace，清 UI 与缓存可达性 |
| 登出 | revoke | 不再可用 | 不再可用 | 提升 NamespaceGeneration，取消任务，禁止旧 Commit |
| 临时签名 URL 刷新 | 不变 | 不变 | +1 | 稳定 record 可命中，FetchExecutionKey 改变 |

`AuthorizationContextID` 不应直接由原始 token 哈希得到；它由应用按授权语义生成，避免 token 轮换无界制造缓存变体。


### 自定义凭证 header

Phase 0a 的 `ImageRequest.credentialHeaderNames` 允许调用者显式标记非标准凭证字段。规则：

- 名称规范化为小写，并必须是合法 HTTP token；
- 被标记字段不进入 FetchVariantKey 或 diagnostics；
- 实际凭证值不哈希，凭证变化仍由 CredentialGeneration 表达；
- header 名集合进入 FetchExecutionKey 的版本化 policy fingerprint，避免不同凭证形态错误 single-flight；
- URLSession task 注册该集合，跨 origin redirect 必须同时剥离内置与自定义凭证字段；
- 自定义凭证存在但 authorization context / credential generation 缺失时，在发网前 fail-closed。

内置敏感字段覆盖 Authorization、Proxy-Authorization、Cookie、API key 及常见 cloud/access-token 名称；不能识别的业务凭证必须由调用者显式分类。

## 5. Cookie 默认策略

Apple 的默认和后台 `URLSessionConfiguration` 通常使用共享 Cookie storage；显式设为 `nil` 可以禁用 Cookie storage。Fovea 的默认 composition root 应：

```text
httpCookieStorage = nil
httpShouldSetCookies = false
```

并通过显式 CookieProvider/RequestAuthorizer 注入当前请求需要的 Cookie。

若应用选择系统 `HTTPCookieStorage`：

- 应用必须提供稳定的 cookie partition generation；
- Fovea 不能通过读取 Cookie 内容自行推断账户边界；
- `Vary: Cookie` 时必须提供安全的 CookieVariantFingerprint；
- 无法提供这些元数据时，credential-bearing 请求 fail closed：不持久化、不跨请求合并；
- 共享 Cookie store 的变更通知只用于触发 generation 更新，不能把原始 Cookie 记录到 diagnostics。

## 6. Fail-closed 条件

以下任一成立时，默认禁止持久复用和网络 single-flight：

- 请求携带 Authorization/Cookie，但没有 SecurityNamespaceID；
- 账户/tenant 无法稳定区分；
- RequestAuthorizer 返回的 CredentialGeneration 未随凭证材料变化；
- `Vary: Cookie` 但无法构造安全 fingerprint；
- 调用者传入不透明 URLSession，无法说明 Cookie、client identity、proxy 或 protocol state；
- auth refresh 回调可能递归调用同一 pipeline 且没有重入保护。

Fail closed 不等于拒绝显示：请求仍可作为 task-local、不可复用的加载执行。`HTTPTransporting` 必须显式声明 `TransportReusePolicy`；内建默认 `URLSessionTransport` 使用固定安全配置并可复用，任何调用者提供的 `URLSessionConfiguration` 默认都是 `.taskLocal`。只有调用者提供稳定、非敏感且能覆盖 proxy、protocol、client identity 与其他会改变响应语义的 context identifier 时，才可显式启用跨请求复用。Fovea 只把该 identifier 的摘要纳入精确执行身份，不记录原值。

## 7. 并发与刷新

- 同一授权上下文的 refresh 应 single-flight，防止多个 401 同时刷新；
- 每个 fetch 最多触发一次显式 refresh cycle；
- refresh 完成后生成新 CredentialGeneration 和 FetchExecutionKey；
- refresh 期间 namespace 被撤销时立即终止，不再重试；
- 新 subscriber 加入不得重置 refresh/retry budget；
- auth provider 不得在持有 pipeline/task registry 锁时被调用。

## 8. Property tests

- **AUTH-PT-001**：token 刷新且权限不变时 FetchVariantKey 不变、FetchExecutionKey 改变；
- **AUTH-PT-002**：scope/role 改变时 AuthorizationContextID 改变；
- **AUTH-PT-003**：账户切换永不复用旧 namespace 的 record/blob；
- **AUTH-PT-004**：登出与 refresh/fetch Commit 竞态下旧数据不可达；
- **AUTH-PT-005**：Vary: Cookie 缺 fingerprint 时不持久化、不复用；
- **AUTH-PT-006**：raw token/Cookie 不出现在 key、日志、错误和 trace；
- **AUTH-PT-007**：并发 401 只触发一次 refresh；
- **AUTH-PT-008**：不透明 URLSession 缺上下文时进入 task-local fail-closed 模式；
- **AUTH-PT-009**：refresh 递归/重入不会死锁或无限循环；
- **AUTH-PT-010**：无鉴权 public URL 不要求 provider，FetchExecutionKey 不含 credential generation；
- **AUTH-PT-011**：revoke 清理完成后，晚到 304 metadata refresh 被 generation fence 删除；
- **AUTH-PT-012**：自定义 credential header 不进入稳定 identity，header 集合改变 exact execution identity，跨 origin redirect 会剥离，缺 auth context 时发网前失败。

## 9. 参考

- Apple `URLSessionConfiguration.httpCookieStorage`：默认/后台 session 使用共享 Cookie storage；设为 `nil` 可禁用。
- RFC 9111：认证响应、`Vary`、`no-store` 和 private cache 语义。
