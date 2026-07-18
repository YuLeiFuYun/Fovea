# Fovea Private Image Cache Profile 与一致性测试

> **状态：Proposed，Phase 0b/Core v1 门禁；Phase 0a 只实现内部最小子集。**  
> 本规范定义 Fovea 支持的 HTTP 缓存子集、外部测试语料接入方式和明确不支持的范围。它不是通用代理缓存规范。

## 1. Profile 范围

### Phase 0b 必须支持

- GET；
- 200 image representation；
- 条件 GET 与 304；
- 显式 freshness：`Cache-Control: max-age`、`Expires`、`Age`；
- `ETag`、`Last-Modified`；
- `Vary` 与 `Vary: *`；
- `no-cache`、`no-store`、`private`、`must-revalidate`；其中 `no-store` 禁止 reusable memory/disk cache，只允许同一 in-flight task cohort 处理；task terminal 后不能满足新请求；
- Authorization/Cookie 对应的 private security namespace；
- 跨 origin redirect 不继承 Authorization；
- 默认关闭独立 `URLCache` 持久化，避免双重缓存。

### Core v1 Candidate

- 206、Content-Range、If-Range 与强 validator；
- `stale-while-revalidate`、`stale-if-error`（作为显式 capability）；
- `no-transform` 对 DerivedEncoded/格式转换的约束；
- 更完整的 request cache policy 映射。

### 默认不支持或不持久化

- POST、PUT、PATCH、DELETE 等 unsafe method；
- 负响应缓存（404/410 等）；
- 通用 redirect cache；
- 启发式 freshness；
- shared proxy cache、`s-maxage` 和代理语义；
- 未声明支持的 status/method/directive 组合。

HTTP 缓存是可选机制。遇到 profile 外行为时，默认回源或不持久化，不猜测缓存语义。

## 2. 时钟模型

实现注入：

```text
WallClock        解析 Date/Expires 与跨进程持久时间
MonotonicClock   测量当前进程内 request/response resident duration
```

规则：

- current age 使用 RFC 9111 对应公式和饱和算术；
- delta-seconds 溢出时饱和，不允许变成负数；
- wall clock 明显回拨、Date 无法解析或时间关系不可信时，record 保守视为 stale；
- 测试使用 TestWallClock，禁止依赖真实 sleep；
- RepresentationRecord 持久化计算所需的 requestTime、responseTime、Date/Age 派生值，而不是只存一个模糊 TTL。

## 3. Header 持久化策略

Fovea 不向应用重放任意 HTTP response，因此只保存：

- cache selection/freshness/validation 所需字段；
- Content-Type、Content-Length/Range、Content-Encoding、Content-Language 等图像表示字段；
- 调试所需的脱敏信息。

不得持久化或回放：

- `Set-Cookie`；
- `Authorization`、`Proxy-Authorization`；
- Authentication-Info/Proxy-Authentication-Info；
- hop-by-hop headers；
- 未脱敏的私有 query/header。

字段名匹配大小写不敏感；`Vary` 字段规范化必须遵守 HTTP field 语义，不能简单按原始字符串字节比较。

## 4. URLSession 隐式状态边界

Fovea 默认 composition root 使用可解释配置：

- `urlCache = nil`，request policy 绕过独立 URLCache 持久化；
- 自动 Cookie 行为默认关闭，或由显式 `CookieProvider` 注入；
- 若使用调用者提供的 cookie/session，必须同时提供 cookie partition generation / AuthorizationContextID；
- redirect delegate 对跨 origin Authorization 做显式剥离；
- TLS client identity、proxy、cookie store、protocol classes 等会影响响应的配置必须进入 transport policy fingerprint；
- 调用者注入不透明 session 且无法提供这些 identity 时，Fovea 保守禁用持久缓存与跨请求合并。

隐藏的 URLSession Cookie、URLCache 或 credential storage 不能绕过 FetchVariantKey/FetchExecutionKey。

## 5. Content-Encoding 与 Range

`ContentID` 对 **传给 ImageCraft 的 representation payload bytes** 求摘要，而不是 HTTP framing 字节。

- Transport 必须声明 body 是 content-decoded 还是 wire encoded；
- 同一 profile 内存储层固定一种 payload layer，不允许混用；
- 若 URLSession 已透明解压，不能用 wire `Content-Length` 直接验证解压后长度；
- 跨请求 Range resume 默认仅在 `Content-Encoding: identity`、总长度已知且存在强 validator 时启用；
- 非 identity content coding 或语义不明确时禁用 range 拼接，改为完整 GET。

## 6. 外部一致性语料

### 6.1 来源

1. RFC 9111/9110 规范场景；
2. `cache-tests.fyi`；
3. Web Platform Tests `fetch/http-cache` 和 `fetch/stale-while-revalidate` 中适用场景；
4. Chromium/WebKit/成熟库公开回归用例，仅作为差分启发。

WPT 的 http-cache 测试从 Fetch API 视角定义，其中 cache mode、document cache 和浏览器行为不一定适用于 Fovea。`cache-tests.fyi` 的结果页也明确说明项目仍在进行中、结果可能有误，不适合直接比较实现支持度。两者用于发现场景和回归，不是唯一 oracle；最终 expected result 必须映射到 RFC section 与 Fovea profile。不得直接把“外部套件全部通过”当目标，也不得在未分析时全部排除。

### 6.2 Test provenance manifest

每个移植用例记录：

```text
local test id
source project
upstream URL / commit / license
upstream test id
RFC section
profile capability
classification
expected result
adaptation notes
```

classification：

```text
required
optional-caching-choice
not-applicable
stricter-security
```

`not-applicable` 必须经过 review，并说明是 Fetch/browser 特性、profile 明确不支持，还是 Fovea 选择不缓存。

### 6.3 门禁

- Phase 0b：freshness、Age、Vary、304、auth/no-store 核心外部向量全部通过；
- Core v1：manifest 中所有 required profile tests 100% 通过；
- 上游 corpus 固定 commit，升级单独 PR；
- 失败不得通过更新 expected result 隐藏；语义变更必须 ADR。

## 7. 必测组合

- Date/Age/max-age 的不同组合与时钟偏移；
- max-age=0、no-cache、must-revalidate；
- no-store 与 private namespace；
- `Vary` 大小写、空白、多字段、`*`；
- 304 缺失/更新部分字段时保留旧 metadata；
- weak/strong ETag；
- Last-Modified fallback；
- Authorization 请求的 private 存储；
- credential 刷新、缺失 AuthorizationContextID 的 fail-closed 行为和 namespace 切换；
- 206 validator 变化；
- Content-Encoding 非 identity 时禁用 Range；
- unsafe method/profile 外 status 默认不持久化；
- 自动 Cookie/URLCache 被禁用或显式纳入 identity；
- `Set-Cookie` 与认证字段不会进入持久 record；
- `no-store` response 不产生下一请求可命中的 RenderedMemory/Metadata/Original/Derived/Analysis。

## 8. 可观测性

每次缓存决策输出脱敏 reason code：

```text
freshHit
staleRevalidate
notStoredNoStore
notStoredProfileUnsupported
varyMismatch
varySchemaUnknownNoMerge
authNamespaceMismatch
validator304
rangeResumeDisabledContentEncoding
clockAnomalyTreatedStale
```

reason code 必须可用于测试断言，不能只输出自由文本日志。
