# Fovea Codec-Readiness 深度审查与改进报告（2026-07）

> **状态：Implemented local evidence / release claim forbidden；插件可见性由 ADR-0012 修订。** 本报告审查的是 2026-07-27 的脏工作树，并明确区分本轮新增改动与此前已存在的大规模未提交工作。未执行 reset、discard、commit、tag 或 push。

## 1. 核心判断

Fovea 原有网络、HTTP 语义、namespace、持久提交、目标像素准入和测试治理已经形成较强局部结构，但其解码边界仍隐含“只有 ImageIO、只有完整静态主帧、所有后端共享 decoderVersion 1”的假设。这个假设是未来独立 codec 接入的主要架构阻力，也比再增加若干图像格式或优化函数更优先。

本轮没有直接建立一个“万能 codec 抽象层”，而是完成最小、可证明、可扩展的 seam：

```text
public ImageCraftCore codec contract
+ finite capability request
+ bounded probe facts
+ conservative resource estimate
+ prepared/decode lifecycle
+ backend-specific cache identity
+ stable failure taxonomy
+ cross-backend conformance tests
```

结果是：Fovea 可以继续以 ImageIO 为参考后端推进网络、缓存、调度、UI 和持久化；未来 codec 可以独立实现 parser、decode、encode、progressive、animation、HDR、SIMD 或 learned compression，只依赖 `ImageCraftCore` 并通过技术中立 conformance kit。早期版本曾因 API 规模将完整 contract 收缩为 package access；ADR-0012 根据明确的 AxiomRaster/第三方插件目标重新公开该 seam，并以精确 DocC 预算、独立 ImageIO product 和缓存插件契约约束增长。

这证明 Fovea 已具备显式注入公共 codec 的 host 边界，但不证明 AxiomRaster 已完成，更不证明任一后端整体优于 ImageIO/libjpeg-turbo。默认迁移仍受 conformance、真机性能、资源、安全和 rollout gate 约束。

## 2. 基线与审查方法

### 2.1 脏工作树保护

开始时仓库已有约 28 GB 工作目录，其中 `.artifacts` 约 23 GB、`.build` 约 2.4 GB，并有大量已修改、已暂存和未跟踪文件。本轮：

- 冻结了开始时的 status、staged/unstaged binary diff 与 tracked/nonignored file digest manifest；
- 将所有既有改动视为受保护基线；
- 不使用 `git reset`、`git checkout --`、`git clean`、commit、tag 或 push；
- 所有候选先在排除 `.build/.artifacts/.workflow` 的 shadow worktree 验证，再交由 workflow 控制器做 SHA/write-scope/command 验证。

### 2.2 审查维度

- 架构职责与依赖方向；
- cache/shared-work identity；
- 资源准入与 hostile input；
- concurrency、cancellation 与 prepared-state 生命周期；
- 数学不变量和独立 oracle；
- ImageIO 当前事实与未来 codec 能力；
- 文档、测试、研究和路线图一致性；
- workflow-bundle 在超大脏仓库上的控制面可靠性。

### 2.3 来源

研究档案固定了 W3C WebCodecs 2026 Working Draft、libjxl、libavif、jpegli、Wuffs、libjpeg-turbo、Swift SE-0392、Swift concurrency vision、OSS-Fuzz，以及 2026 progressive/learned compression 论文。详见 `image-codec-boundary-research-2026-07.md`。

## 3. 主要发现

### F-01：不同 codec 会碰撞到同一 DecodeKey/RenderKey

旧路径在 `DecodeStage` 与 `ImageDeliveryCoordinator` 中写死 `decoderVersion = 1`。如果未来 codec 与 ImageIO 对颜色、方向、精度或 metadata 的解释不同，相同 bytes/request 仍可能复用错误派生像素。

**修复：** descriptor 的 identifier、implementation version、contract version 组成 fingerprint，并同时进入 decode/render identity。

### F-02：能力由类型转换和实现惯例隐式决定

仅有 `ImageDecoding` 的 probe/decode 不足以进入 Fovea；所有后端必须通过 `ImageCodec` 显式声明 prepared 之外的能力、资源、输出与取消语义。

**修复：** 有限 capability algebra；调用方显式提出 request；在像素分配前 fail closed。Fovea 只接受完整 `ImageCodec`，缺少能力或资源契约的后端在组合边界被拒绝。

### F-03：后端 working-set 事实没有进入统一准入

旧管线只使用通用估计，未来 backend 可能需要更大 scratch；若改成完全信任 backend，又会产生低报绕过 hard limit 的风险。

**修复：** `W_admit = max(W_generic, W_backend)`，无效估计 fail closed。该运算避免低报，也避免对同一峰值双重相加。

### F-04：prepared state 的释放义务未与 capability/resource failure 一起建模

一旦在 probe 之后增加 capability 或 backend estimate，新的失败点会扩大 prepared-state 泄漏面。

**修复：** capability、estimate、admission、cancel、decode 的所有失败路径都显式 discard；新增 fake backend 测试证明能力不匹配与低报时 decode 未执行、prepared 已释放。

### F-05：渐进、动画、HDR 容易被“类型存在”误记为“功能存在”

接口若直接加入 `progressive`、`animated` 字段，项目状态可能错误地关闭 W4/W5 gap。

**修复：** 值类型只冻结词汇和不变量；ImageIO descriptor 明确不支持 progressive generations、animated timeline、HDR、pixel-buffer/planar output 与 interruptible cancellation；project memory 保留 capability gaps。

### F-06：总体“强于 ImageIO/libjpeg-turbo”不是可验证命题

format breadth、正确性、安全、rate-distortion、感知质量、吞吐、tail latency、peak RSS、能耗、渐进、动画、HDR、可移植性可能互相冲突。

**决策：** 只允许逐格式、逐设备、逐 corpus、逐参数和逐指标的有界结论；默认切换需要 preregistered comparative evidence，不能从单一维度推出整体 superiority。

### F-07：workflow-bundle 会被超大 ignored tree 拖垮

旧 `working_tree_digest` 递归读取整个目录，纳入 `.artifacts` 与 `.build`，对 Fovea 约 28 GB/25 万文件执行无关哈希。

**修复：** Git 仓库使用 `git ls-files --cached --others --exclude-standard` 作为 reviewable set，fallback 明确忽略生成目录，并添加回归测试。

### F-08：workflow-bundle 把质量基线无条件注入 PLAN

1.27 MB `quality-baseline.json` 使单次 planning prompt 达到约 1.68 MB/127 万输入 token，并返回空结果。

**修复：** authority context 按 PLAN/IMPLEMENT/REFACTOR 分阶段；PLAN prompt 降到约 235 KB/10.7 万 token。

### F-09：形式 traceability 不能保证语义 traceability

自动 planner 的第一个 DAG 覆盖了全部 requirement ID，却把 codec boundary 映射为 persistence tests，把研究/路线图映射为无关脚本。控制器的 ID 覆盖率为真，任务语义仍然错误。

**处置：** 在任何 Fovea patch 落盘前终止该 DAG，通过 objective amendment 归档旧 action/DAG/certificate，改为 requirement→artifact 显式绑定的五阶段 DAG。该负面结果已进入 registry；workflow-bundle 后续仍需加入语义映射约束。

### F-10：动态 output schema 变化未使旧模型结果缓存失效

强化 schema 后，supervisor 曾复用旧 action 的历史结果，直到生成新 action 才生效。

**状态：** 已确认，仍需在 workflow-bundle 中把 specialized schema digest 纳入 result reuse key；不得把当前绕过方式当成完成修复。

## 4. 已实现的生产改进

### 4.1 `ImageCodecContract`

新增：

- `ImageCodecIdentifier`；
- complete/progressive delivery；
- primary/animated track；
- orientation/source color/HDR/frame timing metadata；
- SDR/HDR；
- CGImage/pixel buffer/planar output；
- operation-boundary/interruptible cancellation；
- strict progressive generation；
- checked frame timing；
- capability request/capabilities/failure；
- versioned descriptor/fingerprint；
- independent contract error；
- conservative resource estimate。

### 4.2 ImageIO reference adapter

只声明当前已验证语义：

```text
formats: PNG / JPEG / GIF
output: complete primary frame
metadata: orientation / source color
range: SDR
representation: CGImage
cancellation: operation boundary
```

GIF 多帧可探测不等于动画 timeline 已实现；ImageIO incremental API 存在不等于 Fovea progressive pipeline 已实现。

### 4.3 Pipeline integration

- probe 后、working-set reservation 前进行 capability negotiation；
- backend resource estimate 在 blocking executor 上执行；
- host/backend 估计取最大值；
- 取消在 estimate/admission 前后观察；
- contract failure 映射为稳定 `PipelineFailure`；
- shared decode/render identity 携带相同 codec fingerprint；
- 所有新失败点释放 preparation。

## 5. 数学化与测试

### 5.1 支持谓词

```text
supports(C, r)
= format ∈ C.formats
∧ delivery ∈ C.delivery
∧ track ∈ C.tracks
∧ requiredMetadata ⊆ C.metadata
∧ range ∈ C.ranges
∧ output ∈ C.outputs
∧ requestedCancellation ≤ C.cancellation
```

### 5.2 可执行性质

- capability superset monotonicity；
- deterministic first failure；
- generation irreflexive/transitive strict order；
- resource max monotone/commutative/idempotent；
- frame timing nonzero duration/no overflow；
- backend fingerprint separation；
- probe format contained in descriptor；
- unsupported reserved semantics fail closed；
- invalid/underreported resource estimate fails before decode；
- prepared state cleanup。

### 5.3 穷举规模

Python model checker 当前穷举：

- capability request：2,304；
- progressive generation triples：262,144；
- resource joins：49；
- timing boundaries：25；
- errors：0。

Swift conformance suite 使用独立 membership oracle 穷举同一 2,304 request 域。

### 5.4 本地验证

最终文档前的 shadow/真实工作树验证达到：

- Swift tests：476/476；
- codec model：全部通过；
- project mathematical proof gate：通过；
- Release/build、项目原生治理门仍由最终任务和现有 `scripts/verify.sh` 负责；
- 真机、稳定 iOS、低性能设备、外部网络和独立 evaluator 不在本地证明范围。

曾发生两类失败，均保留而非隐藏：

1. task 1 的第一次切分把新 `ImageCraftError` case 留给下一任务，导致 exhaustive switch 编译失败；改为独立 contract error algebra；
2. task 2 首次真实 suite 唯一失败是既有 SharedTask cancellation timing test，目标单测和全套立即复跑通过，candidate 在 shadow 也全绿，按诊断证据重试后通过；
3. 最终 loopback 门暴露了灰度+Alpha 光栅被直接重标为 RGB sRGB 的错误假设。Core Graphics 拒绝跨颜色模型重建，导致 probe 成功而 raster 后处理失败。现改为同模型重标、跨模型有界转换，并用有效灰度 PNG 同时覆盖直接解码和 loopback。

## 6. 架构评价

### 6.1 已改善

- codec 与 host 的职责边界明确，且未把未验证的 capability vocabulary 冻结为 Stable public API；
- 未来后端不会自动污染当前 cache identity；
- 能力事实进入分配前准入；
- 资源和取消不再依赖模糊惯例；
- progressive/animation/HDR 有稳定词汇但不夸大实现；
- conformance kit 已有同仓库基线；
- 文档、研究、ADR 和 roadmap 与代码一致。

### 6.2 仍不应声称“世界最好”

- 公共 API 尚未稳定；
- 第二个真实 backend 尚不存在于 Fovea；
- conformance kit 尚未抽成跨仓库产品；
- W4/W5/W6/W9 等关键 workload 未完成；
- 真机性能、能耗、峰值 RSS 和 held-out corpus 未形成；
- fuzz/sanitizer 主要是路线图要求，未来 codec 尚无证据；
- 自动 backend selection、shadow decode、canary/default rollout 未实现。

## 7. 后续优先级

1. **抽取 conformance kit**：让 ImageIO 和未来 codec 在各自仓库运行同一测试，不依赖 Fovea 私有类型；
2. **codec C1/C2**：有界 parser/probe + scalar/reference still decode，先 correctness/fuzz 再 SIMD；
3. **Fovea 持续推进 W1-W3 与 host 质量**：不等待 codec；
4. **第二 backend 通过 kit 后再做 registry**：确定性、显式 opt-in、可关闭；
5. **shadow decode**：不影响用户输出，独立资源预算，形成 differential/quality/performance 数据；
6. **按能力推进 W4/W5/HDR**：每项有独立 pipeline、corpus、真机和 rollback gate；
7. **默认切换**：只按格式/设备/版本的有界证据推进，保留 ImageIO reference path。

详细工作包、依赖和门禁见 `docs/roadmaps/fovea-codec-parallel-roadmap.md`。

## 8. 本轮明确未做

- 未接入用户正在开发的 codec；
- 未实现 encoder；
- 未实现生产 progressive stream、动画播放、HDR surface 或 backend registry；
- 未运行公网/真机比较；
- 未关闭 W4/W5/W6/W9 capability gaps；
- 未提交、打 tag 或推送 Git；
- 未把 476 个本地测试等同于 release、world-best 或 superiority 证据。
