# 缓存、身份与 HTTP 语义规范

> **状态：Proposed，Phase 0a 子集 / Phase 0b 完整可执行规范。**
> 本文规定稳定 key 构造、执行期合并键、Vary/auth 处理、partial 内容、原子提交、逻辑/物理 blob 身份、持久格式演进和派生缓存失效。实现不得用“等价优化”绕过这些规则。

## 1. 时序模型

```text
请求前：LogicalSourceID + ResolvedLocator + AuthorizationContextID
        → FetchVariantKey
执行前：FetchVariantKey + 精确请求执行指纹
        → FetchExecutionKey（仅内存）
响应后：RepresentationRecord（Vary/freshness/validator/content digest）
完整字节：ContentID
派生后：DecodeKey → RenderKey
```

- `FetchVariantKey` 用于 RepresentationRecord 候选选择，不承诺等于精确网络任务键。
- `FetchExecutionKey` 只用于当前进程的网络 single-flight，不持久化、不记录敏感值。
- `RepresentationRecord` 是可变 metadata record，不是内容身份。
- `ContentID` 只表示完整、验证后的 representation payload bytes。
- `DecodeKey`、`RenderKey` 不能在 ContentID 未确定时进入持久或跨请求缓存。

## 2. 稳定持久键编码

持久 key、文件名和 fingerprint 禁止使用 Swift `hashValue`、`Hasher`、对象地址、字典遍历顺序或平台相关归档结果。

持久编码使用版本化 canonical encoding，并固定：

```text
KeySchemaVersion
字段顺序与类型 tag
整数端序
nil/默认值表达
UTF-8 与 Unicode normalization
URL canonicalization policy（不得盲目排序 query 或删除重复参数）
浮点或颜色参数的量化规则（拒绝 NaN/Infinity，统一 -0）
```

编码后使用 SHA-256 等明确版本的密码学摘要，并把算法版本与 payload length 纳入存储 metadata。命中既有 blob 时校验长度和摘要，不以文件名存在作为完整性证明。ContentID 是逻辑摘要；物理文件使用 store-local、namespace-local 的随机不透明 PhysicalBlobID，不能直接暴露 ContentID。必须维护 golden vectors，证明同一语义在不同进程、架构和优化构建下得到相同字节和摘要。

`Hashable` 只可用于进程内 collection，不等于持久身份协议。URL 的 host/default port 等可按标准安全规范化；path、percent-encoding、query 顺序和重复参数默认保持语义，不做“看起来等价”的重写。只有调用者声明的 ephemeral signature 字段可以从稳定身份移除。

Golden vector：

- **KEY-GV-001**：固定的 public/auth URL 样例、header 变体、namespace 和 schema version 必须在不同进程、CPU 架构、Debug/Release 构建中产生相同 FetchVariantKey canonical bytes 与摘要。

## 3. FetchVariantKey 与 FetchExecutionKey

### 3.1 FetchVariantKey

```text
LogicalSourceID
+ stable resolved locator components
+ HTTP method
+ caller/adapter declared variant headers
+ known Vary schema and selected request values（若已有历史 record）
+ SecurityNamespaceID
+ AuthorizationContextID
+ request body digest（profile 支持非 GET 时）
```

### 3.2 FetchExecutionKey

```text
FetchVariantKey
+ exact resolved locator fingerprint
+ credential/cookie generation fingerprint
+ cache/revalidation mode
+ range/validator execution state
+ transport-affecting policy fingerprint
```

它解决稳定缓存身份与本次精确网络执行的冲突：签名 URL 或 token 刷新可以继续选择同一 record，但过期凭证的在途任务不能吞并新凭证请求。

### 3.3 敏感信息规则

- Bearer token、Cookie 值、签名 secret 不以明文或可逆形式进入持久 key、日志或 metrics。
- `SecurityNamespaceID` 隔离 user/tenant/profile。
- `AuthorizationContextID` 表示 principal、scope/entitlement generation 和 cookie partition generation。
- token 刷新但授权语义不变时，FetchVariantKey 不变；精确凭证 generation 改变时 FetchExecutionKey 改变。
- 权限、账户或会话隔离语义改变时 AuthorizationContextID 必须变化。
- credential-bearing 请求若无法提供稳定且安全的 AuthorizationContextID/cookie partition generation，默认禁止跨请求持久复用和网络合并；不能退化为只按 URL 缓存。

## 4. 键构造样例

### 4.1 公共静态 URL

```text
input:
  URL = https://cdn.example.com/a/avatar.jpg
  method = GET
  Accept = image/avif,image/webp,image/*
  namespace = public

FetchVariantKey:
  logical = normalized asset URL or caller asset ID
  locator = scheme+host+path+stable rendition query
  variant = Accept
  namespace = public

FetchExecutionKey:
  FetchVariantKey + fingerprint(完整 resolved request)
```

### 4.2 轮换 Bearer token

```text
input:
  URL = https://api.example.com/users/42/avatar
  Authorization = Bearer <rotating token>
  namespace = user:42
  authorizationContext = principal:42 + entitlementGeneration:7
```

FetchVariantKey 包含 namespace 与 opaque authorization context，不包含 raw token。token refresh 不击穿持久缓存，但 FetchExecutionKey 含 credential generation fingerprint，因此旧/新凭证在途请求默认不合并。

### 4.3 Cookie 会话

```text
input:
  URL = https://gallery.example.com/current/avatar
  Cookie = session=<secret>; locale=zh-CN
  namespace = account:A
  cookiePartition = account:A/sessionGeneration:3
```

raw Cookie 不进入持久 key。若响应声明 `Vary: Cookie`，实现不得持久化 raw Cookie；应由应用提供稳定的 cookie variant fingerprint，无法安全表达时禁用该 record 的复用。

### 4.4 首次出现 `Vary: Accept-Language`

第一次请求前，调用者或默认 variant policy 可把常见字段纳入 FetchVariantKey。响应 record 保存：

```text
Vary = Accept-Language
original request value = zh-CN
```

后续缓存选择必须比较该字段。对首次未知的自定义 Vary 字段：

- record 建立后更新该 logical source 的 known Vary schema；
- 后续 FetchVariantKey 包含该字段值；
- 首次并发请求只有在调用者预先声明字段或执行键精确相同时才合并；否则保守不合并。

### 4.5 签名 URL

```text
URL = https://cdn.example.com/asset/123?w=600&sig=<ephemeral>&exp=<time>
LogicalSourceID = asset:123
stable rendition = w=600
```

- `sig`、`exp` 不进入稳定缓存身份；
- 完整签名 URL 的不可逆 fingerprint 进入 FetchExecutionKey；
- 新签名可命中旧 record，但不会错误加入以过期 URL 运行的 task；
- 若服务端不能保证不同签名表示同一逻辑资产，调用者不得剥离这些字段。

### 4.6 同 URL、不同账户

账户 A/B 即使得到相同 ContentID，也使用不同 SecurityNamespaceID。默认不共享 blob、metadata、访问时间、quota 或清理生命周期。

## 5. Vary 与 record 选择

- `Vary: *` 的响应不得用于常规缓存复用。
- record 选择由 FoveaHTTP 完成，Akashic 只按指定索引读写。
- 已知 Vary 字段的原请求值保存在 RepresentationRecord；敏感字段只保存安全 fingerprint。
- field name 大小写不敏感；`Accept-Encoding`/`Accept-Language` 由唯一共享实现规范逗号 OWS 与大小写，未知扩展字段只移除首尾 OWS，不擅自改写引号或自定义语义；公开构造、record 选择与 Codable 持久化必须产生同一 canonical 表示，非规范持久值失败关闭。
- 多个匹配 record 时按 HTTP 语义和日期选择，不能简单按“最近访问”覆盖。

## 6. 所有权

| 决策或动作 | 所有者 | Akashic 是否理解语义 |
|---|---|---|
| freshness / stale 可用性 | FoveaHTTP | 否 |
| validator 与条件请求 | FoveaHTTP | 否 |
| 304 metadata merge | FoveaHTTP | 否 |
| `Vary` 匹配 | FoveaHTTP | 否 |
| 是否允许持久化 | FoveaHTTP + SecurityPolicy | 仅执行结果 |
| blob staging/hash/atomic commit | Akashic | 只理解事务 |
| Fetch single-flight | FoveaCore，按 FetchExecutionKey | 否 |
| URLCache 是否启用 | composition root；默认关闭独立持久化 | 否 |
| schema/generation 迁移 | Akashic | 理解存储版本，不理解 HTTP |
| quota、lease、physical GC | Akashic + Fovea CachePolicy | 执行预算，不理解图片语义 |

HTTP profile、外部一致性语料和时钟规则见 `http-cache-conformance.md`。调度与共享任务规则见 `scheduler-semantics.md`。应用鉴权、Cookie partition 和 credential generation 见 `auth-context-integration.md`。

## 7. Payload、完整内容、206 与 partial

### 7.1 Stored payload layer

ContentID 对传给 ImageCraft 的 representation payload bytes 求摘要。Transport 必须声明 body 是否已完成 HTTP content decoding，存储层不得混用 wire bytes 与 decoded bytes。

- 若 URLSession 已透明解压，wire Content-Length 不能直接验证 decoded payload 长度；
- 跨请求 Range resume 默认只在 `Content-Encoding: identity`、总长度已知且存在强 validator 时启用；
- content coding 不明确时回退完整 GET。

### 7.2 完整 200

只有以下全部满足才生成 ContentID：

- body 正常结束；
- 可适用的长度/完整性检查通过；
- DecodeLimits/maximumEncodedBytes 未超限；
- integrity hint（若有）通过；
- 增量摘要完成。

随后用事务提交 blob 与 RepresentationRecord 引用。

### 7.3 206 Partial Content

206 只能写入 `PartialTransferRecord`：

```text
record schema version
FetchVariantKey
strong validator
total representation length
covered byte ranges
payload/content-encoding layer
staging locator
expiry
```

- 没有强 validator 时默认不跨请求合并 range；
- 非 identity content encoding 默认不做 range 拼接；
- ranges 完整覆盖表示后按顺序拼接并完成最终摘要；
- 只有此时才生成 ContentID 和 OriginalEncoded；
- validator 或 payload layer 变化时所有旧 partial 作废。

### 7.4 中断的 200

中断 body 默认回收。只有服务器支持安全恢复、存在强 validator、策略允许且不含禁止项时，才能转成隔离 partial record。

### 7.5 Progressive preview

ContentID 未确定前可以向当前 fetch task 的订阅者交付 preview，但必须先通过最小安全门：响应不是已知非图像、magic/容器头可识别、声明尺寸/像素/帧数未超限、增量 decoder 没有报告结构性损坏。未完成最小 Probe/Security 检查前不得向 UI 交付像素。

- 使用 `EphemeralTransferID`；
- 不进入 OriginalEncoded、DerivedEncoded 或跨请求 RenderedMemory；
- 不写最终 RenderKey；
- fetch 失败后 preview 只作为 UI 瞬态。

## 8. 提交资格矩阵

计算出 ContentID 不等于缓存条目已经可见。所有写入还必须通过安全探测、HTTP policy、namespace generation 和对应层的资格检查。

| 层 | 最早提交点 | 必要条件 | 不依赖 |
|---|---|---|---|
| OriginalEncoded | 完整 payload + hash + Probe/Security accepted 后 | HTTP 可存、namespace active、MIME/magic/limits 通过 | 最终 Transform 成功 |
| RepresentationRecord | 与 Original blob 引用同一事务 | record 与 blob 一致、Vary/auth/freshness 完整 | Rendered 结果 |
| RenderedMemory | Decode/Transform final 成功后 | target pixels 已知、非 no-store、namespace active | 磁盘写成功 |
| DerivedEncoded | final image/plan 可重建且准入通过后 | source 允许 transform、encoder 成功、variant cap | UI 仍在订阅 |
| Analysis | 分析完成后 | source 允许缓存、AnalysisKey 完整、namespace active | Rendered 缓存 |
| Progressive preview | 不进入 reusable cache | 仅当前 task/token | ContentID/最终成功 |

规则：

- `text/html`、magic 不符、security limit、损坏 bitstream 不得提交 OriginalEncoded 为可见图片 record；
- “识别为安全格式但当前没有 decoder”是否保存 OriginalEncoded 是显式策略，v1 默认不保存；
- Processing 失败不自动删除已经安全提交的 OriginalEncoded；
- cache write 失败不阻止已成功生成的 final image Deliver；
- RenderedMemory 的廉价发布可在 Deliver 前完成；非关键磁盘 fsync、Derived/Analysis 写入、GC 和机会式迁移不得位于 UI critical path；
- 后台写入仍是结构化任务，必须受预算、取消策略和 NamespaceGeneration 栅栏约束；
- Commit 是多个受控 checkpoint，不要求 OriginalEncoded 等待最终 Transform。

## 9. 304、提交与 namespace 撤销

- 304 不创建新 ContentID；FoveaHTTP 按 profile merge metadata；
- 更新后的 RepresentationRecord 继续引用原 blob；
- record 更新原子化；同 variant 的 304 metadata 覆盖或 200 新内容覆盖若在 namespace 仍有效时取消/失败，必须恢复旧 record；若 generation 已撤销，则只删除新状态，绝不恢复旧 generation；
- 每个任务捕获 `NamespaceGeneration`；logout/revoke 后 Commit 必须再次校验；
- 被撤销 generation 的旧任务即使完成，也不得提交 memory、blob、record、Derived 或 Analysis；
- 物理清理可异步，逻辑不可达必须立即生效。

## 10. Blob 引用与删除

- ContentID 只作为逻辑索引；物理目录使用随机、不透明 `PhysicalBlobID`；
- metadata 在 namespace 内维护 `ContentID -> PhysicalBlobID`，跨 namespace 不共享 locator；
- 同一 namespace 内多个 RepresentationRecord 可以引用同一 ContentID blob；
- record 引用 ledger 与 record 变化在同一 metadata transaction；
- refcount 为零后经过 grace period 才删物理文件，避免并发 reader 竞态；
- crash 可产生 orphan blob，但不得产生指向缺失 blob 的可见 record；
- 后台 mark-and-sweep/ledger reconciliation 回收 orphan；
- 跨 namespace 默认没有共享 ledger；
- 每个 active reader 持有短期 lease，逻辑 record 删除后仍等 lease 释放再删物理文件；
- 详细 hard/soft limit、namespace quota、类别预算、atime batching 与 GC 规则见 `cache-budget-gc.md`。

## 11. 损坏、磁盘不足与自愈

- record 指向缺失、长度不符或摘要不符的 blob：隔离损坏文件、逻辑删除 record、按 miss 继续；
- SQLite/metadata generation 无法安全打开：隔离该 generation，创建新 generation；缓存损坏不得导致 App crash；
- ENOSPC、权限变化或文件保护导致 cache write 失败：丢弃该次缓存提交，但若图片已成功解码，仍正常 Deliver；
- cache read/write 错误默认是性能退化，不是资源加载失败；仅 `.onlyIfCached` 一类显式策略可把 miss 暴露为结果；
- 任何失败都不得留下可见半 record、错误 ref ledger 或跨 namespace 文件；
- 自愈/GC 受 DiskIOBudget 控制，不能在交互路径全盘扫描。

## 12. DerivedEncoded 与 Analysis 继承规则

派生物不能比来源拥有更宽松的持久化权限：

```text
source no-store       → 仅同一 in-flight task cohort 的当前订阅者共享；任务 terminal 后不满足任何新请求
source no-transform   → 不写任何内容变换后的 DerivedEncoded
source namespace      → Rendered/Derived/Analysis 同 namespace
namespace revoke      → 派生物立即不可达
source privacy class  → 派生物继承或更严格
```

`no-store` 的瞬态持有边界：

- 可以在一个正在执行的 fetch/decode task 内向已加入的多个 subscriber 交付同一结果；
- task terminal 后不得把结果放入页面、屏幕或进程级 ephemeral cache 来满足后续请求；
- UI view 可以继续显示已经交付的像素，直到 token/identity/view 生命周期结束；
- UI retention 不产生 cache hit，也不得被新 view/request 查询；
- namespace revoke、账户切换或敏感 identity 变化时立即清除。

### 12.1 DerivedEncodedKey

```text
ContentID
+ canonical Decode/Transform plan
+ encoder fingerprint
+ output format/color/HDR/attachment policy
+ key schema version
```

### 12.2 AnalysisKey

```text
ContentID
+ AnalysisKind
+ implementation/model fingerprint
+ Vision/API revision（适用时）
+ normalized parameters
+ feature schema version
+ locale/orientation/color context（确实影响结果时）
```

模型、算法、Vision revision 或 feature schema 变化自然 miss；旧分析结果惰性删除。Analysis 结果可能泄漏内容语义，必须使用独立预算并继承 security namespace、TTL 和文件保护策略。

若 Analysis proposal 被接受并改变最终像素，其 fingerprint 还必须进入 RenderKey。

## 13. 持久格式演进

Store manifest 明确记录：

```text
StoreFormatVersion
KeySchemaVersion
RecordSchemaVersion
BlobFormatVersion
AnalysisSchemaVersion
hash algorithm
StoreGenerationID
```

升级策略：

- 兼容 record：读旧、机会式重写；
- 单条不兼容 record：当 miss 并逻辑删除，blob 延迟 GC；
- key/global layout 不兼容：新建 StoreGeneration 并原子切换；
- 安全关键变化：立即撤销旧 generation 可达性；
- 未知未来版本：不得写回，按不兼容处理；
- 启动路径不得同步全盘迁移；后台迁移/清理受 DiskIOBudget 限制且幂等；
- 不保证缓存格式向下兼容。

详细决策见 `../adr/0002-persistent-cache-evolution.md`。

## 14. 进程模型

v1 的 Akashic disk store 默认是**单进程协调模型**：同一进程内多个 pipeline/store handle 共享一个 coordinator。App、Widget、Extension 等多个进程不得直接同时写同一 store generation。

若调用者使用 App Group：

- 默认每个进程使用独立 store/namespace；或
- 启用未来的 explicit multi-process coordinator（文件锁、generation lease、SQLite/blob 原子协议均通过测试）。

仅有 SQLite WAL 不足以证明 blob rename、generation switch、GC 和 namespace revoke 的多进程正确性。在 multi-process capability 毕业前，检测到并发 writer 应 fail closed 或切换只读/独立 store，不能“尽力而为”。

## 15. App / Widget 推荐共享模式

v1 不让 App 与 Widget 并发写同一个 Akashic generation。需要 Widget 展示图片时，推荐：

- App 与 Widget 各自使用独立 store/namespace；
- App 显式导出已确认公开、无鉴权、允许 transform 的小尺寸缩略图；
- 导出目录使用独立 version/manifest、随机文件名和原子 replace；
- Widget 只读，不参与 OriginalEncoded、auth metadata、ref ledger 或 GC；
- 导出物不包含原始私有 URL、ContentID、Cookie、token 或账户标识；
- logout/权限变化时删除对应导出 manifest 和文件；
- 私有/认证 OriginalEncoded 默认禁止导出。

这是一条产品集成通道，不是 multi-process Akashic store capability。

## 16. Property-test 最小集合

- **CACHE-PT-001**: token 刷新不改变 FetchVariantKey，但 credential generation 改变 FetchExecutionKey；
- **CACHE-PT-002**: 主体/权限代际变化改变 AuthorizationContextID；
- **CACHE-PT-003**: 相同 URL 的账户 A/B 永不复用彼此 record/blob；
- **CACHE-PT-004**: `Vary` 字段不同不得命中同一 record；
- **CACHE-PT-005**: `Vary: *` 不复用；
- **CACHE-PT-006**: fresh record 不访问网络；
- **CACHE-PT-007**: stale + validator 发条件请求；
- **CACHE-PT-008**: 304 复用 ContentID 并更新 metadata；若 304 将策略改为 `no-store`/`Vary: *`，当前请求仅瞬态使用字节并撤销 reusable memory/record/blob；
- **CACHE-PT-009**: `no-store` 不产生持久文件、Derived 或 Analysis；
- **CACHE-PT-010**: incomplete 200 不生成 ContentID；
- **CACHE-PT-011**: 206 ranges 只有完整覆盖、payload layer 和 validator 一致时才能提交；
- **CACHE-PT-012**: progressive preview 不能成为最终缓存命中；
- **CACHE-PT-013**: crash 位于 blob rename 与 record commit 任一点都能恢复一致状态；
- **CACHE-PT-014**: signed URL refresh 可命中稳定 record，但不与旧 locator 在途 task 错误合并；
- **CACHE-PT-015**: logout/revoke 与 Commit 竞态下旧 generation 写入始终为零；旧 generation record 即使物理残留也不能被新 generation 查询命中；
- **CACHE-PT-016**: Analysis model/revision 变化必然 miss；
- **CACHE-PT-017**: 持久 key golden vectors 跨进程/架构一致；
- **CACHE-PT-018**: 未发布的旧 record schema 不再解析或静默降级；直接打开旧目录时失败关闭且不重写原文件，正式组合根通过 StoreGeneration 切换；
- **CACHE-PT-019**: StoreGeneration 切换任意 crash point 可恢复；
- **CACHE-PT-020**: 多 record 引用时删除一个 record 不提前删除 blob；
- **CACHE-PT-021**: unknown future schema 不被当前版本修改；
- **CACHE-PT-022**: non-identity Content-Encoding 不启用跨请求 Range 拼接；
- **CACHE-PT-023**: credential-bearing request 缺少安全 auth context 时不持久化、不跨请求合并；
- **CACHE-PT-024**: 未启用 multi-process shared-writer capability 时，同进程重复打开复用同一组 store actor；跨进程第二个 writer 立即失败关闭，owner 退出后才能重新取得租约；活动 generation 的运行预算配置不得静默分叉；
- **CACHE-PT-025**: blob 文件名命中但长度/摘要不符时视为损坏并隔离；
- **CACHE-PT-026**: `no-store` 只在同一 in-flight task cohort 内共享；task terminal 后不能满足新请求；
- **CACHE-PT-027**: query 顺序/重复参数变化默认改变 key，只有显式 ephemeral 字段可移除；
- **CACHE-PT-028**: ENOSPC/cache corruption 不阻止已成功解码图片交付，且不产生半提交；
- **CACHE-PT-029**: ContentID 已计算但安全 Probe 失败时 OriginalEncoded 不可见；
- **CACHE-PT-030**: Transform 失败时已安全提交的 OriginalEncoded 与 representation record 保持有效，Rendered/Derived 不提交；后续请求可复用原编码并重新执行 transform，不重复发网；
- **CACHE-PT-031**: ContentID 不直接出现在物理文件名、日志或跨 namespace locator；
- **CACHE-PT-032**: hard limit/namespace quota 永不被普通写入突破；
- **CACHE-PT-033**: active lease 期间不物理删除 blob，但逻辑记录可立即 miss；
- **CACHE-PT-034**: cache hit 不同步持久化精确 atime；
- **CACHE-PT-035**: GC/ENOSPC/diagnostics degradation 不覆盖成功 final。
- **CACHE-PT-036**: progressive preview 未通过最小 Probe/Security gate 时不向 UI 交付像素；
- **CACHE-PT-037**: Widget 导出目录不包含 auth OriginalEncoded、ContentID 或敏感 metadata，Widget 不能写主 store；
- **CACHE-PT-038**: namespace revoke 后的新 200 必须写入当前 NamespaceGeneration；重建内存 pipeline 后仍可选择该 fresh record，不永久退化为网络 miss；
- **CACHE-PT-039**: 同 variant 的 304 metadata 覆盖或 200 新内容覆盖若在 namespace 仍有效时被调用方取消，事务必须恢复旧 record；namespace 已撤销时则删除新 record，不能复活旧 generation。
- **CACHE-PT-041**: OriginalEncoded staging 写入不得在显式 publish 前通过逻辑清单可见；decode/安全验证失败、取消或 revoke 必须 discard，GC 不得误删仍在途 stage；只有 stage 与 RepresentationRecord 均原子发布后，成功 completion 才成立。
- **CACHE-PT-042**: 已通过安全探测、目标解码、transform 与 namespace fence 的完整像素可作为 preview 先显示；final 事件与 `image(for:)` completion 仍必须等待 OriginalEncoded 与 RepresentationRecord 的耐久发布。

- **CACHE-PT-046**: transport-verified handoff 的字节若在 probe/decode 被证明非法，必须删除 handoff，禁止持久化；下一消费者重新回源并只提交通过完整图像门禁的字节。
- **CACHE-PT-047**: 明确可复用、无需立即再验证且仍新鲜的 200 响应，可在完整 FetchExecutionKey 下保留最多 250 ms 的进程内 completion handoff，以覆盖 fetch 完成到 decode/persist 可见之间的 delayed-hit 窗口；它不得成为无界或跨身份缓存。
- **CACHE-PT-048**: `no-store`、`no-cache`、`max-age=0`、不可表示/通配 `Vary` 与非 200 响应不得进入 completion handoff。
- **CACHE-PT-049**: 持久缓存损坏或 probe/decode 负证明必须撤销对应 completed handoff；撤销只作用于 exact key 的已完成条目，不得取消 active fetch。租约到期后新调用必须重新执行。
