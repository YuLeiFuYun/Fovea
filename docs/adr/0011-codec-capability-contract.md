# ADR-0011：版本化图像 codec 能力契约与保守准入

- **状态：Accepted；公共可见性与装配边界由 ADR-0012 修订**
- **日期：2026-07-27**

## 背景

图像后端需要同时提供 probe/decode、稳定身份、有限能力声明和保守资源估计。只依赖最低 `ImageDecoding` 无法安全承载多个 codec：

1. 不同后端可能对相同字节产生不同颜色、方向、动态范围或像素表示，却碰撞到同一共享/缓存身份；
2. “能识别容器”会被误当成“能提供渐进代次、动画时间轴、HDR、指定输出表示或可中断取消”；
3. 后端若低报峰值工作集，可能削弱管线分配前预算；
4. 未来 codec 若直接替换 ImageIO，fetch、cache、admission、identity、display 与 persistence 会被迫跟着重写；
5. 只用 feature flag 或文档说明能力，无法形成可执行的 fail-closed 边界。

用户正在独立开发新的图像编解码器。Fovea 必须在该项目尚未完成时继续演进，并在 codec 完成后通过稳定接缝接入，而不是等待或预设其内部实现。

## 决策

1. `ImageCraftCore` 公开版本化 `ImageCodecDescriptor`。`ImageDecoding` 仍是 ImageCraft 内可复用的最低 probe/decode 协议，但 Fovea 的生产、package 和系统组合入口只接受完整 `ImageCodec`。descriptor 身份由以下三部分组成：
   - 后端稳定标识 `identifier`；
   - 像素/元数据语义变化时递增的 `implementationVersion`；
   - Fovea codec 契约变化时递增的 `contractVersion`。
2. descriptor 明确声明有限能力集合：
   - 容器格式；
   - 完整帧或渐进代次；
   - 主帧或动画序列；
   - orientation、source color、HDR、frame timing 元数据；
   - SDR/HDR；
   - `CGImage`、pixel buffer、planar pixels 输出；
   - 只在操作边界观察取消，或真正可中断后端工作。
3. 调用方把所需语义表示为 `ImageDecodeCapabilityRequest`。后端必须在任何像素分配和 working-set reservation 前通过能力协商；缺口返回稳定、可枚举的 `ImageCodecSupportFailure`，然后映射为结构化 `PipelineFailure`。
4. Fovea 不为仅实现 `ImageDecoding` 的后端合成 descriptor 或资源估计；缺少完整 `ImageCodec` 契约的实现不能进入 Fovea 组合。
5. ImageIO 适配器当前只声明已经由实现和测试兑现的能力：PNG/JPEG/GIF 容器探测、完整主帧、orientation/source color、SDR、`CGImage`、操作边界取消。它不声明 progressive、animated timeline、HDR、planar output 或 interruptible cancellation。
6. working-set 准入采用：

   ```text
   W_admit = max(W_generic, W_backend)
   ```

   两个估计都必须为正；后端低报不能降低通用下界，无效估计 fail closed。
7. `DecodeKey`/`RenderKey` 同时包含 contract version 与 `identifier + implementationVersion + contractVersion` 组成的 fingerprint。任何可能改变像素、颜色、方向、元数据解释或 capability 语义的版本变化都必须改变身份。
8. 渐进输出以严格递增的 `ImageProgressiveGeneration` 表示：只有 `g_new > g_previous` 才能替换已经发布的同帧结果。动画时间以无溢出的 timestamp/duration 值类型表示。当前只建立值语义，不宣称生产 pipeline 已支持渐进或动画。
9. codec 契约错误使用独立 `ImageCodecContractError`，不把能力协商、无效时间轴和无效资源估计混入容器解析错误。
10. Fovea 继续由 `DecodeStage` 负责调度、优先级、共享任务、预算和生命周期；codec 只负责有界 probe/decode 及后端事实。codec 不获得网络、cache namespace、用户身份或持久提交权限。
11. 跨仓库 conformance kit 使用独立 fixture manifest、行为 oracle 和失败 taxonomy。外部 codec 只需依赖独立 `ImageCraftCore` 产品，不导入 Fovea 网络、缓存或 UI 模块；公共 bridge、默认装配和缓存插件政策由 ADR-0012 定义。

## 数学与可执行不变量

令请求为 `r`，能力集合为 `C`：

```text
supports(C, r)
= format(r) ∈ formats(C)
∧ delivery(r) ∈ deliveryModes(C)
∧ track(r) ∈ trackModes(C)
∧ metadata(r) ⊆ metadata(C)
∧ range(r) ∈ dynamicRanges(C)
∧ output(r) ∈ outputs(C)
∧ cancellation(r) ≤ cancellation(C)
```

当前有限域上验证以下性质：

- **能力单调性**：若 `C1 ⊆ C2`，则 `supports(C1, r) ⇒ supports(C2, r)`；
- **代次严格序**：替换关系不可自反，并满足传递性；
- **资源合并上界**：`max` 对两个估计均单调、交换、幂等，且不发生算术加法溢出；
- **身份分离**：后端标识、实现版本或契约版本任一变化，fingerprint 都变化；
- **probe/decode 一致性**：生产适配器探测出的格式必须属于其 descriptor 声明的格式集合；
- **释放义务**：能力、估计、准入、取消或 decode 任一失败后，一次性 prepared state 不得遗留。

这些是当前有限契约的局部性质，不构成所有未来格式、所有资源模型或端到端全局最优证明。

## 被拒绝的替代方案

### 直接用新 codec 替换 ImageIO

拒绝。它会把 codec 成熟度与 Fovea 的网络、缓存、UI 和持久化演进锁在一起，并使故障时只能整体切换整条图像管线。

### 只保留一个最低公分母 `decode(data) -> CGImage`

拒绝。它无法表达渐进、动画、HDR、输出表示、取消和资源事实，最终会重新引入隐式能力与运行时猜测。

### 使用 `[String: Any]` 或自由文本 metadata

拒绝。无法稳定哈希、序列化、穷举测试，也无法形成跨仓库 conformance kit。

### 完全信任后端 working-set 估计

拒绝。插件式后端可能低报、溢出或返回无效值；准入必须保留 host 的通用下界。

### 现在就实现 backend registry、自动选择和 fallback 链

拒绝。当前只有一个生产后端；在第二个 conforming backend 与对照数据出现前引入策略层属于过早设计。descriptor 先解决身份和能力事实，选择策略以后由证据驱动。

## 后果

- Fovea 可以继续使用独立 ImageIO 产品，同时未来 codec 先对技术中立 conformance kit 验证，再直接遵循明确的公共 contract；
- 不同后端由 `codecContractVersion + codecFingerprint` 隔离，不会共享错误像素；
- 未实现能力在分配前被拒绝，而不是在深层路径失败；
- 后端仍可拥有 prepared state、SIMD、硬件或专有内存布局，但不得把这些实现细节泄漏到 fetch/cache/UI；
- contract 增加了版本治理责任：语义变化而不递增版本会造成缓存污染；
- Fovea 不接受缺少 descriptor、capability 和 resource estimate 的后端；公共 contract 继续受 API review 与 contract version 治理；
- progressive/animation/HDR 类型的存在不是生产能力声明。

## 验证

- `ImageCodecContractTests` 验证支持判定、superset 单调性、失败优先级、资源上界和 identity 分离；
- `ImageCodecConformanceTests` 在当前有限域穷举 2,304 个 capability request，并用独立 oracle 比较；
- Python model checker 穷举 capability、generation、resource join 与 timing 边界；
- ImageIO PNG/JPEG/GIF probe 结果必须属于 descriptor；
- 不支持能力、无效资源估计和后端低报均在 decode 前失败；
- preparation 在所有失败路径释放；
- 完整 Swift 测试套件与项目数学 gate 持续执行。

## 可执行需求映射

以下 ID 是本 ADR 的当前可执行契约；测试追踪清单给出精确文件与方法：

- **CODEC-PT-001**：ImageIO descriptor 只声明当前能够兑现的能力。
- **CODEC-PT-002**：能力不匹配在像素解码前失败，并释放一次性 preparation。
- **CODEC-PT-003**：后端低报 working set 不能削弱通用资源下界。
- **CODEC-PT-004**：当前有限 capability 域与独立 membership oracle 一致。
- **CODEC-PT-005**：未实现的 progressive delivery 在 capability negotiation 中按稳定优先级失败，不保留虚构的 generation ordering 类型。
- **CODEC-PT-006**：ImageIO probe 得到的容器格式属于其 descriptor 声明。
- **CODEC-PT-007**：progressive、animation、HDR 和未实现输出表示均失败关闭。
- **CODEC-PT-008**：无效后端资源估计在 decode 前转化为稳定 contract failure。
- **CODEC-MATH-001**：有限模型穷举 capability、generation、resource join 与 timing 边界。
