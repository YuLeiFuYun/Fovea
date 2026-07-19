# 错误、重试与回退规范

> **状态：Active Phase 0a 子集 / Core v1 Candidate 规格。**

## 1. 目标

错误必须说明发生阶段、是否终止请求、是否允许重试或回退，以及哪些信息可以暴露给调用者。缓存写失败、取消和安全拒绝不得被压缩成一个无法推理的 `Error`。

## 2. 错误模型

```text
PipelineFailure
├── category
├── stage
├── disposition
├── reasonCode
├── sanitizedContext
├── underlyingCause（仅调试，脱敏）
└── retryAfter（可选）
```

`category`：

```text
source
transport
http
securityLimit
securityPolicy
namespaceRevoked
schemaIncompatible
cacheRead
cacheWrite
probe
decode
processing
unsupportedCapability
cancelled
```

`disposition`：

```text
terminal
retryable
fallbackAllowed
cacheDegraded
cancelled
```

同一失败可以同时具备结构化属性，例如 `cacheWrite + cacheDegraded`，但必须只有一个面向调用者的最终结果。

## 3. Phase 0a 已实现子集

公开加载 API 统一抛出 `PipelineFailure`，当前稳定字段为：

```text
category
stage
disposition
reasonCode
statusCode（HTTP 时可选）
```

Phase 0a 已实现 transport、HTTP、authorization、security limit、namespace revoke、cache degradation、probe、decode 与 cancellation 的脱敏映射。SwiftUI failure surface 接收 `PipelineFailure`，取消 disposition 映射为 `.cancelled`。底层 `URLError`、`TransportError`、`ImageCraftError` 和磁盘路径不直接暴露。

当前实现对幂等 GET 执行有界 retry，并在 pipeline policy 与请求级 `ImageRequest.stalePolicy` 同时允许时执行 stale-if-error。共享 fetch 的订阅者可分别接受或拒绝 stale；该交付偏好不改变上游 FetchExecutionKey。

## 4. 非终止性失败

以下默认不能把已成功生成的图片变成失败：

- memory/disk cache 写入失败；
- atime、GC、机会式 schema rewrite 失败；
- diagnostics sink 丢弃事件；
- DerivedEncoded 或 Analysis 写入失败；
- 已有 final image 后的后台 revalidation 失败，且策略允许保留当前结果。

这些情况记录 degradation event。只有 `.onlyIfCached`、`requirePersistence` 等显式策略才可把对应失败提升为终止结果。当前 `.onlyIfCached` 只接受 fresh、完整且可成功读取/解码的缓存表示；miss、stale、损坏记录或 task-local transport 均在发网前返回 `cacheRead/cacheLookup/terminal/only-if-cached-miss`。缓存条目已命中但解码失败时保留真实解码错误，不伪装成 miss。

## 5. 重试

v1 只自动重试幂等 GET 的明确瞬态失败：

- 网络暂时不可达、连接重置等 transport error；
- 429/503 且策略、`Retry-After`、deadline 和预算允许；
- 授权适配器最多进行一次显式 refresh cycle。

规则：

- 指数退避使用有界 jitter；
- 重试总次数、总时间和总额外字节有硬上限；
- 新 subscriber 加入不重置共享任务 retry budget；
- 取消、securityLimit、securityPolicy、schemaIncompatible、确定性 decode failure 默认不重试；
- retry 若改变 exact locator、credential generation、range state 或 transport policy，必须生成新的 FetchExecutionKey；
- retry 不得绕过 Low Data Mode、expensive network 或 namespace revoke。

## 6. 回退顺序

允许的回退必须显式、有限且保持身份语义：

```text
fresh reusable result
→ stale result（策略允许时）
→ network/source fetch
→ 同一 ContentID 的替代 decoder/backend
→ 已声明等价的 representation candidate
→ failure
```

- stale-if-error 只能在 HTTP profile、pipeline policy 与请求级策略同时允许时使用；认证/私有结果仍受 namespace 和 generation 限制；
- 替代 decoder 不得绕过 Probe/SecurityPolicy，也不能改变输出语义而不更新 DecodeKey；
- representation fallback 必须来自同一 logical asset 的声明候选，不能把任意 URL 当作备用图而沿用原 key；
- placeholder/error image 是 UI 展示，不是成功结果或可缓存的资源替代。

## 7. 共享任务与订阅者差异

底层 fetch/decode 可以共享，但订阅者的交付策略可能不同：

- 会改变上游网络执行的 cache/retry/network policy 必须进入 FetchExecutionKey 或阻止合并；
- 仅影响最终 UI 展示的 fallback 可以按 subscriber 独立处理；
- 一个 subscriber 接受 stale 不能迫使另一个要求 fresh 的 subscriber 接受 stale；
- 共享任务的 underlying failure 只产生一次，按各 subscriber policy 映射为 final/stale/failure。

## 8. 错误暴露与隐私

公开错误不得包含：

- raw URL 私有 query；
- token、Cookie、签名；
- ContentID/物理 blob locator；
- 用户或 tenant 的原始 namespace ID。

公开 API 返回稳定 category/reason code；底层 NSError/decoder 信息仅在脱敏诊断中保留。错误描述文本不作为程序逻辑依据。

## 9. UI 恢复矩阵

| 结果/错误 | 默认 UI 行为 | 自动重试 | 旧图/placeholder |
|---|---|---|---|
| `cancelled` | 静默结束当前 token | 否 | 按 retention policy |
| `namespaceRevoked` | 立即清除私有像素 | 否 | 不保留旧私有图 |
| `securityLimit` / unsafe probe | 显式失败或安全占位 | 否 | 不显示被拒绝像素 |
| `securityPolicy` / 明文远程 URL 或降级 redirect | 显式失败 | 否 | 不发出或立即终止不安全传输 |
| transient transport | 可显示 retry 状态 | 有限、有预算 | 可保留安全 placeholder/旧公开图 |
| HTTP 401/403 | 允许一次 authorizer refresh 后失败 | 仅显式一次 | 私有旧图按 namespace policy |
| HTTP 404/410 | 终止失败 | 默认否 | 调用者错误图 |
| cache read/write degradation | 对已有 final 静默降级 | 否 | 保留 final |
| decode unsupported | 尝试明确 fallback 后失败 | 否 | placeholder/error image |
| stale delivered | 标记 source/staleness | 后台 revalidate 依策略 | 保留 stale 直到替换 |

UIKit/AppKit/SwiftUI 必须共享同一 disposition 到 UI action 的映射；UI adapter 不自行发明 retry。

## 10. Property tests

- **ERR-PT-001**: cache write 失败不覆盖成功 final；
- **ERR-PT-002**: `.onlyIfCached` miss 返回明确结果且不访问网络；
- **ERR-PT-003**: retry budget 不因 subscriber join 重置；
- **ERR-PT-004**: cancellation/security failure 不重试；
- **ERR-PT-005**: credential refresh 后使用新 FetchExecutionKey；
- **ERR-PT-006**: stale 仅交付给允许它的 subscriber；
- **ERR-PT-007**: 替代 decoder 不绕过安全拒绝；
- **ERR-PT-008**: representation fallback 改变候选时身份与诊断可追踪；
- **ERR-PT-009**: 公开错误不包含秘密或稳定内容摘要；
- **ERR-PT-010**: shared underlying failure 不 double-complete。
- **ERR-PT-011**: namespaceRevoked 在所有 UI adapter 中立即清图且不自动重试；
- **ERR-PT-012**: securityLimit 不保留被拒绝像素；
- **ERR-PT-013**: cache degradation 不覆盖成功 final；
- **ERR-PT-014**: UIKit/AppKit/SwiftUI 对同一 disposition 产生一致默认 UI action；恢复矩阵唯一实现在 `FoveaCore`，三个平台策略模块只委托该映射，不维护副本。
