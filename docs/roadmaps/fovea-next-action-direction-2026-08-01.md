# Fovea 接下来行动方向（2026-08-01）

> **状态：Active canonical plan。** 本文件取代 2026-07-28 的可插拔图像栈计划和
> 2026-07-30 的组件边界迁移路线图。已完成的提取与迁移事实进入项目记忆和
> `component-pins.json`；旧操作步骤不再保留，避免未来执行者重复建立已完成的边界。

> 状态：Active execution direction
> 适用范围：Fovea、ImageCraft、Akashic、跨仓 conformance、比较与发布证据
> 继承：`docs/project-memory/long-horizon-roadmap.json` 的 P0-P9 机器骨架，不替代、不重编号既有阶段
> 当前源状态：ImageCraft 与 Akashic 已公开、MIT、alpha-tagged、CI-green 且受 required check 保护；Fovea 已使用公共 exact pins，正在建立首个隐私净化公共根提交

## 1. 真正的核心问题

本轮真正要决定的不是“怎样开始封装 ImageIO 和缓存”，因为这两件事在本地已经基本完成。真正的问题是：

> 如何把已经成立的逻辑组件边界，转换为可独立发布、可精确锁定、可回滚、可组合验证的物理依赖边界，同时确保第三方替换不能削弱 Fovea 的 HTTP、身份、授权、撤销、资源和持久化事务语义？

因此，当前主线不是继续增加协议，也不是扩大功能面，而是完成四次跃迁：

1. **已完成**：从内嵌源码镜像跃迁到公共、不可变 exact-revision 外部依赖；
2. **进行中**：从组件分别通过跃迁到跨仓 conformance 与组合语义通过；
3. **进行中**：从本机局部证据跃迁到 Fovea 公共根、required CI、回滚与稳定真机证据；
4. **待推进**：从选取若干优势指标跃迁到预注册语义等价类内的有界 Pareto 证书。

## 2. 对原始前提的修正

### 2.1 ImageIO 不需要重新封装

独立 `ImageCraft` 仓库已经存在，并提供：

- `ImageCraftCore`：codec descriptor、能力、资源、prepared-state、像素与颜色契约；
- `ImageCraftImageIO`：Apple ImageIO/Core Graphics 参考实现；
- 独立消费者、公共 API、平台矩阵、retained corpus、oracle、性能与 release-readiness 门。

ImageCraft 当前公共提交 `bc93b8df0337d7a57779b53106dd744ad97b095e` 是唯一支持的 revision，已通过 GitHub Hosted `xcode-27` required CI，并以 `0.1.0-alpha.5` 标记。Fovea 通过公共 HTTPS exact revision 使用它，内嵌 target/source 已删除；当前 clean-copy 通过。剩余缺口是真实独立 codec、hostile corpus 和真机资源证据。

### 2.2 缓存库也不需要从零拆分

独立 `Akashic` 仓库已经存在，并提供：

- `AkashicCore`：typed blob、partition、generation、publication 契约；
- `AkashicMemory`：SIEVE 内存缓存；
- `AkashicDisk`：stage/publish/discard、单 writer、恢复、损坏隔离和文件系统防御。

Akashic 当前公共提交 `2715f23d50b5a17b7328be41608eaf1b1c99b0d6` 是唯一支持的 revision，已通过 GitHub Hosted `xcode-27` required `core` CI（run `30790047451`），并以 `0.1.0-alpha.5` 标记。Fovea 通过 typed adapter 和公共 exact revision 使用它，内嵌 target/source 已删除；当前 clean-copy、fault V5、resource V2 与平台构建证据通过。物理断电和稳定真机资源/能耗证据仍待完成。

### 2.3 “整体帕累托优势”不能作为一个无条件目标

全局、跨能力、跨设备的“全面支配”通常不存在，也无法由有限实验证明。可成立的目标是：

> 在固定平台、设备、系统、能力剖面、输入域、质量约束和 workload 中，Fovea 对全部语义合格对手在所有预注册主要指标上非劣，并在至少一个主要指标上严格更优；能力缺口、不可比和不确定结果保持可见。

这是一组 scoped Pareto certificate，而不是一个总榜或加权总分。

## 3. 当前架构判断

### 3.1 已经正确的边界

应继续稳定：

1. codec backend；
2. rendered-memory cache；
3. original encoded/blob store；
4. representation record store 的实现边界；
5. advanced transport；
6. deterministic image transform。

### 3.2 不得插件化的宿主权威

不得交给插件改写：

- Fetch/Content/Decode/Render 身份代数；
- authorization 与 Profile ACL；
- namespace generation 和 revoke fence；
- single-flight 的 join/cancel/retention 语义；
- 跨 encoded/record 的发布资格与事务协调；
- credential refresh；
- UI identity/state machine；
- benchmark acceptance 与 release policy。

这些不是“缺少扩展性”，而是 Fovea 能证明正确性的可信计算基。

### 3.3 当前构造边界

#### A. codec 入口已收紧

`FoveaSystemPipeline.open`、`FoveaPipeline` 和 package 内部 DecodeStage 现在统一接收 `any ImageCodec`。动态 legacy descriptor、通用资源估计 fallback 和旧构造标签均已删除。

当前规则：

- descriptor、capability、resource estimate 和 cache fingerprint 均为必需契约；
- 不建立全局 codec registry，直到第二个真实 backend 通过 conformance。

#### B. 持久缓存不能以独立裸 hook 注入

官方组合根当前固定同时打开 encoded store、representation record store 与 namespace-generation store。这个耦合有合理性：三者共享 StoreGeneration、writer lifetime、revoke 和发布事务。

方向：

- 不给 `FoveaSystemPipeline.open` 增加三个互不相关的 store 参数；
- 设计一个不可变、经过资格验证的 `PersistentStoreBundle` 或 factory seam；
- bundle 必须同时提供 encoded、records、namespace-generation、generation identity、关闭/生命周期语义和兼容 fingerprint；
- Fovea 在接收 bundle 后仍重验 authority、digest、generation、stage/publish 和 record eligibility；
- 第一版只在 `FoveaAdvanced` 暴露，默认 `Fovea` 继续使用 ImageIO + Akashic 安全组合。

## 4. 执行优先级

优先级从高到低：

1. **发布 Fovea 隐私净化公共根，并让 required CI 全绿**；
2. **保持当前 exact pin、clean-copy 与 conformance registry 一致**；
3. **建立独立 codec/storage conformance kits 与 qualified composition seam**；
4. **完成 Akashic 物理断电、真机 I/O/能耗和 ImageCraft 真机资源证据**；
5. **重新锁定 A-tier，重跑 W1/W2/W3/W7/W8/W10/W13**；
6. **按依赖顺序激活 W4-W15 与第二 codec**。

组件仓库、exact pins 和内嵌源码删除已经完成，不再作为未来任务重复执行。功能数量仍不是当前瓶颈。

## 5. 分阶段行动计划

### Gate 0：建立可迁移的干净基线（P0）

状态：**当前组件边界已完成；Fovea 公共根待发布。**

已完成：本地历史 bundle、隐私净化、MIT 边界、公共 exact pins、`Package.resolved`、零 sibling 依赖 clean-copy、475 项宿主回归。当前退出条件只剩 Fovea 根提交、公共 CI 与后续提交可执行源码回退。

### Workstream A：ImageCraft 正式发行与迁移（P1 → P2）

状态：**本地与公共迁移完成。**

- 公共 MIT 仓库、`0.1.0-alpha.4`、Hosted `xcode-27` required `core` check 已建立；
- 公共 API、consumer、兼容与组件门在 GitHub CI 通过；
- Fovea 只固定到 `bc93b8df0337d7a57779b53106dd744ad97b095e`；
- 内嵌源码已删除，宿主与 clean-copy 均为 475/475。

剩余：真实独立 codec conformance、稳定真机 RSS/能耗和格式范围扩展证据。

### Workstream B：Akashic 正式发行与迁移（P4 → P5）

状态：**本地与公共迁移完成。**

- 公共 MIT 仓库、`0.1.0-alpha.5`、Hosted `xcode-27` required `core` check 已建立；
- 55 项组件测试、fault V5、resource V2、崩溃/quota/contention/六项平台门和 GitHub CI 通过；
- Fovea 只固定到 `2715f23d50b5a17b7328be41608eaf1b1c99b0d6`；
- typed adapter 是唯一原编码持久化路径，内嵌源码已删除，当前宿主与 clean-copy 均为 478/478。

剩余：跨仓 storage conformance、物理断电和稳定真机 I/O/能耗；flat-manifest 写放大已由 manifest v2 增量记录方案替代。

### Workstream C：跨仓 conformance（P6）

当前 provider 与 ImageCodec v1 kit 已作为独立 SwiftPM consumer 运行；真实第三方实现和发布级证据仍未完成。

应建立两个小而独立的 kit，避免一个万能测试框架：

#### CodecConformanceKit

- capability/request/descriptor 的有限语义；
- bounded probe；
- still decode；
- prepared create/consume/discard；
- resource estimate 和宿主保守 join；
- cancellation 声明；
- format、尺寸、orientation、color、metadata 和失败分类；
- ImageIO backend 与故意缺能力 fake backend 运行同一义务；
- fixture manifest 与语言中立 observation schema；
- 当前唯一版本 ImageCraft × 当前唯一版本 Fovea 矩阵。

只吸收 `ImageCodecCapabilityAlgebra` 中必要的有限 request/offer、refinement 与反例生成；不把其完整 attestation/governance 系统放入运行时。

#### StorageConformanceKit

- digest/partition/generation；
- stage/publish/discard；
- read/remove/removeAll；
- writer exclusivity；
- future schema、corruption、orphan/temp recovery；
- ENOSPC、permission、owner、crash 与 reopen；
- host adapter 的 revoke、record、cross-store transaction 义务；
- 当前唯一版本 Akashic × 当前唯一版本 Fovea 矩阵。

组件 conformance 和 Fovea host composition 必须作为不同证据层报告。

### Workstream D：资源契约收敛（P0/P6）

当前单一 `workingSetBytes` 对第一版 admission 有用，但不能表达 prepared state、framework-private allocation、output ownership transfer、分支别名和 cancellation reclaim tail。

行动：

1. 保留现有公共标量，避免未经验证的大 API 重构；
2. 在内部引入阶段化 resource lifetime ledger：probe、prepare、decode、output、transform、publish、reclaim；
3. 区分 capacity stock、cumulative work、concurrency cardinality 和 reclaim latency；
4. host 使用通用下界、backend 声明、实测校准中的保守 join；
5. `unknown` 不得被转换为数值硬上界；
6. 在 ImageIO held-out corpus 与稳定真机校准前，不公开通用多资源协议；
7. 第二 codec 的准入必须等待该模型能表达两种 backend 的实际生命周期。

`ImagePipelineResourceEnvelopeLab` 和 `ImageArtifactCausalModel` 作为模型与反例来源，不成为生产依赖。

### Workstream E：组合正确性矩阵（P6）

至少验证：

1. ImageIO + Akashic 默认组合；
2. qualified custom codec + Akashic；
3. ImageIO + custom rendered cache；
4. ImageIO + qualified persistent-store bundle；
5. codec、rendered cache、persistent bundle 同时替换；
6. capability 缺失在昂贵分配前失败；
7. backend 低报资源不能绕过 host 上界；
8. delayed cache hit 与 network completion 竞态；
9. stage/publish/discard 与 cancel/deadline/revoke 竞态；
10. revoke 后旧 generation 的所有派生结果不可达；
11. corruption、future schema、ENOSPC、permission、short write；
12. cold、warm、reopen、pressure、scroll、identity churn。

每种组合必须绑定具体 component version fingerprint；“协议相同”不等于“像素与资源身份相同”。

### Workstream F：比较与 Pareto 改进循环（P7）

#### A-tier 端到端矩阵

固定包含：

- Apple URLSession + URLCache + ImageIO；
- Apple AsyncImage；
- Nuke；
- Kingfisher；
- SDWebImage；
- PINRemoteImage；
- Fovea。

正式实验开始时重新解析最新稳定版本并锁定完整 commit/tag、依赖树和构建环境。不得沿用文档中可能过期的版本号。

#### 组件矩阵

Codec：

- 原生 ImageIO；
- ImageCraftImageIO；
- libjpeg-turbo 等格式专用参考；
- 未来 AxiomRaster，只在通过准入门后加入。

Cache：

- NSCache；
- URLCache（仅 HTTP 语义）；
- LRUCache；
- PINCache；
- Akashic；
- 算法 trace oracle（Belady/SIEVE/LRU/S3-FIFO/TinyLFU 等，不进入 Apple 绝对性能总榜）。

#### 首轮迁移后重跑范围

先重跑 W1、W2、W3、W7、W8、W10、W13：

- W1/W7/W10 验证滚动、并发、取消和 UI identity；
- W2 验证目标像素、颜色、方向和 decode 资源；
- W3 验证认证、Vary、no-store、redirect、namespace；
- W8/W13 验证持久化、恢复和缓存策略。

W4-W6、W9、W11-W12、W14-W15 仍然保留，但只有生产能力与不可变实验计划同时存在后才激活声明。

#### 判定规则

1. correctness/security hard gates 先通过；
2. 只在语义等价类内比较；
3. 全部预注册主要指标达到 non-inferiority；
4. 至少一项达到 multiplicity-corrected superiority；
5. 同时报告 p50/p95/p99、分布、峰值、取消浪费、I/O、能耗和 UI 暴露；
6. 不使用加权总分；
7. Simulator 只能校准，不产生 release 性能声明；
8. 负结果、不可比和 capability gap 不得删除。

改进循环固定为：

```text
劣势定位
→ 实现缺陷 / 语义成本 / 测量混杂 / 能力缺口
→ 单一机制修改
→ 单元、模型、故障测试
→ 组件实验
→ 端到端 workload
→ held-out / 稳定真机
→ 接受、回滚或登记负结果
```

### Workstream G：随后才推进的能力（P8/P9）

#### W6 与 Afferent

Afferent 的 strong-ETag/If-Range、request fingerprint、bounded amplification、background adoption 和 finalization arbitration 对 W6 有直接价值。先提炼 acquisition/transport 义务和 trace，不直接把 Afferent 变成 Fovea 依赖，也不把通用下载管理器塞入图片热路径。

#### Progressive/animation/HDR

- progressive 采用独立 DecodeSession 生命周期，参考 `DecodeSessionContractLab`；
- animation 采用独立时间轴、disposal/blend、frame window 和后台策略；
- HDR 采用独立 color/output ownership 与真机 EDR 证据；
- 三者不能仅靠 capability enum 存在就宣布支持。

#### AxiomRaster

本阶段不改 AxiomRaster。未来顺序固定为 bounded probe、reference still decode、shared conformance、hostile corpus、differential、resource/cancellation、opt-in adapter、shadow、format canary、真机、ImageIO fallback 演练，再考虑默认选择。

#### 跨平台

当前不为 Android/Windows/Linux/Web 建立猜测性通用 runtime。先共享：

- descriptor/schema；
- fixture/corpus；
- trace；
- conformance obligation；
- evidence format。

只有一个真实非 Apple 原型出现后，才抽取技术中立 runtime 子集。Apple 实现继续以 Swift 和系统框架为主，不为虚构可移植性牺牲当前质量。

## 6. 研究项目采用矩阵

| 项目 | 采用 | 暂不采用 |
|---|---|---|
| ImageCraft | 独立 ImageIO 规范来源、codec 契约与证据 | 继续在 Fovea 镜像中双向开发 |
| Akashic | typed cache/blob 机制与 fault evidence | HTTP、账户、revoke 业务语义下沉 |
| Afferent | W6 acquisition/resume/background 契约来源 | 当前直接依赖或替换 Fovea transport |
| ArtifactDerivationAlgebra | identity、checkpoint、rollback、publication 思想 | 通用 runtime provenance DAG |
| ImageArtifactCausalModel | 分层身份、资源生命周期、single-flight 反例 | 每个运行时对象携带完整因果记录 |
| ImageCodecCapabilityAlgebra | 有限 request/offer、refinement、义务生成 | 完整信任链进入运行时 |
| ImagePipelineResourceEnvelopeLab | 阶段化、多维资源模型 | 未校准即公开新 API |
| EvidenceCompositionAlgebra | P6/P7 scoped certificate 规则 | 标量置信分数或自动升级声明 |
| FoveaCapabilityComplexityResearch | 新抽象准入与反事实审查 | 自动复杂度评分决定合并 |
| CodecExecutionBoundaryLab | 统一语义高于执行边界、host 重验 | 默认路径引入 C ABI/WASI/XPC registry |
| DecodeSessionContractLab | 后续 progressive session 输入 | 现在冻结 production progressive API |
| HostileImageCorpusLab | 保留为待建设工作项 | 将当前占位项目当成完整 corpus |
| ImageCodecConformanceKit | 作为待重建的独立 kit 位置 | 以一行 README 宣称完成 |
| ImagePipelineWorkloadLab | 作为待建设的 workload 位置 | 替代现有 W1-W15 控制面 |
| FoveaConstitutionResearch | proposal/evidence/activation 分离 | 运行时宪法解释器或自动激活 winner |

## 7. 最近十个可执行任务

1. **P0-FOVEA-PUBLIC-ROOT**：提交并推送隐私净化、MIT、exact-pin 的单一公共根。
2. **P0-FOVEA-PUBLIC-CI**：修复首次根提交语义并让核心 required gates 全绿。
3. **P6-CODEC-CONFORMANCE-KIT**：ImageIO + 缺能力 fake backend 共用的最小独立 kit。
4. **P6-STORAGE-CONFORMANCE-KIT**：partition/generation/stage/publish/recovery 的最小独立 kit。
5. **P6-QUALIFIED-COMPOSITION-SEAMS**：新 codec 入口要求 `ImageCodec`，设计 immutable persistent-store bundle。
6. **P4-AKASHIC-PHYSICAL-EVIDENCE**：稳定设备 I/O、能耗、长期 kill 与物理断电计划。
7. **P7-A-TIER-REPIN**：重新解析并锁定 Apple、Nuke、Kingfisher、SDWebImage、PINRemoteImage。
8. **P7-CURRENT-STACK-PARETO-RERUN**：重跑 W1/W2/W3/W7/W8/W10/W13。
9. **P2-W4-W15-PLANS**：按真实生产能力和依赖顺序建立不可变实验计划。

任务 3、4、6 可并行；任务 7、8 必须在 Fovea 公共 CI 和当前组件证据稳定后执行。

## 8. 停止条件与复杂度预算

出现以下任一情况，停止新增抽象并先解决边界：

- 第三个 key/epoch/fingerprint 没有新的独立失效机制；
- 插件需要理解 URL、header、账户、UI 或物理路径；
- 默认请求需要动态 registry、服务发现或策略解释器；
- 无第二实现却建立通用 backend factory/DAG；
- store 可以单独替换，却无法共同证明 revoke/transaction；
- codec 可低报能力或资源而宿主不重验；
- 为迁移可重建缓存而引入比删除重建更复杂的兼容状态机；
- benchmark/治理代码进入热路径；
- 组件测试通过被解释为端到端组合通过。

## 9. 当前真实未知项

以下事实仍不能由代码或现有 CI 证明：

1. 稳定系统真机及第二台低性能设备的来源；
2. 物理断电实验使用的专用设备、供电控制和文件系统观测方式；
3. `xcode-27` public preview 的容量、镜像稳定性与 GA 时间；在 preview 期间必须保留显式标签、工具链身份、失败关闭与 runner provenance，不能退回 `macos-latest`；
4. 第一个真实非 Apple 验证平台是 Android、Linux、Windows 还是 Web；
5. conformance kit 的长期仓库归属与独立评估者；
6. AxiomRaster 首个满足 bounded probe + reference still decode 的格式范围。

这些未知不阻塞当前公共根和 P6 kit，但阻塞 release-ready、跨设备性能和第二 codec 默认化声明。

## 10. 最终方向

接下来的方向不是继续“做更多”，而是把已经做出的强边界变成可信产品边界：

1. ImageCraft 是唯一 ImageIO 规范来源；
2. Akashic 是唯一通用缓存机制来源；
3. Fovea 保留网络、HTTP、身份、授权、撤销、组合事务和 UI 权威；
4. 默认产品保持 ImageIO + Akashic 的安全静态组合；
5. 高级插件必须通过资格、身份、资源、故障和组合门，而不是只满足 Swift protocol；
6. 发行身份与外部依赖已经完成；先补齐回滚、跨仓 conformance 和组合证据，再扩大能力面；
7. 竞争目标采用 scoped Pareto 证书，不采用无边界“世界最好”；
8. 跨平台先共享契约与证据，等真实第二平台反向验证抽象。

这条路线比再次重构或继续增加 protocol 更慢一点，但能避免最昂贵的失败：把尚未具备发行和组合证据的本地分拆，误认为已经完成模块化。
