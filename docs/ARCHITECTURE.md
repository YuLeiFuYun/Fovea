# Fovea 图片加载系统架构

> **状态：Proposed（唯一工作架构文档）**  
> 本文是当前唯一的架构入口。只有经过可运行原型、自动化正确性测试和真机基准验证的局部决策，才可在对应 ADR 中标记为 `Accepted`。整份蓝图在 Phase 0b 完成前不称“定稿”。
>
> **规范优先级：** Accepted ADR 决定其范围内的决策；`specifications/` 决定可执行语义；本文决定系统边界、产品范围和阶段门禁。发现直接冲突时必须停止实现并修正文档，不能由实现者静默择一。
>
> **平台基线：** iOS/iPadOS 15、macOS 12、watchOS 8、tvOS 15、visionOS 1。  
> **语言：** Swift 6 严格并发；Phase 0a 同时启用 Swift 6.2 `NonisolatedNonsendingByDefault` 与 `InferIsolatedConformances`。
> **执行模型：** UI adapter 为 `@MainActor`；加载入口与共享 operation 显式 `@concurrent`；阻塞磁盘 I/O 使用专用串行 executor；核心通过 `ImageDecoding`/`WallClock` 等协议注入平台实现与可控时间。
> **产品边界：** Apple 平台静态图、动图及其按需辅助平面；不扩张为视频播放器、生成式图片平台或通用网络框架。

---

## 1. Fovea 为什么值得存在

Nuke、Kingfisher、SDWebImage 等项目已经具备成熟的管线、缓存、任务合并、取消、渐进式加载和 UI 集成。Fovea 不能把这些入场能力包装成“代际优势”。

Fovea 的存在价值必须由更小、可验证的契约证明：

1. **身份与 HTTP 正确性**：请求变体、响应记录、内容摘要、解码结果和渲染结果严格分离；正确处理 freshness、validator、`Vary`、认证响应、`private`、`no-store`、304 与 Range。
2. **安全域正确性**：认证资源按 namespace 隔离；退出登录可完整清理；默认禁止跨 namespace 内容去重。
3. **目标像素正确性**：默认路径不产生不需要的像素；大图缩略不先生成全尺寸位图。
4. **取消和生命周期正确性**：取消后的下载字节、解码和处理浪费可以测量，并在 UI 复用和滚动场景中保持低水平。
5. **默认安全**：像素、帧数、元数据和递归限制在大内存分配前生效；畸形输入有可测试的拒绝行为。
6. **可证伪性能**：任何性能宣称都绑定固定 workload、设备、缓存状态、指标和原始 trace。
7. **前沿技术可工程化但不绑架核心**：新 codec、可信媒体、HDR、空间图、模型增强和学习策略通过最小 capability slot 接入；没有数据就不升级为稳定承诺。

Fovea 必须通过 Phase 0b 的存在性门禁后才能扩大公共 API。门禁允许两条受约束路径：Performance Path 证明性能净收益；Correctness Path 证明关键 HTTP/安全/目标像素契约及性能 non-inferiority。后者不得宣传“性能领先”。具体规则见 `docs/specifications/benchmark-workloads.md` 与 `docs/COMPETITIVE_CONTRACTS.md`。

---

## 2. 文档与决策治理

### 2.1 单一权威来源

- `docs/ARCHITECTURE.md`：唯一工作架构。
- `docs/archive/`：历史版本，只用于追溯，不指导实现。
- `docs/adr/`：局部决策及其证据。
- `docs/specifications/`：可执行规范，包括缓存/身份语义、HTTP 一致性、调度、并发所有权、资源预算、错误恢复、诊断、表示正确性、基准、安全默认、UI 状态机和平台配置。
- `docs/TECHNOLOGY_RADAR.md`：前沿技术跟踪，不构成产品承诺。
- `docs/COMPETITIVE_CONTRACTS.md`：只记录经来源或 Phase 0b 适配器验证的竞品能力与 Fovea 验收契约。
- `docs/research/`：专题研究与证据综述，不直接形成产品承诺；决策必须进入 ADR/规格。

决策状态：

```text
Proposed      方向成立，尚未通过实现验证
Accepted      已有实现、测试、真机数据与兼容承诺
Experimental  可运行但 API 可破坏，默认关闭
Deferred      有价值但当前证据不足
Rejected      已明确否决并记录原因
Superseded    被后续决策替代
```

### 2.2 不按日历划分技术

不使用“未来五年”作为技术优先级。AI 可以显著压缩调研、原型、测试和文档周期，因此多个前沿方向可以立即并行验证。

但实现速度不等于协议成熟度。技术是否进入稳定核心，取决于：

- 平台和标准可用性；
- 对核心的侵入性；
- 真机净收益；
- 安全和隐私边界；
- 确定性回退；
- API 稳定成本；
- 长期维护责任。

### 2.3 实现驱动的文档冻结

从 ADR-0008 生效到 Phase 0a 完成，功能型设计文档进入冻结期：

- 只接受实现 blocker、规范矛盾、安全缺口和 API 命名修正；
- 不新增未被 0a 代码触发的大型 capability 规格；
- 新 capability slot 必须提交 ADR，并证明现有接缝无法表达；
- 0a PR 不受 FoveaLab、完整外部 corpus 或 Phase 0b 性能门阻塞；
- 设计争议优先通过最小原型、失败测试和 trace 裁决；
- 新建文档或新增大章节默认拒绝，除非附带失败测试 ID、0a blocker 日志/trace，或明确安全事件。

### 2.4 AI 主导实现的质量保障

Fovea 预计大量代码由 AI 编程智能体实现。项目不把 AI 代码视为天然低质，也不接受“模型更强/测试通过”作为充分证明。变更按影响面分为 R0–R4，合并由独立、可重复、受保护的证据决定：

```text
Specification / invariant
        ↓
AI or human implementation
        ↓
independent oracle + trusted CI + accountable human
```

关键规则：

- 实现 agent 不得单方面修改 required gate、hidden tests、branch protection 或发布控制；
- R2/R3 必须有 human accountable maintainer，AI review 不能替代人类理解签署；
- identity、HTTP、auth、persistence、concurrency、security、build/release 属于 R3；
- agent 使用临时隔离环境、最小权限、网络/工具 allowlist，不持有生产秘密或签名权限；
- 所有 AI-assisted PR 提交可审计 Evidence Bundle；
- 模型升级只改变通过率，不降低产品 gate；
- Stable 的 R3 契约需要 human two-party review 或外部审计。

详见 ADR-0009、`docs/specifications/ai-development-assurance.md` 与 2026 专题研究。AIQA 在 0a 内分为 bootstrap 与 complete：前 1–3 个 PR 先建立最小可信合并轨道，完整 mutant/rollback 门禁在宣布 0a 完成前补齐。该治理属于实现质量控制，不解除功能型文档冻结。

---

## 3. 交付门禁与成熟度分层

“Phase”描述当前工程门禁；“成熟度”描述产品承诺。两者不可混用。

### 3.1 Phase 0a：Runnable Slice

0a 的唯一允许实现面由 `docs/specifications/phase-0a-surface.md` 规定。任何超出符号预算的抽象或产品必须提供 blocker evidence 并经 ADR 批准。

0a 只证明最小垂直切片可运行、可替换、可观测，不形成长期兼容或性能领先承诺：

```text
URL
→ FetchVariantKey record lookup / FetchExecutionKey single-flight
→ bounded Transport + spill/hash
→ OriginalEncoded 单进程原子提交
→ ImageIO target-size decode
→ RenderedMemory
→ 一个 UI surface
```

0a 必须具备：

- 基础 key/canonical encoding 与 golden vectors；
- `fresh`、304、`no-store`、namespace 基本隔离；
- 最关键的 request token、取消和 revoked-generation Commit 测试；
- 一个可运行的 W1/W2 harness 骨架，但不要求达到性能门限；
- 最小诊断事件和 deterministic clock；
- AIQA bootstrap：前 1–3 个 PR 建立隔离 agent、基础 Evidence Bundle、clean trusted CI、protected gates、依赖默认拒绝和 accountable owner；
- AIQA complete：宣布 0a 完成前，`AIQA-GATE-001...010` 与指定关键 mutants 全部真实执行通过。

0a-bootstrap 可以合并产品和治理脚手架，但不等于 Phase 0a 通过。0a 不要求完整外部 HTTP corpus、全量 StoreGeneration crash matrix、双设备复现、双竞品适配器全部完成或 15% 性能收益。

### 3.2 Phase 0b：Existence Gate

0b 决定 Fovea 是否值得进入 Core v1 Candidate。它包含：

- G0 全量协议、持久化、schema、priority 和 revoke 门禁；
- Private Image Cache Profile 的 required external corpus；
- W1/W2/W3 与预注册竞品 adapter；
- 最低性能档和当前主流设备复现；
- Performance Path 或 Correctness Path 至少一条通过；
- R3 完整独立 oracle、关键 mutant、agent eval 与供应链证据通过。

通过 0b 才意味着可以继续建设可发布的 Core v1 Candidate。完整判据见 `docs/specifications/benchmark-workloads.md` 与 ADR-0008。

### 3.3 Core v1 Candidate

Phase 0b 通过后才进入此层，目标是形成首个可发布候选：

- URL/File/Data/Asset source；
- 固定阶段管线与 single-flight；
- target-size static decode 与 orientation/color/alpha 基本正确性；
- OriginalEncoded 与 RenderedMemory；
- 版本化 Fovea Private Image Cache Profile：freshness、Age、validator、`Vary`、304 和核心认证语义；
- 取消、优先级和提交边界；
- DecodeLimits 与安全默认矩阵；
- UIKit、AppKit、SwiftUI；
- 可复现诊断与 canonical workloads。

Core v1 Candidate 仍可破坏 API。只有经过真实应用试用、至少一个兼容周期和 Accepted ADR 后，局部契约才能成为 Stable Core。

### 3.4 Stable Core

Stable Core 不是“计划实现的功能清单”，而是已经承担兼容承诺的最小集合。成为 Stable 必须同时满足：

- 已有生产实现和自动化测试；
- Phase 0b/Phase 1 对应门禁通过；
- 真机基准无未解释回归；
- 错误、取消和安全行为已经规范化；
- 至少一个版本周期内没有结构性返工；
- 对应 ADR 标记为 `Accepted`。

因此在当前阶段，Stable Core 可以为空；“安全、身份和 HTTP 必须进入未来 Stable Core”不等于它们现在已经 Stable。

### 3.5 Capability Slots

Core 只预留技术无关的最小接缝，不承诺具体实现：

- 多表示候选与 representation selection；
- codec capabilities；
- 可选辅助平面；
- 异步 enhancement processor；
- opaque provenance attachment；
- processor/model fingerprint；
- 资源需求提示；
- advisor 建议接口。

Capability slot 是架构接缝，不是产品成熟度。它不得迫使普通请求承担额外内存、依赖、线程或分支成本。

### 3.6 Experimental Modules

已有可运行实现，但默认关闭、API 可破坏：

- `FoveaPlaceholders`；
- `FoveaVisionCrop`；
- `FoveaTrust`；
- `FoveaAdaptive`；
- `FoveaRasterStoreExperimental`；
- ImageCraft 的重型 codec 插件；
- 端侧超分和重建处理。

### 3.7 Technology Radar / FoveaLab

论文复现、标准跟踪、模型和策略竞赛放在 FoveaLab。生产仓库不得依赖 FoveaLab。

FoveaLab 工作还必须满足：

- 不修改 Core 的公开协议，除非先提交独立 ADR；
- 不阻塞 Phase 0a/Core v1 PR；
- 不进入默认 product dependency graph；
- 不共享未经隔离的生产缓存 namespace；
- 实验失败时可整包删除。

### 3.8 与技术雷达的映射

| 架构/产品状态 | Technology Radar | 含义 |
|---|---|---|
| Stable Core / Accepted | Adopt | 已形成实现与兼容承诺 |
| Core v1 Candidate | Trial | 正在通过实现与门禁验证，尚无兼容承诺 |
| Experimental Module | Trial | 有实现，默认关闭，可破坏 |
| FoveaLab / Research | Assess | 研究、复现和原型，不构成产品承诺 |
| Rejected / 长期暂停 | Hold | 当前明确不采用 |
| Capability Slot | 不对应雷达环 | 只是无实现或实现可替换的最小接缝 |

不再使用 `Incubating` 作为独立状态，避免和 Trial/Experimental 重叠。

---

## 4. 项目边界与开发形态

长期发布边界仍是三个生产项目：

```text
ImageCraft   图像探测、编解码、处理、动画和辅助平面
Akashic      通用缓存与持久化机制
Fovea        来源、HTTP、加载调度、组合与 UI
```

但 Phase 0a 不立即建立三套独立发布节奏。采用统一 workspace、path dependency 或固定 commit pin 联调；公共契约稳定后再独立发版。这样保留长期边界，同时避免早期版本矩阵拖慢重构。

### 4.1 ImageCraft 目标边界

```text
ImageCraftCore
ImageCraftImageIO
ImageCraftProcessing
ImageCraftAnimation
ImageCraftAuxiliary
ImageCraftTesting

可选：ImageCraftAVIF / ImageCraftJXL / ImageCraftSVG / 实验 codec
```

它负责像素和容器语义，不知道 URL、HTTP、缓存实现和 UI 生命周期。

### 4.2 Akashic 目标边界

```text
AkashicCore
AkashicMemory
AkashicDisk
AkashicTraceKit
AkashicTesting
```

它缓存任意键值，不知道图片、URL、HTTP 或用户界面。成本由调用者传入或通过 `CostEstimator<Value>` 注入，不要求第三方类型遵循库私有协议。

### 4.3 Fovea 产品

```text
FoveaCore
FoveaSources
FoveaTransport
FoveaHTTP
FoveaUIKit
FoveaAppKit
FoveaSwiftUI
FoveaDiagnostics
FoveaTesting
Fovea
```

格式解码插件属于 ImageCraft，不以 `FoveaAVIF` 等名称倒置职责。

现实代码与目标边界的差距见 `docs/adr/0001-reality-gap.md`。

### 4.4 Pipeline 配置与注册

Pipeline 在构造后持有不可变配置快照。codec、processor、source loader、transport、store、clock、安全策略和 diagnostics 只在 composition root 注入并冻结。`Fovea.shared` 是默认 pipeline 的只读 façade，不提供运行时全局注册或修改默认 decoder 的 API。配置变化创建新的 pipeline/configuration generation，进行中的任务继续使用启动时快照。详见 `docs/specifications/pipeline-configuration.md` 与 ADR-0006。

---

## 5. 默认简单 API

架构复杂度不能转嫁给普通使用者。首先保证：

```swift
FoveaImage(
    url: url,
    accessibility: .label(Text("用户头像"))
)
```

SwiftUI façade 从稳定布局推导 target pixels；装饰图必须显式使用 `.decorative`，非 UI API 仍必须传入 target。

```swift
imageView.fovea.setImage(from: url)
```

```swift
let image = try await Fovea.shared.image(
    for: url,
    target: .pixels(width: 600, height: 400)
)
```

原始编码字节使用：

```swift
let data = try await Fovea.shared.encodedData(for: url)
```

高级请求才使用结构化配置：

```swift
let request = ImageRequest(
    source: .url(url),
    target: .init(points: view.bounds.size, scale: screenScale),
    contentMode: .fill,
    priority: .interactive,
    cachePolicy: .automatic
)
```

v1 的公共请求不强迫用户理解 trust、模型、八维预算或完整多表示 manifest。高级功能通过可选配置或独立模块启用。

### 5.1 默认行为必须明确

- URL 请求默认 GET；
- 公共 API 可以接受 points + scale，但在请求规范化时必须转换为整数 target pixels；
- DecodeKey、RenderKey 和所有解码预算只保存像素语义，不保存等价的 point 表达；
- 无 UI 的 decoded-image API 默认要求 target；原尺寸解码必须显式 opt-in；目标未知时最多解析 metadata/预取 encoded，不静默解码或缓存全尺寸结果；
- UI 复用会取消旧订阅；
- SwiftUI identity 改变会取消旧任务；
- placeholder、transition、错误和 retry 行为可预测；
- 默认不启用重建型增强和 trust 验证。

### 5.2 API 与发布治理

0.x 阶段允许破坏性重构；1.0 后遵守 SemVer，并把可观察行为、错误分类、默认缓存/安全语义纳入兼容承诺。Experimental product 不由稳定 umbrella 自动 re-export。SwiftPM、依赖、二进制体积、library evolution 与弃用规则见 `docs/specifications/api-release-policy.md`。

---

## 6. 身份与缓存键：唯一模型

废弃 V1 的 `RequestIdentity / ResourceIdentity` 模型。validator 与内容身份不可混合，`Vary` 也不能在首次请求前完整获知。

### 6.1 FetchVariantKey：请求前可计算

用于稳定 RepresentationRecord 候选选择，并作为 FetchExecutionKey 的语义基础：

```text
logical source identity
+ resolved locator
+ HTTP method
+ 请求前已知且会影响响应的字段
+ security namespace
+ request body digest（若支持）
```

CDN 重写、鉴权适配和 locator 解析必须在 FetchVariantKey 冻结前完成。认证材料本身不以明文进入 key；使用稳定、不可逆的 `AuthorizationContextID` 与 security namespace 表达主体和授权代际。应用集成、`AuthorizationContextProvider`、Cookie partition、credential generation 和 fail-closed 行为见 `docs/specifications/auth-context-integration.md`；键构造样例见 `docs/specifications/cache-semantics.md`。

### 6.2 FetchExecutionKey：执行前、仅内存

稳定缓存身份与一次精确网络执行不是同一概念。网络 single-flight 使用：

```text
FetchVariantKey
+ exact resolved locator fingerprint
+ credential/cookie generation fingerprint
+ cache/revalidation mode
+ range/validator execution state
+ transport-affecting policy fingerprint
```

它不持久化、不记录原始 token/Cookie/签名 query。签名 URL 或凭证刷新可以继续命中旧 record，但不会错误加入使用过期凭证的在途任务。

### 6.3 RepresentationRecord：响应后建立

它是记录，不是内容哈希：

```text
status、MIME、必要且允许持久化的响应 metadata
Vary 字段与原请求值
freshness metadata
ETag / Last-Modified
content digest
Range/partial state
隐私和 trust metadata locator
```

### 6.4 ContentID：实际字节身份

完整内容经摘要后得到 ContentID。相同内容可在一个安全域中跨 locator 复用。

**安全铁律：跨 security namespace 的 ContentID 去重默认关闭。** 即使字节摘要相同，也不得因共享 blob、访问时间或元数据造成账户侧信道或生命周期耦合。

### 6.5 DecodeKey

```text
ContentID
+ normalized DecodePlan
+ decoder fingerprint
+ requested auxiliary attachments
```

DecodePlan 包含实际输出像素范围、orientation、颜色/HDR 策略、静态/动画策略等。语义已经由 target pixels 完整表达时，不重复加入仅用于 UI 的 point scale，避免等价结果产生重复 key。

### 6.6 RenderKey

```text
DecodeKey
+ canonical TransformPlan
+ output pixel/color policy
+ processor fingerprints
+ enhancement fingerprint（若改变像素）
```

processor identity 必须是结构化、版本化、可规范化的值，不允许任意字符串拼接。

### 6.7 四种共享不可混淆

```text
FetchExecutionKey → 精确网络请求共享（仅内存）
ContentID         → 已获取字节去重
DecodeKey         → 解码结果共享
RenderKey         → 最终显示结果复用
```

FetchVariantKey 用于稳定 record 选择，不直接承担临时凭证和精确执行状态。持久 key 禁止使用 Swift `hashValue`/`Hasher`，必须采用版本化 canonical encoding；详见 `docs/specifications/cache-semantics.md` 与 ADR-0002/0004。

---

## 7. Source、Transport 与 HTTP

### 7.1 Source

Core 面向来源，而不是面向 URL：

```text
URLSource
FileSource
DataSource
AssetSource
PhotosSource（可选）
CustomSource
```

非网络来源不得伪装成 Transport。File/Data/Asset/Photos/Custom 的身份、revision 和失效规则见 `docs/specifications/source-identity.md`。

### 7.2 Transport

Transport 只搬运远程字节：

- 有界缓冲和背压；
- 响应头与 body 分离；
- 可取消；
- 提供进度与 metrics；
- 支持 Range 机制，但不自行决定恢复策略；
- 超过阈值自动 spill 到 staging file；
- 下载时可并行执行增量摘要、staging 写入和渐进 decoder 输入；
- 不要求把完整图片常驻为单一巨大 `Data`。

不建立通用 REST DSL、JSON 映射或 OAuth 框架。

### 7.3 Fovea Private Image Cache Profile

```text
无记录
  → 正常请求

记录新鲜
  → 直接使用，不访问网络

记录过期且有 validator
  → 条件请求

304
  → 更新 RepresentationRecord，复用原 ContentID

200
  → 创建新 record/blob

允许 stale-while-revalidate
  → 先交付旧内容，再后台重验证

允许 stale-if-error
  → 请求失败时按策略交付过期内容
```

Fovea 不宣称实现通用代理缓存。Core v1 只承诺版本化的 private image cache profile；对未支持的 method/status/directive 选择不持久化或回源，而不是猜测语义。Phase 0a 只实现 fresh、304、no-store 和 namespace 的最小内部路径；Phase 0b 才要求 GET、200/304、显式 freshness、Age、validator、Vary、auth/no-store 的 required profile corpus。206/If-Range 与 stale 扩展按 profile capability 推进。

必须覆盖：

- `Cache-Control`、`Expires`、`Age` 与可注入时钟；
- `no-cache` 与 `no-store` 的区别；
- `private`、认证响应和 private namespace 规则；shared proxy 语义不在 v1 profile；
- `Vary`、`Vary: *`；
- ETag、Last-Modified、304 metadata merge；
- 206、Content-Range、If-Range；
- 重定向跨 origin 时 Authorization 的处理；
- 与 `URLCache` 的边界，默认避免无法解释的双重缓存；
- content-decoding layer 与 Range 的兼容性；
- 专用图片缓存只持久化必要 header，禁止保存/回放 `Set-Cookie` 和认证字段。

Akashic 提供事务和存储；FoveaHTTP 拥有 HTTP 语义。热路径所有权固定如下：

| 决策或动作 | 唯一所有者 | 持久化位置 |
|---|---|---|
| 记录是否 fresh、是否允许 stale | FoveaHTTP | RepresentationRecord |
| 条件请求与 304 metadata merge | FoveaHTTP | RepresentationRecord |
| `Vary` 匹配与候选记录选择 | FoveaHTTP | RepresentationRecord 索引 |
| 是否允许落盘 | FoveaHTTP + SecurityPolicy | record flags |
| blob staging、摘要与原子提交 | Akashic 事务 API | OriginalEncoded |
| single-flight 注册与订阅 | FoveaCore，按 FetchExecutionKey | 仅内存任务表 |
| URLSession/URLCache 配置 | FoveaTransport/FoveaHTTP composition root | 不重复持久化 |

完整状态机、profile 范围和外部一致性语料见 `docs/specifications/cache-semantics.md` 与 `docs/specifications/http-cache-conformance.md`。WPT 测试是 Fetch/browser 视角，只移植适用序列并维护 provenance manifest；不得宣称无分析地“全量 WPT 兼容”。

---

## 8. v1 固定加载阶段

v1 不实现通用 DAG 运行时。内部可用依赖图解释共享关系，但执行阶段固定、数量受控：

```text
1. ResolveSource
2. SelectRepresentation     // 单候选时为 no-op
3. SelectCache
4. FetchOrRevalidate
5. AccumulateHashAndStage
6. Probe
7. DecodeAtTarget
8. Transform
9. Commit
10. Deliver
```

`SelectRepresentation` 是受控的固定插槽，不意味着引入通用 DAG。v1 只要求单候选 no-op 和简单 srcset；复杂 manifest/学习选择器仍属 Capability Slot 或 Experimental。`Commit` 表示一组受控 checkpoint：OriginalEncoded 可在完整字节和安全 Probe 通过后独立提交，Rendered/Derived 则等待对应结果完成；不能把“ContentID 已计算”误当成“图片 record 已可见”。

阶段编号表达依赖和所有权，不要求形成十个串行 barrier：Accumulate、增量 Probe、hash、staging write 与 progressive preview decode 可以有界重叠。最终图一旦通过安全/身份检查即可 Deliver；非关键 DerivedEncoded、Analysis、GC 或机会式 schema rewrite 不得阻塞 UI。RenderedMemory 插入可以在 Deliver 前完成，磁盘持久化按结构化后台任务执行并再次检查 namespace generation。

允许的公共 hook 仅限：

```text
SourceResolver
RequestAuthorizer
Transport
HTTPPolicy
CachePolicy
DecodePolicy
TransformPlanner
PipelineObserver
```

Observer 只能观察。任何影响 locator、字节或像素的扩展必须在对应 key 冻结前执行并提供 fingerprint。

### 8.1 Stage-level single-flight

- 相同 FetchExecutionKey 且执行约束兼容时共享网络获取；
- 相同 ContentID 可以共享探测；
- 相同 DecodeKey 共享解码；
- 相同 RenderKey 共享最终处理；
- 不同目标像素在解码阶段分叉；
- 相同解码、不同圆角在处理阶段分叉。

### 8.2 交付事件

v1 使用简单交付模型：

```text
placeholder
preview
final
```

`preview` 可来自低分辨率候选或 progressive decode。复杂 deadline-aware quality planning 先保留为实验能力，不进入 v1 通用调度器。

---

## 9. 取消、优先级与提交

### 9.1 默认取消

最后一个订阅者离开后，默认 `cancelImmediately`。

只有同时满足以下条件，才允许完成 encoded 数据并落盘：

- 无鉴权且属于公开资源；
- 响应允许缓存；
- 只完成 OriginalEncoded，不继续解码或处理；
- 剩余字节低于配置阈值；
- 非 Low Data Mode、非低电量、非资源压力；
- 记录明确原因码。

认证、`private`、`no-store` 内容不得在无人订阅后继续落盘。`no-store` 只允许同一在途 task cohort 的当前订阅者共享；任务完成后不得建立页面/屏幕会话级 reusable cache。UI 可以继续持有已经交付给当前 view token 的像素，但该持有不是缓存命中来源，identity 变化、view 释放或 namespace revoke 时必须清除。

### 9.2 优先级是三层概念

```text
Fovea scheduler priority  决定本地排队、预算和抢占
Swift TaskPriority        执行上下文提示
URLSessionTask.priority   网络栈提示
```

三者不可互相等同。共享任务的有效优先级始终等于当前 active subscribers 的最大优先级；订阅者加入、退出或取消时重算。可见订阅退出且只剩预取时必须降级，不能永久保留高优先级。完整规则与 property tests 见 `docs/specifications/scheduler-semantics.md`。

### 9.3 提交边界

- 完整 200 body 只有在传输结束、长度/完整性检查通过并完成摘要后才生成 ContentID；
- 206 range 仅保存为 `PartialTransferRecord`，必须绑定 FetchVariantKey、强 validator 和已覆盖 range；完整表示拼接并验证后才能生成 ContentID；
- 中断的 200 body 不得作为 OriginalEncoded 可见。只有具备安全恢复条件时才可留下隔离的 partial staging；
- ContentID 未确定前允许向当前订阅者交付 progressive preview，但只使用任务内 `EphemeralTransferID`，不得进入持久缓存或跨 fetch 复用；
- preview 不得写入最终 RenderKey；最终内容完成后才能提交可跨请求复用的 DecodeKey/RenderKey；
- RepresentationRecord 与 blob 引用原子提交；304 只更新 record，不重写 blob；
- 每个任务捕获 NamespaceGeneration，logout/revoke 后 Commit 再校验；旧 generation 的在途任务不得让已清理数据复活；
- 解码失败不污染 RenderedMemory；DerivedEncoded 半写文件不可见；
- 取消和崩溃后 staging 可回收。

更完整的 partial/Range/commit 规则见 `docs/specifications/cache-semantics.md`。

### 9.4 错误、重试与回退

错误必须区分终止失败、可重试失败、允许回退、缓存降级和取消。cache write、GC、Derived/Analysis 或 diagnostics 失败默认不能覆盖已经成功生成的 final。自动重试只服务幂等 GET 的明确瞬态错误，并受次数、deadline、额外字节、网络限制和 FetchExecutionKey 约束；stale、替代 decoder 和 representation fallback 必须按 subscriber policy 独立裁决。详见 `docs/specifications/error-recovery.md`。

---

## 10. 图像解码与处理

### 10.1 Target-pixel-first

首选 ImageIO 目标尺寸解码，不先解码全尺寸再 resize。目标尺寸必须以像素而非仅 points 表达。

### 10.2 DecodeLimits

在任何大分配前检查：

```text
encoded bytes
width / height
pixel count
frame count
metadata bytes
progressive scans
auxiliary attachments
nesting / recursion
allowed formats
```

### 10.3 TransformPlan

TransformPlan 是规范化、可哈希、可序列化的内部值类型，不是任意协议：

```text
source region
orientation
resize/content mode
output extent
color conversion
alpha operation
effects
schema version
```

Planner 导出 DecodePlan 与 RenderPlan，把 region、orientation 和 resize 尽可能下推到 decoder，避免中间位图。

### 10.4 后端选择

ImageIO、vImage、Core Graphics、Core Image 和 Metal 通过真机数据选择。Metal 不是默认答案。

row alignment 由目标后端和基准决定；不宣称固定 64 字节对齐即可保证 Core Animation 零拷贝。

Display preparation 是条件阶段。若结果已 eager decoded 且 display-ready，不重复调用平台 preparation API。

### 10.5 缓冲复用

ImageCraftProcessing 应评估临时像素缓冲池和可复用工作区，尤其是动画、连续 resize 和颜色转换。缓冲池的收益要与内存滞留、线程安全和 jetsam 风险一并测试；不能只研究磁盘 RasterStore。

### 10.6 图像表示正确性

Core 的真实表示不是 `UIImage`。`DecodedImage` 必须明确 pixel size、orientation state、颜色描述、dynamic range、alpha/pixel format、display readiness 和 lazy attachments。普通显示路径默认把 orientation 规范化为逻辑 `.up`；颜色/HDR/tone-map/attachment policy 参与 DecodeKey 或 RenderKey，不能在 P3/sRGB、HDR/SDR 间错误共享。详见 `docs/specifications/image-representation.md`。

### 10.7 动画图像

动画属于 Phase 2/Experimental，不阻塞 Phase 0a。它使用独立的 animation asset、frame cache 和 cost model，默认采用受控 decode window，不把所有帧无界解码进内存。frame timing、loop、disposal、可见性、后台和 Reduce Motion 策略见 `docs/specifications/animation-policy.md`。

---

## 11. 缓存：使用语义名，不使用乱序层号

```text
RenderedMemory       目标尺寸、处理完成的显示结果
MetadataMemory       格式、尺寸、颜色、validator 等轻量信息
OriginalEncoded      原始响应 blob + RepresentationRecord
DerivedEncoded       目标尺寸压缩衍生物，默认保守准入
Analysis             模型/Vision 分析结果，独立预算
RasterExperimental   未压缩热点 slab，默认关闭
```

### 11.1 内存策略

文档阶段不预定 S3-FIFO、SIEVE、TinyLFU、ARC 或 LRU 为赢家。

v1 必须先实现：

- byte-aware cost；
- 单对象 cost cap；
- oversize reject；
- memory pressure 清理；
- 可重复 trace；
- LRU 基线；
- 至少一种抗扫描候选（S3-FIFO 或 SIEVE）。

默认策略由 Feed Scroll 与真实应用 trace 决定。复杂多因子评分先放在 AkashicTraceKit 离线评估，不进入默认同步热路径。

初始准入采用可解释硬规则：

```text
entry cost > budget percentage  → reject
一次性大对象                  → reject from RenderedMemory
no-store                       → reject all reusable cache
不可见 speculative result      → conservative admission
```

### 11.2 DerivedEncoded

方向有价值，但写入默认关闭或极保守。只有满足以下条件才允许生成：

- sourcePixels / targetPixels 达到阈值；
- targetPixels 在上限内；
- 已有复用证据；
- ContentID 的变体数量未超限；
- 编码成本、磁盘预算和当前 thermal/IO 状态允许；
- HDR、色彩和辅助平面语义不会被错误丢弃；
- source 未声明 `no-transform`，且派生物不扩大 source 的持久化权限。

强制指标：

```text
derived_write_bytes
derived_hit_bytes
derived_encode_cpu
derived_latency_saved
derived_variant_count
estimated_flash_write_amplification
```

若端到端净收益不成立，DerivedEncoded 保持关闭。

### 11.3 RasterExperimental

只服务固定尺寸、固定格式、高复用小图。必须与 DerivedEncoded 和临时缓冲复用比较：

- page fault；
- 工作集；
- 磁盘膨胀；
- 解码节省；
- 能耗；
- 冷启动。

### 11.4 Analysis 失效语义

Analysis 缓存键至少包含 `ContentID + AnalysisKind + implementation/model fingerprint + Vision/API revision + normalized parameters + feature schema version`。模型、算法或 schema 升级必须自然 miss；旧条目惰性删除。Analysis 继承 source 的 namespace、`no-store`、TTL 和文件保护，不能扩大持久化权限。若分析建议被接受并改变像素，其 fingerprint 还必须进入 RenderKey。

### 11.5 磁盘格式与 schema 演进

持久存储分别版本化 Store、Key、Record、Blob 与 Analysis schema。兼容 record 机会式迁移；单条不兼容 entry 当 miss 并惰性删除；Key/全局布局不兼容时原子切换新的 StoreGeneration，旧 generation 后台清理。安全关键升级先撤销旧数据可达性。启动路径禁止同步全盘迁移，未知未来 schema 不得被当前版本改写。详见 ADR-0002。

### 11.6 配额、物理标识与 GC

ContentID 是逻辑摘要，不直接作为日志值或物理文件名。store 使用 namespace-local、随机不透明 `PhysicalBlobID`，metadata 维护索引。磁盘设置 hard limit、soft target、namespace quota 与 Original/Derived/Analysis/partial 类别预算；active reader 通过短期 lease 防止提前物理删除；atime 采用聚合/分桶/批量写，避免每次 hit 写盘。详见 `docs/specifications/cache-budget-gc.md` 与 ADR-0007。

---

## 12. 资源治理：先简单、可测

v1 实现：

```text
NetworkBudget
DiskIOBudget
DecodeBudget
ProcessBudget
MemoryPressurePolicy
```

`DeliveryObjective` 只映射到少量 profile：

```text
interactive
balanced
prefetch
```

GPU、ANE、energy 和精确 deadline 控制不进入 v1 全局控制器。Core 只保留最小资源需求提示，例如：

```text
preferred compute class
estimated peak memory
is degradable
latency sensitivity
```

四类预算采用 permit/reservation 模型，在昂贵阶段开始前准入，并对估算像素、working set、优先级、公平性和 pressure state 做有界控制；不得通过创建无界等待 Task 绕过预算。Low Data Mode/expensive network、后台和 memory pressure 规则见 `docs/specifications/resource-budgeting.md`。当实验增强或新 codec 证明需要时，再升级 governor，而不是预先冻结八维最优控制 API。各平台初始预算与 CI 分层见 `docs/specifications/platform-profiles.md`。Swift 并发所有权、ByteStream fan-out、MainActor 和 `@unchecked Sendable` 约束见 `docs/specifications/concurrency-contracts.md`。

---

## 13. UI 生命周期是核心竞争面

### 13.1 UIKit/AppKit

- 复用时通过 request token 防止旧结果覆盖新内容；
- 目标尺寸变化可触发新的 DecodeKey；
- 离屏取消与预取降级明确；
- transition 只应用于合适的来源，避免缓存命中闪烁；
- placeholder 与错误图不会被迟到任务覆盖。

### 13.2 SwiftUI

必须规范：

- request identity 与 `Equatable` 行为；
- view 消失和 identity 变化时取消；
- placeholder、redacted、preview、final 的状态机；
- 动画切换策略；
- 避免 body 重算导致重复订阅；
- 缓存命中不产生不必要闪烁。

SwiftUI 行为不能只是 UIKit wrapper 的附录。规范状态机、request token、迟到结果和 transition 规则见 `docs/specifications/swiftui-image-state.md`；points/scale 到 target pixels、布局未定、stable-target admission 和动态 resize 规则见 `docs/specifications/target-geometry.md`；错误到 UI 展示、重试和 placeholder 保留矩阵见 `docs/specifications/error-recovery.md`。

---

## 14. 安全与隐私

默认拒绝矩阵由 `docs/specifications/security-defaults.md` 定义并进入测试。

核心规则：

- MIME、UTType、magic number 交叉验证；
- `text/html` 等非图像响应默认拒绝；
- SVG script、external entity/resource 默认禁止；
- 重定向到不同 origin 默认不继承 Authorization；
- `no-store` 不进入任何跨请求可复用缓存；只允许同一 in-flight task cohort 处理，并由当前 view token 继续显示已交付像素；
- 认证响应不进入共享 namespace；
- logout/revoke 通过 NamespaceGeneration 栅栏阻止旧在途任务事后提交；
- DerivedEncoded 与 Analysis 不得比来源拥有更宽松的持久化权限；
- 日志不记录 token、cookie 和完整私有 URL；
- 第三方 codec 版本钉定、fuzz、ASan/UBSan 和恶意 corpus；
- 模型不由 Fovea 隐式远程下载。

安全是 Core v1 Candidate 的硬门禁，并将在验证后进入 Stable Core，不是可选插件。不同平台的保守默认值见 `docs/specifications/platform-profiles.md`。

---

## 15. Canonical workloads 与存在性门槛

详见 `docs/specifications/benchmark-workloads.md`。Phase 0b 固定三个 canonical workloads：

1. **Feed Scroll**：大量图片、高取消率、列表复用。
2. **Detail Hero**：少量超大源图、目标尺寸远小于源。
3. **Auth Gallery**：token/cookie、多账户、登出和私有缓存。

统一核心指标：

```text
TTFP / final latency
peak dirty memory
decoded megapixels
network bytes
cancel waste
main-thread hitch
cache pollution after logout
```

Phase 0a 只要求 workload harness 可运行，不承担存在性裁决。Phase 0b 的 G0 和 W3 是不可交换的硬门禁；外部 HTTP corpus 只在 G0 统计一次。通过 Performance Path 时，W1/W2 必须满足 provisional 性能门和回归护栏；通过 Correctness Path 时，必须证明关键正确性契约、target-pixel invariant 和预注册 non-inferiority。不可比指标既不能帮助通过，也不能判失败；每个 workload 至少保留一个采用统一 harness 的可比较主指标。门限、profile 和可比性分类只能通过 ADR 调整，且不得在查看目标实现结果后追溯改写。

`Adaptive Representation` 可作为第四个非阻塞实验 workload，用于验证多候选选择，不阻塞 v1。

---

## 16. 前沿技术如何进入项目

前沿技术现在就可研究和实现，但不得自动进入 Stable Core。

### 16.1 毕业条件

- 可运行实现；
- 可复现基准；
- 相对确定性基线有净收益；
- 有 fallback；
- 身份和缓存 fingerprint 完整；
- 安全限制、恶意输入测试完整；
- 默认路径无额外成本；
- 公共 API 不依赖某个具体模型；
- 有维护者和升级策略。

### 16.2 当前技术归类

| 技术 | Core 只保留 | 当前归类 |
|---|---|---|
| 多尺寸/格式候选 | RepresentationCandidate | Capability Slot；简单 srcset 可较早实现 |
| HDR gain map / 辅助平面 | lazy attachment | Capability Slot；有独立实现后进入 Experimental |
| JPEG AI | codec capabilities、fingerprint | FoveaLab / Experimental codec |
| C2PA / JPEG Trust | opaque provenance、trust state | Experimental，默认零成本 |
| Vision 裁剪 | Async proposal processor | Experimental，显式启用 |
| ThumbHash/BlurHash | placeholder source | Experimental extras，不属于 AI |
| 端侧超分/修复 | enhancement processor | Experimental，显式 opt-in |
| 学习缓存/预取 | advisor suggestion | FoveaLab，不能控制机制 |
| GPU/ANE 调度 | compute hint | 等真实模块需要后再扩展 |

JPEG AI Part 1 已于 2025 年标准化，因此应立即跟踪和原型验证；这不等于 Apple 平台默认路径已经具备足够采用条件。JPEG Trust/C2PA 同理：现在保留正确接缝，验证插件可并行推进，但普通图片加载默认不得承担验证成本。

### 16.3 AI 加速下的研发方式

AI 用于并行实现候选方案和扩大验证，而不是扩大未经证实的公共契约：

- 同时实现 LRU、SIEVE、S3-FIFO 等策略并回放同一 trace；
- 自动生成 HTTP 状态机组合和 property tests；
- 生成畸形图像与 fuzz corpus；
- 差分测试 ImageIO 与第三方 decoder；
- 分析 Instruments、signpost 和 benchmark 回归；
- 快速丢弃失败原型。

原型成本下降意味着更应依赖实验，而不是更早冻结抽象。

---

## 17. 可观测性

每个请求至少记录：

```text
source resolution
FetchVariantKey / FetchExecutionKey class（不泄露敏感值）
requested/applied shared priority
cache outcome
HTTP freshness/revalidation outcome
bytes and timings
probe/decode/transform backend
decoded pixel count
single-flight joins
cancellation reason and wasted work
budget changes
namespace/store generation
schema migration outcome
final delivery stage
```

支持：

- `OSSignposter`；
- 结构化事件流；
- DeterministicClock；
- trace record/replay；
- 固定 cache/network state；
- advisor 关闭模式；
- 导出匿名化执行摘要。

没有可观测性，不允许宣称策略更优。事件必须版本化、使用随机 RequestTraceID/SharedTaskID，并禁止输出 URL、ContentID、PhysicalBlobID、原始 namespace 或凭证。observer 使用有界异步 sink，阻塞/失败不能影响请求。AI-assisted 变更还必须保存脱敏 Evidence Bundle，记录 base commit、agent/tool 版本、权限、验证与未证明项，不保存 raw secret/prompt。详见 `docs/specifications/diagnostics-contract.md` 与 `docs/specifications/ai-development-assurance.md`。

---

## 18. 实施顺序

### Phase 0a：Runnable Slice（立即开工）

0. 以 `docs/specifications/phase-0a-surface.md` 建立 Implementation Contract，拒绝超出 surface 的空抽象。
1. 建立 workspace 与 Fovea/ImageCraft/Akashic SwiftPM 壳，使用 path dependency；同步建立 0a-bootstrap 的最小可信合并轨道。
2. 实现 FetchVariantKey/FetchExecutionKey canonical encoding 和 0a golden vectors。
3. 完成有界 Transport、spill-to-disk 和 streaming hash。
4. 完成单进程 OriginalEncoded 原子提交与基本 corruption recovery。
5. 完成 ImageIO target-size decode。
6. 完成唯一 0a UI surface：iOS 15+ SwiftUI `FoveaImage`，以及 request token 防迟到覆盖。
7. 实现 `fresh`、304、`no-store`、namespace/revoke 的最小 HTTP/安全路径。
8. 把 `TEST_CATALOG.md` 的 Phase 0a 产品 ID 与 0a-bootstrap AIQA 转成自动化/可审计门禁。
9. 让 W1/W2 harness 跑通并输出 trace，不要求先达到 0b 门限。
10. 在宣布 Phase 0a 完成前，通过全部 `AIQA-GATE-001...010` 与指定 critical mutants。

### Phase 0b：Existence Gate

1. 完成 G0 的 schema/generation crash matrix、priority/revoke property suites 和 key golden vectors。
2. 接入 RFC 向量、cache-tests.fyi 和适用 WPT 的 required external corpus。
3. 完成 W1/W2/W3、Nuke/Kingfisher adapter、固定网络/滚动 trace 和双设备复现。
4. 按预注册规则通过 Performance Path 或 Correctness Path。
5. 公开不可比指标、coverage gap、raw trace、adapter 配置和失败项。
6. 完成 R3 critical mutant、held-out oracle、FoveaAgentEval、SBOM/provenance 与独立审查证据；
7. 通过后才进入 Core v1 Candidate。

### Phase 1：确定性生产核心

- URL/File/Data/Asset，并通过 source identity/invalidation 规格；
- target-size static decode；
- OriginalEncoded、RenderedMemory；
- single-flight、取消和优先级；
- UIKit/AppKit/SwiftUI；
- DecodeLimits、安全矩阵和诊断；
- Fovea Private Image Cache Profile 的 required cases 全部通过。

### Phase 2：经数据选择的优化

- 内存策略 trace 竞赛；
- progressive preview；
- animation；
- DerivedEncoded 保守准入实验；
- Photos；
- richer HTTP Range/recovery；
- capability matrix；
- HDR/辅助平面表示验证；
- animation policy 与独立帧缓存。

### 并行 FoveaLab

从 Phase 0a 起即可并行研究 JPEG AI、trust、HDR/空间图、Vision crop、超分和学习策略。它们通过毕业门禁随时迁移，不绑定固定年份或 Phase 5。

并行不等于抢占主线：FoveaLab 不得修改 Core 公共协议、不得阻塞 Phase 0a PR、不得进入默认依赖图。需要新增 capability slot 时，必须先提交独立 ADR，证明现有接缝无法表达。

---

## 19. 当前明确拒绝的设计

- 用 URL 作为所有缓存与共享阶段的唯一 key；
- 用 ETag/Last-Modified 充当内容摘要；
- 在响应前把未知 `Vary` 字段写入完整请求身份；
- 通用可任意改写阶段的拦截器链；
- v1 通用 DAG/算子运行时；
- v1 八维全局资源优化器；
- 默认开启重建型增强、trust 验证、RasterStore 或学习策略；
- 每个 target 独立仓库；
- Akashic 依赖 UIKit 或图像请求；
- ImageCraft 负责 UI 生命周期；
- 无数据即宣称某缓存算法或 GPU 后端为默认最优；
- 因 AI 提高编码速度而跳过真机、稳定性和安全验证；
- 运行时全局可变 codec/processor registry；
- 直接用 ContentID 作为物理文件名或日志关联 ID；
- 无 hard limit/namespace quota 的缓存；
- 每次 cache hit 同步写精确 atime；
- 把 cache/diagnostics 后台失败覆盖为图片加载失败；
- 无 target 的 decoded-image API 静默解码原尺寸；
- 默认全帧预解码大动画；
- 允许同一 agent 同时修改实现、降低验收门槛并自我批准；
- 以模型自信、AI review、提交量或生成代码比例替代独立质量证据；
- 给 coding agent 默认生产秘密、签名、主分支直写或无限网络/工具权限。

---

## 20. 最终判断

Fovea 的野心不应缩小，但必须被正确安置：

- **Phase 0a 极小且可运行，Phase 0b 严格裁决存在性，Stable Core 只包含已验证承诺；**
- **Capability Slots 面向未来但不绑定具体技术；**
- **Experimental Modules 可高速演进且随时删除；**
- **FoveaLab 并行吸收论文、标准和新平台能力。**

AI 已经改变了原型和验证的速度，因此 JPEG AI、可信媒体、学习策略和端侧增强可以现在就开始，而不是等待若干年。但它们何时成为公共承诺，仍由正确性、净收益、安全和维护成本决定。

Fovea 首先必须把 Phase 0a 写成真实代码，再由 Phase 0b 以身份、HTTP、目标像素、取消、安全和可比较性能裁决其价值。由于多数实现将由 AI 完成，代码通过还不够：实现、验收 oracle 和发布来源必须彼此制衡，并由维护者承担理解和回滚责任。0a 完成前，文档只接受实现驱动的修正；只有基础契约和质量保障同时被代码证实，前沿能力才会成为架构优势，而不是纸面范围膨胀。
