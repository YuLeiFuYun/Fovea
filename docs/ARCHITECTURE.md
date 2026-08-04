# Fovea 图片加载系统架构

> **状态：Proposed（唯一工作架构文档；当前项目状态：`phase0b-closeout`，Phase 1 preparation only）**
> 本文是当前唯一的架构入口。只有经过可运行原型、自动化正确性测试和真机基准验证的局部决策，才可在对应 ADR 中标记为 `Accepted`。整份蓝图在 Phase 0b 完成前不称“定稿”。
>
> **规范优先级：** Accepted ADR 决定其范围内的决策；`specifications/` 决定可执行语义；本文决定系统边界、产品范围和阶段门禁。发现直接冲突时必须停止实现并修正文档，不能由实现者静默择一。
>
> **当前平台基线：** iOS/iPadOS 15、macOS 12；其他平台尚未声明支持。
> **语言与工具链：** Xcode 27 / Apple Swift 6.4、Swift 6 严格并发；当前实现显式启用 `NonisolatedNonsendingByDefault` 与 `InferIsolatedConformances`，并仅采用通过部署与证据门的 6.4 所有权能力。
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

### 1.1 当前实现快照（2026-07）

当前代码已具备：固定职责 coordinator、Fetch/Decode single-flight、无回绕 namespace revoke、持久 StoreGeneration 与单 writer fail-closed、请求级网络权限、Profile ACL、精确 origin policy、URLSession ambient state 清除、代理 metrics 验证、带权 decode working-set 准入、脱敏 URLSession 事务摘要、SwiftUI/UIKit/AppKit 生命周期适配，以及 iOS 15+ `FoveaWorkbench`、macOS Gallery 与 Network Lab 三类可执行验证面。`FoveaNetworkLab` 真实联网必须显式 `--live`；确定性 loopback chaos matrix 才属于本地门禁。

当前没有：通用 middleware/interceptor DAG、自定义代理路由器、IP/CIDR 级 egress 或 DNS rebinding 防护、CPU 时间硬配额、后台 URLSession 延续、完整多进程多 writer、全格式生态、真机竞品 non-inferiority 证明或稳定 API 承诺。运行时不创建子进程；所谓“僵尸进程回收”只适用于测试工具，Network Lab runner 通过进程组超时终止处理。

扩展原则是 typed seam 优先于任意 post-key mutation。任何未来 request preparer 必须在 identity 冻结前执行，或提供版本化且非敏感的 execution fingerprint。

---

## 2. 文档与决策治理

### 2.1 单一权威来源

- `docs/PHASE0B_GRADUATION_AND_PHASE1_ENTRY.md` 与 `docs/phase0b-status.json`：阶段转换和当前阻塞项。
- `docs/ARCHITECTURE.md`：唯一工作架构。
- `docs/adr/`：局部决策及其证据。
- `docs/specifications/`：可执行规范，包括缓存/身份语义、HTTP 一致性、调度、并发所有权、资源预算、错误恢复、诊断、表示正确性、基准、安全默认、UI 状态机和平台配置。
- `docs/TECHNOLOGY_RADAR.md`：前沿技术跟踪，不构成产品承诺。
- `docs/COMPETITIVE_CONTRACTS.md`：只记录经来源或 Phase 0b 适配器验证的竞品能力与 Fovea 验收契约。
- `Benchmarks/ComparativeLab`：不进入生产依赖图的统一竞品协议、独立 adapter package、真机 workload 与脱敏工件。
- `docs/research/`：专题研究与证据综述，不直接形成产品承诺；决策必须进入 ADR/规格。
- `docs/specifications/interdisciplinary-engineering.md`：跨学科工程定律、反教条边界与“金蛋”发现流程。
- `docs/engineering-knowledge.json`：定律、证伪条件、代码证据和可复用发现的机器注册表。

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

### 2.5 跨学科工程定律与发现账本

AI 的知识广度用于扩大候选解释、反例和实验空间，不用于绕过证据。数学不变量、物理资源守恒、生态承载力、控制稳定性、复杂性局部化、经济外部性和科学哲学的可证伪性，被翻译成明确的软件状态、边界、指标与失败条件；类比本身不构成架构证明。完整定律见 `docs/specifications/interdisciplinary-engineering.md`。

重大缺陷和复杂实现还必须检查是否产生可复用“金蛋”：值类型、所有权原语、安全校验器、测试工具、门禁或明确的拒绝抽象边界。promoted 发现必须拥有真实资产、独立证据、复用边界和过度推广风险，并登记在 `docs/engineering-knowledge.json`。`scripts/check-engineering-knowledge.py` 验证原则 ID、测试追踪和资产路径；项目不以定律或金蛋数量评价质量。

---

## 3. 交付门禁与成熟度分层

“Phase”描述当前工程门禁；“成熟度”描述产品承诺。两者不可混用。

### 3.1 Phase 0a：Runnable Slice

0a 的唯一允许实现面由 `docs/specifications/core-surface.md` 规定。任何超出符号预算的抽象或产品必须提供 blocker evidence 并经 ADR 批准。

0a 只证明最小垂直切片可运行、可替换、可观测，不形成长期兼容或性能领先承诺：

```text
URL
→ FetchVariantKey record lookup / FetchExecutionKey single-flight
→ bounded Transport + spill/hash
→ OriginalEncoded 单进程原子提交
→ bounded FetchStage / DecodeStage
→ ImageIO target-size decode
→ generic MemoryCache + scoped RenderKey
→ 一个 UI surface
```

0a 必须具备：

- 基础 key/canonical encoding 与 golden vectors；
- `fresh`、304、`no-store`、namespace 基本隔离；
- 最关键的 request token、取消和 revoked-generation Commit 测试；
- 一个可运行的 W1/W2 harness 骨架，但不要求达到性能门限；
- 最小诊断事件、结构化 `PipelineFailure` 和 deterministic clock；
- 图片无关的 generic Akashic memory cache，以及 fetch/decode 静态并发 hard cap；
- AIQA bootstrap：前 1–3 个 PR 建立隔离 agent、基础 Evidence Bundle、clean trusted CI、protected gates、依赖默认拒绝和 accountable owner；
- AIQA complete：宣布 0a 完成前，`AIQA-GATE-001...011` 与指定关键 mutants 全部真实执行通过。

0a-bootstrap 可以合并产品和治理脚手架，但不等于 Phase 0a 通过。0a 不要求完整外部 HTTP corpus、全量 StoreGeneration crash matrix、双设备复现、双竞品适配器全部完成或 15% 性能收益。

### 3.2 Phase 0b：Existence Gate

0b 决定 Fovea 是否值得进入 Core v1 Candidate。它包含：

- G0 全量协议、持久化、schema、priority 和 revoke 门禁；
- Private Image Cache Profile 的 required external corpus；
- W1/W2/W3 当前 baseline 与预注册竞品 adapter；完整 W1-W15 路线仍由 workload registry 持续追踪；
- 最低性能档和当前主流设备复现；
- Performance Path 或 Correctness Path 至少一条通过；
- R3 完整独立 oracle、关键 mutant、agent eval 与供应链证据通过。

通过 0b 才意味着可以正式声明进入 Phase 1 / Core v1 Candidate Hardening。准备性 adapter、API 收缩草案和 Source 原型可以先行，但不得扩大稳定公共面。完整判据见 `docs/PHASE0B_GRADUATION_AND_PHASE1_ENTRY.md`、`docs/specifications/benchmark-workloads.md` 与 ADR-0008。

### 3.3 Phase 1 / Core v1 Candidate Hardening

Phase 1 与 Core v1 Candidate Hardening 是同一层，不再作为两个重叠阶段维护。Phase 0b 通过后才可正式进入，目标是形成首个可发布候选：

- 收缩 public API，明确普通集成面、Advanced 逃生口和内部实现；
- 在既有 URLSource 上补齐 File/Data/Asset source 的身份、失效、权限和持久化边界；
- 冻结版本化 Fovea Private Image Cache Profile v1 Candidate；
- 以真实宿主 App 完成至少一个兼容周期；
- 固化错误、取消、默认值、配置和 StoreGeneration 迁移政策；
- 建立 API diff、编译器矩阵、二进制体积、启动成本、SBOM 和发布 provenance；
- 保持 target-size decode、缓存、single-flight、安全矩阵、三套 UI adapter 与 canonical workloads 的回归证据。

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


### 3.8 FoveaWorkbench：可演进的 iOS 集成工作台

`Examples/FoveaWorkbenchApp` 与库保持相同的 iOS/iPadOS 15.0 最低版本。它是独立 Xcode App，不进入 SwiftPM 产品图，也不允许依赖 `FoveaTesting`。场景通过稳定 ID、类别、行为和预期结果注册；未来增加 source、渐进加载、动画或 codec 时，应扩展 scenario/capability，而不是复制新的导航和状态容器。

所有正常入口、专题直达入口和场景工坊直达入口都包在 `WorkbenchAppHost` 内。该宿主是 `WorkbenchAppModel.start()`、`scenePhase`、运行错误与重试呈现的唯一 UI 生命周期所有者，并发布稳定的 `runtime.state` Accessibility 值；`WorkbenchRootView` 只组合标签页，快捷路由不得建立第二条运行时或绕过图片管线初始化。

Workbench 的普通交互启动进入 schema 2 的“生态超载世界图谱”。内容由 8 卷、32 个专题、28 份可追踪来源、6 类证据性质和 160 个互不重复的稳定媒体身份组成。每个专题必须同时记录因果机制、权力与分配、主张、质疑、综合判断、来源、指标、讨论问题和图片负载契约；旧九章 schema 和兼容解码已删除。

页面不是同一种卡片复制三十二次。内容层提供 editorial、mosaic、timeline、comparison、atlas、dossier、field-notes 与 immersive 八种媒体表面，并另有首页、专题库、八卷索引、案例集、系统地图、概念索引和方法页。UI 自动化分别进入八种表面，并验证 fit/fill、重建、清内存恢复和从叙事进入完整图片实验场。

媒体治理分三层。许可校验回答能否使用；普通图库采用严格默认准入；公共教育叙事允许肉食与动物利用、未成年人、战争、疾病、伤害、贫困和迁徙进入情境审查，但必须记录教育必要性、来源与许可、主体尊严和隐私、年龄适宜性、非猎奇呈现、避免污名化及替代文本。题材不自动通过，也不自动拒绝；以痛苦制造点击、羞辱主体、来源不可核实或与论证无关的刺激性展示始终禁止。

一级导航固定为理解、验证、证据、设置。理解层承载公共叙事和真实图片负载，再从二级入口进入 11 类产品场景、完整媒体目录与高压 Feed。验证层按问题域组织；原始事件和高级参数只在证据层出现。

`--ui-testing`、确定性集成测试和普通合并门只使用 `fovea-demo.test`；公网 Live XCTest 必须由构建设置显式授权并始终标记为 environment-dependent。App 只依赖官方 `Fovea` product，并通过 `FoveaSystemPipeline` 获得正式 `URLSessionTransport`、持久 namespace generation、Profile/destination ACL、持久 store、single-flight、解码预算和 SwiftUI/UIKit 生命周期。网络预取身份由稳定素材 ID、目标宽高与 content mode 构成，视图刷新 UUID 不进入业务身份；任务条目另带版本戳，reset 前的迟到 completion 不能删除同 key 的替换任务。随包图片由宿主的有界内存缓存管理，不冒充网络证据。

回屏性能由核心和宿主共同保证：SwiftUI 初始 `.empty` 状态保持透明，只有加载延迟真正到期后才显示占位；新鲜 RepresentationRecord 可由持久 ContentID 直接构造 RenderKey，先查 rendered-memory，再按需读取原编码磁盘；Feed 默认保留成功图并预取首批内容。请求/显示配置与 transport/store 配置分别比较，只有后者触发事务式 runtime 替换；重建先取消并汇合全部证据 runtime，再发布新管线；管线代际改变会清空预取完成集，避免新 runtime 被旧预取状态抑制。旧 profile 清理由专用 utility I/O 队列执行，符号链接不参与候选且失败以计数暴露。

每次证据运行串行执行，并使用独立 diagnostics sink、run correlation 和临时 runtime 保存 origin/join/cache/cancel/status evidence；interactive/evidence 采用物理隔离 store 根，预览暖缓存不得污染实验状态；Feed 脚本额外保存 `CADisplayLink` 帧间隔代理与 `task_vm_info.phys_footprint` 差分。证据包 schema 3 绑定 source revision、source-tree hash、dirty 状态和配置指纹；持久 generation 只导出每次随机加盐的短期令牌，时间降到小时粒度，运行/性能记录只用包内顺序号。simulator UDID、原始 URL、凭证、诊断 key digest、locale、时区、精确设备型号、运行 UUID 和精确开始/结束时间均不进入可分享工件。

工程结构由固定 XcodeGen 版本从 `project.yml` 生成并提交生成结果。统一门禁同时比较 PBX、共享 scheme 与 workspace 的字节摘要，验证 canonical `Fovea -> ../..` package 路径、DesignSystem/视觉测试 target 成员和已删除占位素材的缺席；不得用手工 PBX 条目掩盖漂移。门禁还执行 Release Build、生产管线集成测试、UI 行为矩阵和 oracle 1.2.0 的双设备视觉矩阵。行为矩阵按证明对象分配设备：15 项 compact-width 行为在 iPhone 的三个五测试分片中执行；4 项原生 regular-width 行为在 iPad 的两个两测试分片中执行；包含五张公共导航卡的 `DEMO-PT-024` 使用独立 iPad 分片。分片间重启对应 Simulator，实际 15/5 计数写入 phase 报告，不得解释为跳过。 iPad Feed 行为测试以产品实际发布的中文完成状态和内存占用状态为异步完成证据，随后再验证 UIKit collection 与最后一个动态 cell；视觉或元素存在不能替代该业务状态闭环。每个设备族固定七个视觉检查点并同时导出截图、Accessibility 树和几何 JSON；纵向滚动内容与已声明横向轨道按明确规则处理，普通水平逃逸、低于 44 pt 的按钮、缩字和大面积图片重叠仍失败。结构化 phase 报告写入 `.artifacts/ios-example/verification.json`，视觉报告与三联件写入 `.artifacts/ios-example/visual-audit/`。决策与边界见 `docs/adr/0013-workbench-visual-assurance.md`。研究型 `FoveaLab` 与该产品示例保持不同名称和依赖边界。

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

当前生产模块只有：

```text
AkashicCore
AkashicMemory
AkashicDisk
FoveaStorage
```

`AkashicTraceKit`、`AkashicTesting` 只是未来在真实离线策略评估或独立测试工具形成后才允许创建的候选模块，不属于当前 Package 产品。Akashic 缓存任意键值，不知道图片、URL、HTTP 或用户界面。成本由调用者显式传入，不要求第三方类型遵循库私有协议。

### 4.3 Fovea 产品

当前 SwiftPM 顶层 library product 有四个：

```text
Fovea              官方安全集成面；现阶段默认包含 ImageIO adapter
FoveaAdvanced      自定义 transport/store/decoder 与持久化组合的显式逃生口
ImageCraftCore     独立、技术中立的公共 codec contract
ImageCraftImageIO  只依赖 ImageCraftCore 的独立 ImageIO 参考实现
```

源码仍按 ImageCraft、Akashic、FoveaStorage、FoveaHTTP/Core/Persistence/System/AdvancedSystem/Observability/UIKit/AppKit/SwiftUI 的职责 target 拆分；target 是依赖边界，不再等同于对集成者暴露的顶层产品菜单。`FoveaStoreProbe` 只用于跨进程竞争门禁，不是运行时 product。OSLog/Signpost 适配器位于独立 `FoveaObservability` target，`FoveaCore` 不直接依赖 OSLog。`FoveaSources` 与历史候选名 `FoveaDiagnostics` 不得在未实现时列入当前产品。格式解码插件属于 ImageCraft，不以 `FoveaAVIF` 等名称倒置职责。

Phase 0a 已落实该边界：`AkashicMemory` 提供图片无关的 `MemoryCache<Key, Value>`，值成本由 Fovea 插入时显式传入；当前决策见 ADR-0001。

### 4.4 Pipeline 配置与固定职责 stage

Pipeline 在构造后持有不可变配置快照。codec、transport、store、安全策略和 diagnostics 只在 composition root 注入并冻结。当前 `0b-in-progress` 实现按真实职责拆为：

```text
FetchStage                  exact request + fetch single-flight + network permit
DecodeStage                 probe + target decode + decode permit
PipelineCache               record/blob/memory transaction + rollback
EncodedDataCoordinator      原编码入口，不触发像素解码或未验证持久化
ImageLoadCoordinator        cache selection + fetch/revalidate + stale decision
HTTPImageResponseProcessor  200/304 representation semantics + commit/refresh
ImageDeliveryCoordinator    decode/transform + RenderedMemory publication
FoveaPipeline               immutable composition + public failure/revoke boundary
```

这些 stage 使用 Swift `package` 访问级别，不是公共插件点；不提供动态 DAG、interceptor chain 或运行时全局注册。外部调用者只看到请求、配置、pipeline、结构化失败与必要协议。配置变化创建新的 pipeline，进行中的任务继续使用启动时快照。详见 `docs/specifications/pipeline-configuration.md` 与 ADR-0006。

当前 `PipelineCache` 用同一可取消、有界事务门串行化“数据块提交 → 表征记录发布”和显式 mark-and-sweep 垃圾回收，防止 GC 在记录可见前删除新数据块。持久删除先原子发布移除后的 metadata，再删除物理文件；故障可以留下可回收 orphan，但不得留下指向缺失文件的可见记录。自定义 store 只有实现 `OriginalEncodedMaintaining` 与 `RepresentationRecordMaintaining` 才具备公开 GC 能力，否则返回结构化能力错误。

OriginalEncoded/representation 事务与 RenderedMemory 发布是两个 checkpoint：安全 decode 完成后先提交原编码事务，再执行带固定长度 fingerprint 的 `TransformStage`；transform 返回值重新验证 dimension、pixel count 与 working-set cap。transform 失败或超限保留可复用的 OriginalEncoded，但不得发布 RenderedMemory。该边界使处理失败不会强迫重复网络获取，也不会把半成品伪装成 final。

---

## 5. 默认简单 API

架构复杂度不能转嫁给普通使用者。当前已实现的安全默认组合入口是：

```swift
let system = try await FoveaSystemPipeline.open(cacheRoot: cacheRoot)
let image = try await system.pipeline.image(for: request)
await system.invalidateAndCancel() // 宿主确定结束该 runtime 时，取消网络任务并释放 staging lease
```

它固定组合禁用 `URLCache`/Cookie 的 transport 与同一 StoreGeneration 下的 Akashic 持久 bundle，并以独立 `ImageCraftImageIO` 产品作为当前默认 codec。所有默认、高级和 package 组合入口都要求完整 `ImageCodec`；不存在 `ImageDecoding` 兼容入口或动态 descriptor。`FoveaSystemPipeline.open` 可显式注入 qualified codec、transformer 和 `RenderedImageCaching`。持久化替换只由 `FoveaAdvancedSystem` 扩展接受 `FoveaPersistentStoreBundleProviding`：provider 必须一次返回 encoded、records、namespace generation persistence、generation descriptor 和 lifetime，descriptor/compatibility 不匹配时失败；默认 `Fovea` product 不包含该模块。自定义 transport 仍通过 `FoveaPipeline` 注入，且公共构造器必须显式选择 `ProfileAccessPolicy`。SwiftUI 使用 `FoveaImage(request:loader:accessibility:)`；UIKit/AppKit 使用平台 `FoveaImageView.setImage(request:loader:accessibility:)`。所有 UI surface 都要求显式 decorative 或 label。尚未提供只接收 URL 并猜测 target 的便利 API。 生产可观测性通过 `FoveaObservability.OSLogDiagnosticsSink` 显式注入；它只消费已脱敏事件，不改变 pipeline 配置、身份或调度。

当前不存在 `Fovea.shared`、通用 `Source` enum 或只接收 URL 的便利入口。下列形态仅是 Core v1 Candidate 的易用性方向，不是可编译 API：

```swift
// Candidate API — not implemented in Phase 0b.
let image = try await defaultPipeline.image(
    for: url,
    target: .pixels(width: 600, height: 400)
)
```

当前原始编码入口仍使用显式 `ImageRequest` 与 `EncodedDataLoading`；任何未来便利 façade 都不得引入全局可变注册表或绕过 target、ACL 与资源策略。

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

它不持久化、不记录原始 token/Cookie/签名 query。签名 URL 或凭证刷新可以继续命中旧 record，但不会错误加入使用过期凭证的在途任务。自定义 credential header 必须显式分类；header 名集合进入 exact execution policy fingerprint，并随 task 传给跨 origin redirect 剥离策略。

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

非网络来源不得伪装成 Transport。当前生产实现只有 URL source；File/Data/Asset/Photos/Custom 的身份、revision 和失效规则仍是候选规格，不得据此宣称已交付。

### 7.2 Transport

Transport 只搬运远程字节。当前官方 URLSession transport 已实现：

- hard byte limit、分块消费、内存阈值后 spill 与流式 SHA-256；
- 响应头/body 事件分离、取消和 task metrics；
- 请求级 cellular/constrained/expensive 权限；
- Cookie、URLCache、credential store 与 session-wide header 清除；
- 初始 URL 与每次 redirect 的精确 destination policy；
- 跨 origin 凭证剥离。

当前不提供公开下载进度、Range resume 或生产渐进 decoder 输入；这些能力必须在独立状态机与身份契约完成后才能加入。Transport 不建立通用 REST DSL、JSON 映射或 OAuth 框架。

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

Fovea 不宣称实现通用代理缓存。当前 `0b-in-progress` 已实现 GET、200/304、显式 freshness、Age、validator、Vary、认证隔离、no-store、有限 retry 与 stale-if-error 子集；required profile corpus 已进入本地门禁。206/If-Range、stale-while-revalidate 与通用 shared-cache 语义仍未实现，遇到未支持组合时选择不持久化或失败，而不是猜测。

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

Akashic 提供通用 typed blob/cache 事务与存储；FoveaStorage 拥有原编码能力、namespace 指纹与撤销持久化的最小领域契约；FoveaPersistence 提供 adapter 和磁盘组合；FoveaHTTP 拥有 HTTP 语义。FoveaStorage 只依赖 AkashicCore，防止 FoveaCore 与 FoveaHTTP 形成依赖环。热路径所有权固定如下：

| 决策或动作 | 唯一所有者 | 持久化位置 |
|---|---|---|
| 记录是否 fresh、是否允许 stale | FoveaHTTP | RepresentationRecord |
| 条件请求与 304 metadata merge | FoveaHTTP | RepresentationRecord |
| `Vary` 匹配与候选记录选择 | FoveaHTTP | RepresentationRecord 索引 |
| 是否允许落盘 | FoveaHTTP + SecurityPolicy | record flags |
| blob staging、摘要与原子提交 | Akashic 事务 API | OriginalEncoded |
| single-flight 注册与订阅 | FoveaCore，按 FetchExecutionKey | 仅内存任务表 |
| URLSession/URLCache 配置 | FoveaTransport/FoveaHTTP composition root | 不重复持久化 |
| transport 复用上下文 | `TransportReusePolicy` | task-local 或仅摘要进入精确执行身份 |

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

目标模型：

- 相同 FetchExecutionKey 且执行约束兼容时共享网络获取；
- 相同 ContentID 可以共享探测；
- 相同 DecodeKey 共享解码；
- 相同 RenderKey 共享最终处理；
- 不同目标像素在解码阶段分叉；
- 相同解码、不同圆角在处理阶段分叉。

当前 `0b-in-progress` 已实现 FetchExecutionKey、DecodeKey 与 RenderKey 级 single-flight：相同精确网络执行共享 fetch，相同 namespace generation + DecodeKey 共享 probe/decode，相同 namespace generation + RenderKey 共享 transform。RenderedMemory 仍负责已完成结果复用；single-flight 负责并发中的工作共享，两者是不同契约。namespace revoke 会取消对应 fetch/decode/transform，并在发布 RenderedMemory 前再次验证 generation。

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
- 流式 preview 的宿主 publication fence 必须在等待 codec cancellation 前关闭；正在执行的 `append` 可以在取消请求后才返回 generation，但旧 view identity 不得再发布该像素；
- `UI-PT-029/030` 的 iOS Simulator lab 使用 test-only URLProtocol/URLSession delegate 验证 URLSession 分块 → ImageCraft session → `FoveaImageView` → CADisplayLink 和身份替换竞态。该 lab 绕过生产 staging，只证明宿主接缝和栅栏顺序，不证明生产 transport 已支持流式交付，也不把 CADisplayLink 回调解释为 GPU/物理屏幕 scanout；
- preview 不得写入最终 RenderKey；最终内容完成后才能提交可跨请求复用的 DecodeKey/RenderKey；
- RepresentationRecord 与 blob 引用原子提交；304 只更新 record，不重写 blob；
- 每个任务捕获 NamespaceGeneration，logout/revoke 后 Commit 再校验；旧 generation 的在途任务不得让已清理数据复活；
- 解码失败不污染 RenderedMemory；DerivedEncoded 半写文件不可见；
- 取消和崩溃后 staging 可回收。

更完整的 partial/Range/commit 规则见 `docs/specifications/cache-semantics.md`。

### 9.4 错误、重试与回退

Phase 0a 已用 `PipelineFailure(category, stage, disposition, reasonCode, statusCode)` 统一公开错误，并将同一结构写入脱敏 diagnostics；底层 URL、NSError、磁盘路径和 decoder 文本不直接暴露。cache write、GC 或 diagnostics 失败默认不能覆盖已经成功生成的 final。0a 只标记 retryable，不自动重试；retry budget、stale、替代 decoder 和 representation fallback 属于后续阶段。详见 `docs/specifications/error-recovery.md`。

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

### 10.4 Codec 能力契约与后端选择

当前默认后端仍是 ImageIO，但它不再被当作管线结构本身。独立 `ImageCraftCore` 产品公开 `ImageCodecDescriptor`、`ImageCodec` 与 `PreparedImageDecoding`，以版本化有限集合声明容器格式、完整/渐进交付、主帧/动画轨道、metadata、SDR/HDR、输出表示、取消保证和资源估算。`DecodeStage` 在任何 working-set reservation 与像素分配前验证请求语义；能力缺口 fail closed。只实现最低 `ImageDecoding` 的 decoder 仍可使用，但只能获得按动态类型隔离的保守身份与通用资源估计。

当前 ImageIO adapter 声明 PNG/JPEG/GIF 的完整主帧，以及 **仅 JPEG** 的 progressive generations；`progressiveFormats` 与 `deliveryModes` 分开，禁止把所有格式与渐进交付误当成笛卡尔积。它仍只承诺 orientation/source color、SDR、`CGImage` 和 operation-boundary cancellation；能够探测 GIF 多帧容器不等于已经实现 animation timeline。ImageCraft progressive session 已可运行，也不等于 Fovea 的生产 `URLSessionTransport` 已具备流式 fan-out：当前生产 transport 仍先完成有界 staging、长度/摘要验证和最终 handoff。

后端 identity 是：

```text
codec identifier
+ implementation version
+ codec contract version
```

该 fingerprint 同时进入 DecodeKey 和 RenderKey。任何可能改变像素、颜色、方向、metadata 解释或 capability 语义的变化都必须改变版本，防止不同后端或不同语义复用同一派生像素。

working-set 准入使用：

```text
W_admit = max(W_generic, W_backend)
```

后端估计只能提高保守程度，不能通过低报削弱 host 下界；零值、负值或无法表达的估计作为 codec contract violation 失败。prepared state 在能力、估计、准入、取消和 decode 失败路径都必须释放。

公共 contract 与显式注入已经可用，但只有第二个 backend 通过技术中立的共享 conformance kit 后，才考虑一个 pipeline 内的 registry 与按格式选择策略。首版多后端选择必须确定、显式、可关闭，不尝试没有证据的“自动最优”。当前默认迁移只需修改官方 composition root，原始编码与 HTTP 表征无需迁移，派生像素由 codec fingerprint 自动隔离。ImageIO、vImage、Core Graphics、Core Image 和 Metal 的具体组合仍由真机数据选择；Metal 不是默认答案。

row alignment 由目标后端和基准决定；不宣称固定 64 字节对齐即可保证 Core Animation 零拷贝。

Display preparation 是条件阶段。若结果已 eager decoded 且 display-ready，不重复调用平台 preparation API。能力契约见 ADR-0011；公共插件、独立 ImageIO 与缓存装配见 ADR-0012；并行集成计划见 `docs/roadmaps/fovea-codec-parallel-roadmap.md`。

### 10.5 缓冲复用

ImageCraftProcessing 应评估临时像素缓冲池和可复用工作区，尤其是动画、连续 resize 和颜色转换。缓冲池的收益要与内存滞留、线程安全和 jetsam 风险一并测试；不能只研究磁盘 RasterStore。

### 10.6 图像表示正确性

Core 的真实表示不是 `UIImage`。`DecodedImage` 必须明确 pixel size、orientation state、颜色描述、dynamic range、alpha/pixel format、display readiness 和 lazy attachments。普通显示路径默认把 orientation 规范化为逻辑 `.up`；颜色/HDR/tone-map/attachment policy 参与 DecodeKey 或 RenderKey，不能在 P3/sRGB、HDR/SDR 间错误共享。详见 `docs/specifications/image-representation.md`。

### 10.7 动画图像

动画属于 Phase 2/Experimental，不阻塞 Phase 0a。`ImageDecodeTrackMode.animatedSequence` 与 `ImageFrameTiming` 只冻结能力词汇和无溢出时间值；当前生产 `FoveaPipeline` 仍不会枚举动画轨道、调度 frame clock 或播放动画。

真正实现使用独立 animation asset、frame cache 和 cost model，默认采用受控 decode window，不把所有帧无界解码进内存。track selection、frame timing、loop、disposal/blend、可见性、后台和 Reduce Motion 策略见 `docs/specifications/animation-policy.md`。

### 10.8 渐进代次

渐进预览必须以同一 content/backend/request/frame identity 下的严格递增 generation 发布：

```text
generation_new > generation_published
```

相等、倒退或跨 identity 的结果不得替换当前图像。当前只实现 `ImageProgressiveGeneration` 值语义和模型检查；生产尚缺累计输入预算、增量 parser、preview cadence、subscriber sharing/cancellation、final promotion 和 UI identity fence，因此 W4 继续保持 capability gap。

### 10.9 Codec 与 Fovea 的职责边界

codec 不接触 URL、授权 header、profile namespace、HTTP record、持久 cache 或 UI。Fovea 不感知 codec 的 entropy model、SIMD、LoRA、GPU kernel、内部 frame graph 或 scratch allocator。双方共享的只有：

```text
versioned descriptor
bounded probe facts
capability request/result
resource estimate
prepared/decode lifecycle
pixel + metadata result
stable failure taxonomy
conformance fixtures
```

未来 codec 完成后，应先独立通过 conformance/corpus/fuzz/differential gate，再作为 opt-in backend 接入；不能因其研究目标更先进而跳过 host 侧准入与身份验证。

---

## 11. 缓存：使用语义名，不使用乱序层号

RenderedMemory 通过公共同步 `RenderedImageCaching` 契约替换算法或实现。其键强制包含 namespace、generation 和完整 RenderKey；调用方不能通过自定义缓存绕过账户隔离、撤销代际、transformer 或 codec fingerprint。默认实现是 Akashic 八分片 SIEVE，但不是语义要求；分片数固定为经 V4 retention 反例筛选的 8，而不是按核心数动态变化。OriginalEncoded 与 RepresentationRecord 已分别由公共 store 协议抽象；官方 System 组合根使用持久默认实现，自定义持久存储通过 `FoveaPipeline` 显式注入。request alias、transient verified handoff 和提交事务属于正确性状态机，不开放为普通缓存插件。

```text
RenderedMemory       目标尺寸、处理完成的显示结果
MetadataMemory       格式、尺寸、颜色、validator 等轻量信息
OriginalEncoded      原始响应 blob + RepresentationRecord
DerivedEncoded       目标尺寸压缩衍生物，默认保守准入
Analysis             模型/Vision 分析结果，独立预算
RasterExperimental   未压缩热点 slab，默认关闭
```

### 11.1 内存策略

RenderedMemory 当前只维护 SIEVE，不保留生产 LRU 兼容分支。命中只设置单比特访问标记，淘汰指针在需要空间时沿 FIFO 链表清位或淘汰，避免逐命中改链表。硬约束仍包括 byte-aware cost、单对象 cap、oversize reject、memory pressure 清理和总成本不溢出。

选择依据不是“新算法”标签，而是精确离线 oracle、WorkBench 回屏/扫描 trace、独立状态机差分和 NSDI 2024 SIEVE 研究的假设匹配。LRU、GDSF、频率密度和学习增强策略只保留在离线比较器中；若真实 trace 证明 SIEVE 持续劣化，必须以新证据替换，而不是保留两套生产状态机。

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

ContentID 是逻辑摘要，不直接作为日志值或物理文件名。store 使用 namespace-local、随机不透明 `PhysicalBlobID`，metadata 维护索引。目标架构包含 hard limit、soft target、namespace quota、分类预算、active-reader lease 与批量 atime；这些目标详见 `docs/specifications/cache-budget-gc.md` 与 ADR-0007。

当前实现具备单 store soft limit、namespace 隔离、opaque locator、引用快照、显式 mark-and-sweep、持久 namespace revoke generation，以及由 `AkashicDisk.StoreGenerationDirectory` 提供的原子 store-generation 指针切换。generation 选择与指针发布同时受进程内锁和 POSIX 文件锁保护，独立进程竞争门禁验证所有 opener 收敛到同一 generation。`FoveaPersistence` 在该 generation 根目录组合 typed encoded/record/namespace-generation stores；FoveaStorage 提供共享领域契约，具体 `AkashicOriginalEncodedStore` 保持 package-only，旧 `OriginalEncodedStore` 及其独立 manifest 实现已经删除；namespace revoke 在清理 blob/record 前原子发布新世代，清理失败或进程终止后重启不会使旧世代重新可读。持久层只存储 fingerprint → UInt64，Core 契约由 System adapter 连接，避免依赖方向倒置。具体 representation manifest actor 属于该模块并保持 package implementation，`FoveaHTTP` 只拥有表征模型与存储协议。启动时会清理不完整目录和暂存指针，并恢复到完整且兼容的 generation。运行期 GC 即使没有 manifest victim 也会扫描孤儿与暂存文件。generation 选择之后，`FoveaPersistence` 对活动 generation 持有进程生命周期的单 writer 租约：同进程重复打开复用同一组 store actor，跨进程第二 writer 立即失败关闭，owner 退出后才可重新取得租约。当前仍不支持多个进程共享 writer 或跨进程 reader/writer 快照协调；namespace quota、reader lease、DiskIOBudget 与批量 atime 也尚未实现。

---

## 12. 资源治理：先简单、可测

当前实现具有可取消的 fetch/decode hard cap、有界等待队列和带权 decode working-set reservation。permit 位于 single-flight operation 内部；probe 后立即释放 count permit，等待者取消不会启动对应阶段或泄漏 permit。队列按当前订阅者有效优先级选择，并以 `maximumPriorityBypasses` 限制低优先级饥饿；官方系统层在 memory pressure 下清空可重建 RenderedMemory。Swift TaskPriority/URLSessionTask.priority 仍只是 best-effort 映射。尚未实现 namespace 加权公平、CPU 时间/能耗/thermal 动态预算或后台执行治理。

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
- 重定向到不同 origin 默认不继承 Authorization，并重新执行精确 destination policy；
- 官方 URLSession 不继承调用者配置中的 Cookie、credential storage、URLCache 或 session-wide header；
- namespace generation 达到计数上限后永久失败关闭，不允许回绕；
- `no-store` 不进入任何跨请求可复用缓存；只允许同一 in-flight task cohort 处理，并由当前 view token 继续显示已交付像素；
- 认证响应不进入共享 namespace；
- logout/revoke 在 persistent cleanup 前耐崩溃发布 NamespaceGeneration，并通过栅栏阻止旧在途任务事后提交；
- DerivedEncoded 与 Analysis 不得比来源拥有更宽松的持久化权限；
- 日志不记录 token、cookie 和完整私有 URL；全部动态 OSLog/signpost payload 使用 private privacy，防止短期 digest、尺寸、状态码与路径时序成为公开行为指纹；
- 使用 `stat/fstat/lstat` 的 Akashic targets 各自携带 Privacy Manifest；Workbench 可执行目标另声明容器内 FileTimestamp `C617.1` 与仅用于 App 功能的 UserDefaults `CA92.1`。门禁把源码调用、XcodeGen/SwiftPM 资源和 Release 产物绑定验证；所有清单均无 tracking domain 或 collected data；
- 第三方 codec 版本钉定、fuzz、ASan/UBSan 和恶意 corpus；
- 模型不由 Fovea 隐式远程下载。

安全是 Core v1 Candidate 的硬门禁，并将在验证后进入 Stable Core，不是可选插件。不同平台的保守默认值见 `docs/specifications/platform-profiles.md`。

---

## 15. Canonical workloads 与存在性门槛

完整 canonical workload 矩阵固定为 W1-W15，权威机器入口是 `Benchmarks/workload-registry.json`，人类可读摘要见 `docs/project-memory/accepted-workload-matrix.md` 与 `docs/specifications/benchmark-workloads.md`。

Phase 0b 当前只执行其中三个最小端到端 baseline：

1. **W1 Feed Scroll**：大量图片、高取消率、列表复用；
2. **W2 Detail Hero**：少量超大源图、目标尺寸远小于源；
3. **W3 Auth Gallery**：token/cookie、多账户、登出和私有缓存。

W1-W3 完成不表示 W4-W15 完成，也不能生成完整图片加载库“最佳”声明。W4-W15 必须持续保留状态、依赖、能力缺口和开放事项。

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

`Adaptive Representation` 保留为辅助 workload `X1-ADAPTIVE-REPRESENTATION-V1`，用于验证多候选选择，不占用 W4，也不阻塞 v1。

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

- 在离线分析器中实现 SIEVE、LRU、GDSF、频率密度和学习增强候选并回放同一 trace；生产只保留已通过采用门的策略；
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
PipelineFailure category/stage/disposition/reasonCode
```

支持：

- `OSSignposter`；
- 结构化事件流；
- TestWallClock；
- trace record/replay；
- 固定 cache/network state；
- advisor 关闭模式；
- 导出匿名化执行摘要。

没有可观测性，不允许宣称策略更优。事件必须版本化、使用随机 RequestTraceID/SharedTaskID，并禁止输出 URL、ContentID、PhysicalBlobID、原始 namespace 或凭证。observer 使用有界异步 sink，阻塞/失败不能影响请求。AI-assisted 变更还必须保存脱敏 Evidence Bundle，记录 base commit、agent/tool 版本、权限、验证与未证明项，不保存 raw secret/prompt。详见 `docs/specifications/diagnostics-contract.md` 与 `docs/specifications/ai-development-assurance.md`。

---

## 18. 实施顺序

### Phase 0a：Runnable Slice（本地实现切片已落地，外部信任闭环未完成）

当前本地实现已具备：

- SwiftPM product 边界与 generic Akashic memory cache；
- stable variant / exact execution / content / render identity；
- bounded delegate transport、spill、hash 与逐块背压；
- OriginalEncoded、record schema、namespace fingerprint/generation 与撤销事务；
- 固定 `FetchStage`、`DecodeStage`、`PipelineCache` 和 orchestration；
- target-size ImageIO decode、显式 SwiftUI accessibility 与 request token；
- `PipelineFailure`、有界 diagnostics、W1/W2/W3、critical mutants、rollback 和 sanitizer 门禁；
- 静态 fetch/decode active + queued hard cap。

当前产品实现已进入 `phase0b-closeout`，Phase 1 preparation 已开始，但治理证明仍缺少远程 protected required check、可信 CI run locator、human comprehension attestation 与独立 held-out evaluator。功能代码和本地验证通过不能冒充这些外部信任锚，也不能倒推宣布 0a/0b 已完成。

### Phase 0b：Existence Gate（当前状态：`phase0b-closeout`）

1. 完成 G0 的 schema/generation crash matrix、priority/revoke property suites 和 key golden vectors。
2. 接入 RFC 向量、cache-tests.fyi 和适用 WPT 的 required external corpus。
3. A 级七项矩阵已完成本地集成与 target 构建：Apple Native、Fovea、Nuke、Kingfisher、SDWebImage、PINRemoteImage 使用六项 headless 合同，Apple AsyncImage 与 FoveaResponsiveImage 使用配对 SwiftUI surface；AlamofireImage 仅为 B 级补充。继续完成当前源码摘要下的正式 W1/W2/W3、W7 与 SwiftUI aggregate、稳定 iOS 复跑和双设备复现。W4-W15 的计划、能力缺口和实现顺序由 `Benchmarks/workload-registry.json` 保持可见。
4. 按预注册规则通过 Performance Path 或 Correctness Path。
5. 公开不可比指标、coverage gap、raw trace、adapter 配置和失败项。
6. 完成 R3 critical mutant、held-out oracle、FoveaAgentEval、SBOM/provenance 与独立审查证据；
7. 通过后才进入 Core v1 Candidate。

### Phase 1 / Core v1 Candidate Hardening

Phase 1 不重复建设已经存在的 URL 管线、目标像素解码、OriginalEncoded、RenderedMemory、single-flight、取消、优先级和三套 UI adapter。它负责把这些内部能力收缩成可发布候选：

- 收缩 public API，分离普通集成面、Advanced 逃生口与内部实现；
- 补齐 File/Data/Asset source 的身份、失效、权限与持久化契约；
- 冻结版本化 Private Image Cache Profile v1 Candidate；
- 完成真实宿主 App 兼容周期；
- 固化错误、取消、默认值、配置和 StoreGeneration 迁移政策；
- 建立 API diff、工具链矩阵、二进制体积、启动成本、SBOM 与发布 provenance；
- 继续允许 breaking change，Stable Core 在兼容周期和 Accepted ADR 前保持为空。

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
