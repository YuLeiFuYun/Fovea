# Fovea 测试 ID 注册表

> **状态：Proposed。**
> 测试 ID 是稳定引用。实现文件名、测试框架和目录可以变化，但 ID 的语义不得静默改变；语义变化必须新建 ID，并将旧 ID 标记为 Superseded。

## 1. 命名空间

| 前缀 | 规格 |
|---|---|
| `CACHE-PT` | 缓存、身份、HTTP record、提交与持久化 |
| `AUTH-PT` | 鉴权上下文、Cookie、refresh 与账户切换 |
| `SCHED-PT` | single-flight、优先级、取消与 retry |
| `GEO-PT` | target pixels、布局与动态 resize |
| `UI-PT` | SwiftUI/UI token 与展示状态机 |
| `SOURCE-PT` | File/Data/Asset/Photos/Custom source identity |
| `ERR-PT` | 错误、重试与 fallback |
| `PIPE-PT` | Pipeline configuration 与 registry |
| `RES-PT` | 资源 permit、pressure 与公平性 |
| `GC-PT` | quota、lease、physical GC 与 ENOSPC |
| `DIAG-PT` | diagnostics schema、隐私与背压 |
| `IMG-PT` | orientation、颜色、alpha、HDR 与 attachments |
| `CODEC-PT` | codec 能力、插件装配、prepared lifecycle 与后端身份 |
| `KEY-GV` | 持久键 canonical encoding golden vectors |
| `HTTP-CONF` | 外部 HTTP conformance manifest 用例 |
| `SEC-CASE` | 安全默认矩阵案例 |
| `AIQA-GATE` | AI agent 权限、证据、独立验收和发布治理 |
| `AIQA-MUT` | Fovea 关键不变量变异体 |
| `COMP-EVIDENCE` | 竞品契约的机器可汇总证据记录 |
| `DEMO-PT` | 示例产品、真实网络实验与副作用边界 |
| `VISUAL-PT` | 跨设备截图、Accessibility 与几何视觉保证 |

## 2. Phase 0a 产品测试与 AIQA 分级

0a 只要求最小垂直切片的 blocker tests：

```text
KEY-GV-001      FetchVariantKey canonical bytes 稳定
CACHE-PT-003    账户 namespace 不串号
CACHE-PT-006    fresh record 不访问网络
CACHE-PT-005    Vary: * 不复用
CACHE-PT-008    304 复用 ContentID；策略转 no-store 时撤销 reusable state
CACHE-PT-010    incomplete 200 不生成 ContentID
CACHE-PT-014    signed locator refresh 复用稳定 record、改变执行身份
CACHE-PT-015    revoked generation 不提交且旧代 record 不可见
CACHE-PT-017    持久 key golden vector
CACHE-PT-018/021  预发布旧 schema 与未知未来 schema 均失败关闭且不被重写
CACHE-PT-025    已存在 blob 仍验证长度与摘要
CACHE-PT-026    no-store 只允许 in-flight task cohort
CACHE-PT-027    query 顺序与重复参数保留语义
CACHE-PT-028    持久写失败不产生内存/磁盘半提交
CACHE-PT-029    Probe 失败时 OriginalEncoded 不可见
SCHED-PT-004    最后订阅者只取消一次
SCHED-PT-010    完成/取消/错误不 double-complete
SCHED-PT-013    取消 subscriber 立即结束等待，不阻塞其他 subscriber
SCHED-PT-017    同一 ScopedRenderKey 的并发 transform 只执行一次
GEO-PT-002      0x0 不触发原尺寸 decode
IMG-PT-001      EXIF orientation 参与 target geometry
UI-PT-001       迟到结果不覆盖新 identity
UI-PT-015       图片无障碍语义必须显式声明
UI-PT-024       完整像素 preview 与 durable final 的可见回调分离；preview 不得冒充 terminal final
AUTH-PT-001     token refresh 的 variant/execution key 分离
AUTH-PT-003     账户切换隔离
AUTH-PT-006     凭证不进入 key/log/trace
ERR-PT-001      cache write 失败不覆盖 final
ERR-PT-009      公开 PipelineFailure/diagnostics 不泄漏底层 URL、秘密或稳定摘要
DIAG-PT-001      OSLog 输出与静态标识符不得泄漏 raw URL、token、ContentID 或自由文本
DIAG-PT-002...004  correlation ID 不跨 pipeline 稳定，sink 阻塞/队列满不影响 final
DIAG-PT-005      fetch/decode signpost 在 success/failure/cancel 下闭合，无 begin 时不得制造孤立 end
DIAG-PT-009      production 采样按 correlation 一致且不改变请求身份、调度或结果
DIAG-PT-013      诊断构造/解码重施 schema、摘要、数值、单位、协议候选与隐私边界
IMG-PT-011      supplied probe 与 bitstream 不一致时拒绝
RES-PT-001      fetch/decode 实际并发不超过 0a 静态 hard cap
RES-PT-002      取消等待 permit 不启动阶段且不泄漏 permit
AUTH-PT-010     public URL 不需要 auth provider/credential generation
AUTH-PT-011     revoke 清理后晚到 304 refresh 不得恢复旧 metadata
AUTH-PT-012     自定义 credential header 的 identity、fail-closed 与 redirect 剥离
AUTH-PT-013     credential refresh 保留全部非凭证请求语义
AUTH-PT-014     Profile ACL 在缓存/网络前精确拒绝
AUTH-PT-018     cancelled caller cannot consume remembered credentials or replay authenticated network work
AUTH-PT-019     namespace requests remain fail-closed until every concurrent revoke cleanup lease finishes
AUTH-PT-020     revoke generation 在 cleanup 前耐崩溃持久化，重启后旧代不得复活
CACHE-PT-031    ContentID 不得作为物理文件名
CACHE-PT-038    revoke 后新 200 写入当前 generation，冷内存后仍可 fresh hit
CACHE-PT-039    同 variant 的 200/304 覆盖取消时恢复旧 record，revoke 后不得复活旧 generation
CACHE-PT-040    representation base-key/reference indexes remain consistent after replacement, removal, and reopen
CACHE-PT-041    staged OriginalEncoded 在显式 publish 前不可读；discard/GC/revoke 不得泄漏或误删在途 stage
CACHE-PT-042    完整目标像素 preview 可先于 durable final 可见，但 final 必须等待 blob/record 原子发布
CACHE-PT-043    自定义 RenderedImageCaching 接管派生像素插入、命中和 purge
GC-PT-005       PhysicalBlobID 不泄漏 ContentID
GC-PT-011       0a soft cap 触发保守清理且不阻塞 final
SEC-CASE-001    delegate 分块流受 hard limit 与逐块背压约束
SEC-CASE-003    0a 静态路径拒绝多帧输入
SEC-CASE-014    认证响应只写入专属 namespace
SEC-CASE-015    相同 ContentID 跨 namespace 不共享物理 blob
SEC-CASE-016    登出撤销任务并清除 record/blob，晚到 commit 不复活
SEC-CASE-017    跨 origin redirect 剥离 Authorization/Cookie/API key
SEC-CASE-018    diagnostics 不含 token、Cookie 或稳定账户标识
SEC-CASE-029    持久 metadata 不含明文 namespace
SEC-CASE-039    NetworkLab redacts custom destinations and permits redirects only to explicit exact origins
SEC-CASE-040    repository sensitive-material gate rejects high-confidence secrets and private developer artifacts
SEC-CASE-041    remote Swift packages and external GitHub Actions require an explicit allowlist; Actions use full commit SHAs
SEC-CASE-042    request/response/Vary/persistent HTTP metadata is canonical, bounded, and rejects control-character injection
SEC-CASE-043    every executable or package target declares exactly the required privacy-manifest API categories and reviewed reasons
SEC-CASE-044    bundled media and regenerated downloads contain no EXIF, XMP, IPTC, PNG text metadata, or malformed image containers
SEC-CASE-045    the Release Workbench app contains its root privacy manifest but no UI-test routes, test tokens, or test plug-ins
HTTP-CONF-LOCAL-AGE-001...003  Date/Age corrected age 与畸形 Age 保守处理
HTTP-CONF-LOCAL-AGE-004  fetch permit 排队时间不计入 HTTP response delay
HTTP-CONF-LOCAL-NOCACHE-001  no-cache 覆盖正 max-age
```

0a-bootstrap 报告列出当时已执行项；0a-complete 报告必须列出全部产品 ID、结果、实现测试路径和 verified commit。

AI 主导实现分两级：

```text
0a-bootstrap（最多前 1–3 个 PR）
  AIQA-GATE-001...006
  AIQA-GATE-008
  AIQA-GATE-010
  AIQA-GATE-007/009 可 scaffolded，不得伪报 pass

0a-complete
  AIQA-GATE-001...011
  AIQA-MUT-001       namespace 不得从持久/请求身份消失
  AIQA-MUT-002       精确 fetch 不得错误按 FetchVariantKey 合并
  AIQA-MUT-007       no-store 不得进入 reusable cache
  AIQA-MUT-008       revoke 后不得 Commit
  AIQA-MUT-009       unknown target 不得原尺寸 decode
  AIQA-MUT-015       Probe reject 后不得发布 OriginalEncoded
  AIQA-MUT-017       post-revoke 200 不得写入旧 namespace generation
  AIQA-MUT-018       late 304 refresh 不得跨 revoke 恢复 metadata
```

只有 `0a-complete` 才算 Phase 0a 通过。定义与执行规则见 `specifications/ai-development-assurance.md`。

Phase 0a curated mutant 的可执行入口为 `scripts/run-critical-mutants.py`；报告 schema 为 `schemas/critical-mutation-report.schema.json`。回滚门入口为 `scripts/verify-rollback.py`，CI Evidence Bundle 由 `scripts/generate-ci-evidence.py` 生成。

## 3. Phase 0b / G0

0b 只要求与存在性门禁直接相关的测试，不把后续能力重新塞回首个正式门禁。

### 0b required

```text
KEY-GV-001
CACHE-PT-001...010
CACHE-PT-013...015
CACHE-PT-017...019
CACHE-PT-021
CACHE-PT-023
CACHE-PT-025...031
CACHE-PT-038
AUTH-PT-001...010
SCHED-PT-001...010
RES-PT-001...002
RES-PT-008
RES-PT-011...014
GEO-PT-001...008
UI-PT-001...024
ERR-PT-001...014
PIPE-PT-001...010
IMG-PT-001...003
IMG-PT-011
IMG-PT-006...008
CODEC-PT-001...008
CODEC-PT-010...011
CACHE-PT-043
```

此外：

- Private Image Cache Profile 中分类为 `required` 的 `HTTP-CONF-*` 全部通过；
- 安全矩阵中 Gate 为 `0a` 或 `0b` 的 `SEC-CASE-*` 全部通过；
- W1/W2/W3 对应的 benchmark/assertion 全部通过；
- `AIQA-GATE-001...015`、当前 curated critical mutation 集合 全部通过，并有 R3 独立 oracle/evidence；
- `DEMO-PT-001...009` 与当前 Workbench `DEMO-PT-021...035` 覆盖外部多 origin HTTPS 证据、带许可登记的真实图片画廊、生态专题、Gallery/Network Lab、确定性 loopback chaos、统一 App 运行时宿主、工程可重现和 iPhone/iPad UI 自动化；`VISUAL-PT-001` 另绑定双设备截图、几何与 Accessibility 三联件。`DEMO-PT-001` 在 0b/release 完成证据中 required，但不属于普通 PR 的确定性合并门。

### 不阻塞 0b

以下测试仍须保留，但在对应能力进入 Core v1/Phase 2 时才升级为门禁：

```text
CACHE-PT-011      206 Range 完整拼接
CACHE-PT-016      Analysis 模型/revision 失效
CACHE-PT-020      多 record blob 引用回收
CACHE-PT-022      non-identity Content-Encoding Range
CACHE-PT-024      multi-process writer fail-closed
CACHE-PT-032...035 quota/lease/atime/GC degradation
SCHED-PT-011...012 permit/fairness
RES-PT-003...007/009...010  namespace 公平、动态 pressure 与后台治理
GC-PT-*           完整 quota/GC
DIAG-PT-006...008/010  reader 兼容、reason 稳定、trace 重建与 retention/upload 契约
IMG-PT-004...005  HDR tone-map / gain-map
IMG-PT-009...010  HDR fallback 与跨系统扩展验证
```

推迟门禁不等于删除测试；它只防止未进入当前产品范围的能力阻塞 0b。

## 4. 外部测试 ID

外部 corpus 的稳定 ID 不直接复用 upstream 文件路径。manifest 使用：

```text
HTTP-CONF-RFC9111-<section>-<sequence>
HTTP-CONF-WPT-<upstream-test-id>
HTTP-CONF-CACHE-TESTS-<upstream-test-id>
```

manifest 还必须记录 upstream commit、license、适用性分类、预期结果和 adaptation notes。

## 5. 维护规则

- 不能通过重排文档列表改变测试 ID；
- 修复测试实现但语义不变时保留 ID；
- 扩大或改变断言语义时创建新 ID；
- 删除测试必须通过 ADR，并在毕业矩阵中说明替代项；
- 一个测试可以覆盖多个 ID，但报告必须逐 ID 给出结果；
- 一个 ID 可以在 unit/property/integration/fuzz 多层实现，最终结果取最严格门禁。

AIQA-MUT-018    304 metadata refresh ignores the post-write namespace generation fence
AIQA-MUT-019    namespace revocation leaves an already-published representation record behind
AIQA-MUT-020    transient target geometry is admitted into RenderedMemory
AIQA-MUT-021    encoded metadata byte limits are disabled
AIQA-MUT-022    each subscriber receives an isolated DecodeKey registry
AIQA-MUT-023    cancelled same-variant 304 refresh deletes metadata instead of restoring the old snapshot
AIQA-MUT-024    memory-cache cost accounting can overflow before eviction
AIQA-MUT-025    semantically corrupt OriginalEncoded manifests are accepted
AIQA-MUT-026    semantically corrupt representation manifests are accepted
AIQA-MUT-027    invalid runtime representation records are accepted
AIQA-MUT-028    malformed or conflicting Content-Length values are ignored
AIQA-MUT-029    noncanonical runtime ContentID strings are accepted
AIQA-MUT-030    hard-linked managed files or lock inodes are accepted
AIQA-MUT-031    symbolic links are accepted as managed directories
AIQA-MUT-032    metadata files are allocated before enforcing the st_size bound
AIQA-MUT-033    finite records are rejected when the wall clock moves backward
AIQA-MUT-034    request network permissions disappear from exact execution identity
AIQA-MUT-035    Profile ACL is bypassed before cache and network access
AIQA-MUT-036    credential refresh resets non-credential request semantics
AIQA-MUT-037    decode working-set reservation is replaced with a one-byte permit
AIQA-MUT-038    URLSession transaction metrics are dropped before completion
AIQA-MUT-039    decode-count permit is held while waiting for working-set capacity
AIQA-MUT-040    remote cleartext HTTP is accepted as a normal image source
AIQA-MUT-041    HTTPS redirect is allowed to downgrade to remote cleartext HTTP
AIQA-MUT-042    decode working-set budget disappears from the full configuration fingerprint
AIQA-MUT-043    official system composition defaults to unrestricted profile access
AIQA-MUT-044    completed shared-task result is published before registry cleanup
AIQA-MUT-045    retry-backoff cancellation omits the correlated terminal event
AIQA-MUT-046    ambient URLSession credential storage is preserved
AIQA-MUT-047    zero-subscriber shared task survives beyond its handoff lease
AIQA-MUT-048    strict proxy metrics policy accepts unverifiable/proxied traffic
AIQA-MUT-049    namespace identity byte bound is removed
AIQA-MUT-050    namespace generation wraps from UInt64.max to zero
AIQA-MUT-051    initial URLSession task bypasses destination policy
AIQA-MUT-052    redirect bypasses exact origin allowlist
AIQA-MUT-053    cache access bypasses destination policy
AIQA-MUT-054    transport identity omits destination policy fingerprint
AIQA-MUT-055    namespace registry admits new identities after capacity is exhausted
AIQA-MUT-056    persistent registry strongly retains store actors and writer leases
AIQA-MUT-057    high-cardinality cancellation instrumentation is enabled by default
AIQA-MUT-058    active signpost limits are applied per stage instead of globally
AIQA-MUT-059    remembered credential scopes are not evicted at the configured capacity
AIQA-MUT-060    redirect metrics are dropped before structured diagnostics
AIQA-MUT-061    transient blob I/O failures are treated as corrupt cache content
AIQA-MUT-062    expired weak registry entries accumulate for every cache root
AIQA-MUT-063    cancelled caller bypasses credential refresh and replay cancellation gates
AIQA-MUT-064    namespace work bypasses the active revoke cleanup barrier
AIQA-MUT-065    memory-pressure monitor dies with the transient system wrapper
AIQA-MUT-066    diagnostic reason accepts free-form text
AIQA-MUT-067    memory purge reports item count as released bytes
AIQA-MUT-068    unknown serialized diagnostic schema is accepted
AIQA-MUT-069    dropped diagnostic event count is reported as bytes
AIQA-MUT-070    public PipelineFailure accepts free-form or secret-bearing reason text
AIQA-MUT-071    response-header count bound is removed
AIQA-MUT-072    oversized persistent HTTP validator metadata is accepted
AIQA-MUT-073    representation replacement leaves stale base-key/reference indexes
AIQA-MUT-074    SwiftUI retry token is ignored for the same display identity
AIQA-MUT-075    SwiftUI phase rendering forces fill and loses fit geometry
AIQA-MUT-076    missing redirect route widens to secure-default destination policy
AIQA-MUT-077    public transport response trusts claimed received-byte metrics
AIQA-MUT-078    pipeline trusts a custom transport to enforce the body hard cap
AIQA-MUT-079    transform result bypasses output-surface and working-set admission
AIQA-MUT-080    runtime GC skips orphan cleanup when the manifest has no victims
AIQA-MUT-081    permit queue sequence wraps instead of rebasing the bounded waiter set
AIQA-MUT-082    reusable transport context accepts unbounded or control-bearing identifiers
AIQA-MUT-083    transport request accepts invalid or case-colliding credential header names
AIQA-MUT-084    transport response accepts an unsafe final URL
AIQA-MUT-085    HTTP delta-seconds accepts fractional or scientific notation
AIQA-MUT-086    conflicting duplicate max-age directives are resolved by first value
AIQA-MUT-087    no-cache or must-revalidate representation is served through stale fallback
AIQA-MUT-088    encoded-cache cancellation is treated as corruption and deletes valid metadata
AIQA-MUT-089    custom representation store bypasses namespace validation
AIQA-MUT-090    conflicting duplicate variant records are selected by array order
AIQA-MUT-091    custom decoder probe bypasses runtime decode limits
AIQA-MUT-092    retry scheduler failure is misclassified as user cancellation
AIQA-MUT-093    detached orphan work survives shared registry destruction
AIQA-MUT-094    active OSLog interval sequence wraps instead of rebasing
AIQA-MUT-095    staging cleanup deletes another active same-process transport directory
AIQA-MUT-096    unmeasurable ImageIO properties count as zero metadata bytes
AIQA-MUT-097    namespace revoke leaves remembered refreshed credentials alive
AIQA-MUT-098    orphan blob cleanup reports zero reclaimed files and bytes
AIQA-MUT-099    garbage collection accepts a noncanonical live-content reference


COMP-PT-001       comparator identities require exact 40-character commits
COMP-PT-002       dirty Fovea builds require a source-tree digest and explicit dirty marker
COMP-PT-003       beta-device artifacts remain provisional and exclude URL/UDID/device-name identity
COMP-PT-004       comparator observations use dense deterministic sequence numbers
COMP-PT-005       phase entry and device capture preserve the single-device/beta boundary and redact unique identifiers
COMP-PT-006       comparator versions, dataset selection, repetitions, order, primary metrics, and statistics are preregistered before results
COMP-PT-007       Fovea, Nuke, and Kingfisher adapters bind the common contract and build independently on macOS and iOS Simulator
COMP-PT-008       comparator requests make security namespace and bounded normalized headers explicit in shared identity and transport semantics
COMP-PT-009       the W1 fixture capture is immutable unless explicitly refreshed, resumable, hash-bound, dimension-validated, and strips image metadata
COMP-PT-010       three independent iOS benchmark apps use one shared workload/origin contract and the physical-device runner rejects identifier, URL, and credential leakage
COMP-PT-011       comparative workloads bind equal transport, cache-state, target-pixel, and security semantics before ranking
COMP-PT-012       app resources preserve hash-bound target-pixel fixtures without Xcode image rewriting
COMP-PT-013       W2 executes real EXIF-orientation, sRGB-reference, and target-pixel correctness probes outside timed sampling
COMP-PT-014       five isolated comparator apps emit schema-2 envelopes bound to Fovea commit, source-tree digest, and dirty state
COMP-PT-015       original upstream image-loader tests remain separately executable and every failure or exclusion is classified
COMP-PT-016       cross-language and cache projects contribute traceable challenges without replacing their native tests
COMP-PT-017       comparison ontology, source eligibility, semantic profiles, durability levels, and claim states are machine-gated
COMP-PT-018       Cache Lab stratifies native D1 and wrapper D5 disk semantics, preserves descriptive native metrics, and requires TOST/Holm decisions

DEMO-PT-001       0b/release four-origin HTTPS evidence emits commit/tree-bound metrics and invariant report; excluded from deterministic PR gate
DEMO-PT-002       Gallery and Network Lab build; Network Lab refuses implicit networking
DEMO-PT-003       loopback origin validates 304/no-store/redirect/slow single-flight without public network
DEMO-PT-004       loopback chaos matrix validates missing MIME plus expected HTML/body-limit/401/insecure-redirect failures
DEMO-PT-005       FoveaWorkbench uses iOS 15, reproducible XcodeGen, stable scenario/Lab IDs, interactive real-network defaults, deterministic UI-test defaults, and a >=400 remote / >=16 bundled licensed-and-ethically-reviewed media catalog
DEMO-PT-006       FoveaWorkbench deterministic origin traverses production cache/304/Vary/auth/single-flight/failure paths
DEMO-PT-007       FoveaWorkbench startup is nonblank, exposes the real-scenario studio and controls, while UI automation remains deterministic
DEMO-PT-008       FoveaWorkbench custom URLs are session-only and never persisted to UserDefaults
DEMO-PT-009       FoveaWorkbench UI matrix covers Expected/Actual evidence, 11 product scenarios, hundreds-of-assets Feed, stable failure reasons, memory/disk reentry, repeated-asset sharing and cancellation
DEMO-PT-021       ecological atlas current schema contains exactly eight volumes, 32 stories, 160 unique media identities, complete source closure, and all eight layouts
DEMO-PT-022       ecological atlas separates empirical evidence, theory, contestation, synthesis, and explicit normative claims
DEMO-PT-023       launch presents the ecological atlas and opens a real editorial story before engineering validation surfaces
DEMO-PT-024       library, cases, systems map, glossary, and methodology are all reachable from the public narrative entry; release verification executes the five-card navigation proof on regular-width iPad
DEMO-PT-025       search opens independent editorial, mosaic, timeline, comparison, atlas, dossier, field-notes, and immersive media surfaces
DEMO-PT-026       a story exercises fit/fill, full image reconstruction, memory purge/reload, and an explicit image-load contract
DEMO-PT-027       ecological atlas remains usable in an iPad compact window rather than assuming physical-screen width
DEMO-PT-028       every one of the 32 ecological stories launches directly, builds its declared media surface, and exposes exactly five resolved media identities
DEMO-PT-029       obsolete prefetch completions cannot remove replacement tasks after reset
DEMO-PT-030       prefetch completion identity includes both target width and height rather than width alone
DEMO-PT-031       shareable evidence removes stable generation IDs, run/performance UUIDs, exact times, locale, timezone, and device-model fingerprints
DEMO-PT-032       storage-profile maintenance runs off-main, prunes only eligible directories, and never follows symbolic links
DEMO-PT-033       storage-profile maintenance treats absent roots as an empty state rather than an error
DEMO-PT-034       pipeline rebuild cancels and joins every evidence runtime before publishing the replacement pipeline
DEMO-PT-035       normal, direct-story, and direct-studio routes share one app-level runtime host and report ready before maintenance actions
DEMO-PT-036       iPad Feed waits for localized fast-script completion and memory-footprint evidence before proving UIKit host and final-cell reachability
VISUAL-PT-001     iPhone/iPad each export seven screenshot, geometry, and accessibility checkpoints for oracle 1.2.0 review
AIQA-GATE-015     iOS example verification reproduces PBX/scheme/workspace, rejects project drift, and runs the strict dual-device visual gate

DOCS-PT-001       DocC builds every production module; all public types and at least 50% of source-authored public symbols are documented
DOCS-PT-002       source-authored public symbols cannot exceed the reviewed total and per-module API budgets

RES-PT-018       namespace registry 超限时在网络前失败关闭，并保留已跟踪撤销状态
RES-PT-019       memory-pressure monitor 跟随 pipeline 生命周期；清理遥测区分条目与字节
RES-PT-020       staging maintenance lock acquisition is cancellation-aware and reaches a bounded timeout under a foreign process lock

MATH-PT-001       production module graph is acyclic, imports are declared, fan-out is bounded, and graph metrics are emitted
MATH-PT-002       bounded cache transaction state model preserves generation/record/blob/render invariants and kills all embedded faulty models
MATH-PT-003       the finite cache-decision domain executes all 128 combinations and supplies MC/DC witnesses for every decision condition
MATH-PT-004       finite cache traces compare online policies against an exact offline optimum and report regret without claiming universal optimality
SCHED-PT-018      equal-priority permit waiters use smaller work estimates first while equal estimates remain FIFO
SCHED-PT-019      after eight ordinary bypasses, unit-weight waiters enter a FIFO starvation cohort that blocks nonstarved work
SCHED-PT-020      weighted starved waiters reserve future capacity, drain fragments, and cannot be bypassed by later fast-path arrivals
SCHED-PT-021      a cancelled zero-subscriber shared task retains a bounded non-revivable tombstone; late subscribers cannot restart the operation before lease expiry
SCHED-PT-022      cancellation tombstones distinguish pre-cancellation admissions from truly fresh callers; surviving pre-existing cohorts share one bounded replacement operation while fresh callers cannot revive the cancelled task
STYLE-PT-001      repository Swift formatting is fixed to four-space indentation and enforced by the strict gate
STYLE-PT-002      comment governance rejects English-only comments and preserves useful rationale without requiring line-by-line narration
MATH-PT-006       Workbench prefetch uses a bounded empirical distribution with DKW–Massart risk adjustment and respects monotonicity, sample, and hard-window limits
MATH-PT-007       SIEVE hit bits protect recurrent hot objects while sequential scans are admitted and evicted without hit-path list mutation
MATH-PT-008       seeded state-machine differential testing keeps production SIEVE equal to an independent array/clock reference model
MATH-PT-009       target geometry accepts only the current schema and rejects obsolete or malformed persisted policies
MATH-PT-010       hybrid linear/geometric target quantization never undersamples, bounds relative pixel inflation, and reduces decode identities
MATH-PT-011       bounded single-flight history model covers active, orphan-handoff, and cancellation-tombstone states and kills all six minimal ABA mutants
MATH-PT-012       retry full jitter spans the complete backoff interval and never undercuts a bounded Retry-After requirement
MATH-PT-013       exact timer-bin occupancy and seeded simulation show full jitter reduces peak synchronization and pair collisions
MATH-PT-014       exact-rational DRF progressive filling is capacity-feasible, satisfies the sharing floor, and resists finite demand misreports
MATH-PT-015       every mathematical theory record declares sources, assumptions, falsifiers, decision status, implementation paths, and claim limits
MATH-PT-016       comparison governance validates semantic equivalence, durability levels, source eligibility, and preregistered decision margins
MATH-PT-017       S3-FIFO and cost/size-aware TinyLFU candidates remain below an exact finite oracle and preserve counterexamples that block premature production adoption
MATH-PT-018       hierarchical claim families use oriented loss, L1-L4 gatekeeping, scoped digests, and forbid unbounded world-best claims
MATH-PT-019       block-resampled ECDF violation, Wasserstein-1, and p50/p95/p99 diagnostics reject crossing distributions as stochastic dominance
MATH-PT-020       finite delayed-hit DP finds an exact aggregate-delay optimum and a counterexample to hit-rate-oriented Belady-like eviction
MATH-PT-021       formal physical blocks require nominal thermal state, bounded warmup diagnostics, and whole-block reruns after thermal drift
COMP-PT-019       comparative and cache plans bind immutable statistical claim-family membership; artifacts without the family digest remain descriptive
COMP-PT-020       W7 V7 fixes exactly 1,000 logical requests, a common eight-slot service curve/client budget, direct cancellation and starvation probes, an internal eight-grant fairness bound, the derived fifteen-start black-box origin bound, absolute peak threads, six A-tier headless comparators, B-tier isolation, and versioned preregistration before formal evidence
COMP-PT-021       platform comparators bind Xcode build, OS build, and device profile rather than fabricating a Git commit
COMP-PT-022       incomplete platform-build identities are rejected and cannot fall back to unknown or zero-commit evidence
COMP-PT-023       the accepted A-tier matrix is exactly Apple Native, Apple AsyncImage, Nuke, Kingfisher, SDWebImage, PINRemoteImage, and Fovea; AlamofireImage remains B-tier and cannot satisfy an A-tier slot
COMP-PT-024       Apple AsyncImage and FoveaResponsiveImage run as paired SwiftUI targets against the same loopback origin, traces, sampling, applicability contract, and common-endpoint claim families; W3 and W7 remain explicitly not comparable for AsyncImage
COMP-PT-025       PINRemoteImage is exact-commit locked, adapter/app integrated, and its original iOS workspace tests are executed unmodified apart from a declared deployment-target compatibility override; native failures remain visible

MEM-PT-001       user-provided discussion sources are digest-bound; active decisions, standing requirements, capability gaps, and unresolved obligations are machine-validated without treating conversation summaries as authoritative
MEM-PT-002       the accepted workload catalog remains gap-free W1-W15 with exact names/purposes, explicit capability gaps, current W1-W3 subset boundaries, and Adaptive Representation preserved only as adjunct X1
MEM-PT-003       every multi-step task has a mandatory repository-backed session bootstrap that renders active decisions, workload status, negative results, blockers, and open obligations; local verify and CI enforce the continuity gate
