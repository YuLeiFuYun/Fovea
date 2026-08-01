# 图像 codec 边界研究档案（2026-07）

> **状态：Research。** 本文记录 2026-07-27 固定的上游资料、机制抽取和采用边界。它不是稳定 API 承诺，也不证明 Fovea 或未来 codec 整体优于 ImageIO、libjpeg-turbo 或其他实现。

## 1. 核心问题

真正需要回答的不是“Fovea 能否换掉 ImageIO”，而是：

> 如何让网络图片管线与编解码器分别演进，使任一方都不需要等待另一方，同时在集成时仍能证明格式、资源、取消、输出语义和缓存身份一致？

答案必须同时满足：

- codec 可以独立研究格式、算法、SIMD、硬件和安全解析；
- Fovea 可以独立推进网络、缓存、调度、UI、持久化和真实工作负载；
- 双方只通过版本化、有限、可测试的 contract 耦合；
- 未实现能力不会因“未来会支持”而进入当前生产声明。

## 2. 固定来源

| 来源 | 固定入口 | 本轮关注机制 |
|---|---|---|
| W3C WebCodecs Working Draft, 5 May 2026 | https://www.w3.org/TR/2026/WD-webcodecs-20260505/ | `isTypeSupported`、complete/progressive、frame generation、track、timestamp/duration、orientation、reset/close、资源释放 |
| JPEG XL reference implementation | https://github.com/libjxl/libjxl | ISO/IEC 18181 reference、渐进/动画/HDR/颜色、API、benchmark 与 corpus 文化 |
| libavif | https://github.com/AOMediaCodec/libavif | 可替换 codec backend、incremental/layered decode、fuzzing、coverage、CLI 与 conformance |
| jpegli | https://github.com/google/jpegli | JPEG 兼容接口、高精度内部计算、质量与速度必须分别基准化 |
| Wuffs | https://github.com/google/wuffs | memory-safe parser/codec、显式状态机、fuzz/测试、受限格式范围与成熟度边界 |
| libjpeg-turbo | https://github.com/libjpeg-turbo/libjpeg-turbo | JPEG SIMD 性能基线、API 兼容、不能代表完整多格式 codec 问题 |
| Swift SE-0392 | https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md | 自定义 actor executor 的隔离/调度边界；executor 不等于取消或 FIFO 证明 |
| Swift Concurrency Vision | https://github.com/swiftlang/swift-evolution/blob/main/visions/approachable-concurrency.md | actor reentrancy、隔离和可理解性风险 |
| OSS-Fuzz 新项目指南 | https://google.github.io/oss-fuzz/getting-started/new-project-guide/ | fuzz target、seed corpus、sanitizer、coverage、持续执行 |
| ProGIC (2026) | https://arxiv.org/abs/2603.02897 | residual vector quantization、coarse-to-fine progressive bitstream、生成式低码率方向 |
| Coarse-to-Fine (2026) | https://arxiv.org/abs/2605.08266 | 面向机器语义层级的 progressive coding，不等同于显示质量渐进 |
| Variable-Rate DIC with LoRA (2026) | https://arxiv.org/abs/2606.16107 | 单模型可变码率与参数高效适配，属于 codec 研究而非管线 API |

来源固定到 URL 与访问日期，而不是写“参考最新版”。后续若上游语义变化，应新增研究修订，不静默改写本轮结论。

## 3. 从 WebCodecs 抽取的契约机制

WebCodecs 的价值不在于复制浏览器 API，而在于它把长期容易混淆的语义拆开：

1. **支持查询与执行分离**：能否支持某类型先查询，真正 decode 仍可能失败；
2. **完整帧与渐进输出分离**：`completeFramesOnly` 明确表示调用方是否接受降低细节的输出；
3. **同帧代次**：后续 progressive generation 必须增加细节，不能把任意 preview 当成可替换结果；
4. **轨道与帧索引**：静态主图、动画轨道和帧时间轴不是一个布尔 `isAnimated` 可以完整表达；
5. **timestamp/duration/orientation**：显示语义是 decode result 的一部分；
6. **reset 与 close**：取消 pending work、释放 codec resource 和永久关闭是不同生命周期事件。

Fovea 本轮采用这些分解思想，但没有复制 Promise/ReadableStream/VideoFrame，也没有声称达到 WebCodecs 的渐进/动画行为。

## 4. 现在采用的机制

### 4.1 有限能力协商

包内 `ImageCodecDescriptor` 只表达 Fovea host 真正需要用于准入、身份和测试的有限能力。它比自由扩展字典更不灵活，但可哈希、可序列化、可穷举。跨仓库共享的是技术中立 schema、fixture 和 oracle，不是当前 Swift package-internal 类型；这避免在只有一个生产后端时冻结 public ABI。

### 4.2 后端事实与 host 策略分离

codec 负责：

- 有界 probe；
- 后端能力事实；
- 后端 working-set 估计；
- 像素/metadata 输出；
- prepared state 的创建、消费和释放。

Fovea 负责：

- 网络与字节边界；
- namespace/authorization；
- shared work、priority 和 cancellation propagation；
- 通用资源下界和全局预算；
- cache identity 与持久提交；
- UI 生命周期和展示策略。

### 4.3 保守资源合并

后端估计是额外事实，不是 host 预算的替代物。`max(generic, backend)` 能抵御低报，也避免把两个本来描述同一峰值的估计相加而系统性双重计费。未来若 codec 提供分阶段内存曲线，需要新 contract 和对应证明，不能偷偷改变当前字段含义。

### 4.4 版本化像素身份

后端、实现版本和 contract 版本进入 decode/render identity。否则 shadow decode、A/B、canary 或回滚时可能把 A 后端像素当成 B 后端命中。

### 4.5 fail-closed 与独立错误代数

能力缺失、无效时间轴、无效资源估计和容器损坏不是同一错误。稳定分类使策略、诊断和测试不依赖后端自由文本。

### 4.6 conformance-first

未来 codec 的第一项 Fovea 集成工作不是“接入一个真实图片”，而是运行相同的 capability、identity、resource、probe consistency 与 lifecycle 契约测试。产品接入在 conformance 之后。

## 5. 已保留但尚未实现的能力

以下类型已经存在，是为了冻结语义词汇，不是生产实现声明：

| 能力 | 当前类型/契约 | 仍缺少的生产机制 |
|---|---|---|
| Progressive generations | `ImageProgressiveGeneration`、delivery mode | 累计字节上限、增量 parser、generation stream、preview cadence、共享/取消、final identity、UI promotion |
| Animated sequence | track mode、`ImageFrameTiming` | track enumeration、loop/disposal/blend、decode window、frame cache、clock、visibility/background/Reduce Motion |
| HDR | metadata 与 dynamic-range capability | transfer/primaries/matrix、platform surface、tone mapping、EDR display、cache identity 完整化、真机证据 |
| Pixel buffer / planar output | output representation | ownership、stride/alignment、lifetime、GPU/CPU synchronization、zero-copy 可证伪条件 |
| Interruptible cancellation | cancellation mode | codec 内部中断点、线程/任务安全、资源回收时限、取消后状态可重用性 |
| Backend selection | descriptor | registry、policy、format/feature scoring、failure fallback、shadow mode、rollout governance |

这些能力不得因为 enum 已存在就从 W4/W5/W9 gap 中移除。

## 6. libjxl、libavif、jpegli、libjpeg-turbo 与 Wuffs 的启示

### 6.1 libjpeg-turbo 是重要基线，但不是完整目标函数

libjpeg-turbo 对 JPEG SIMD、吞吐和成熟 API 极有价值。但“比 libjpeg-turbo 更强”必须拆成向量，而不是单一排名：

```text
format breadth
standards conformance
malformed-input safety
lossless/lossy fidelity
rate-distortion / perceptual quality
encode/decode latency
throughput
peak RSS / temporary allocation
progressive / animation / HDR / metadata
cancellation and streaming
portability and operational observability
```

一个 codec 可能在质量或格式上更强，却在 JPEG decode throughput、生态稳定性或 CPU 能耗上更弱。没有同设备、同 corpus、同参数和置信区间，不能发布总体超越结论。

### 6.2 jpegli：兼容面与内部实现可以解耦

jpegli 表明兼容 JPEG bitstream/API 与更高精度内部处理、不同 rate-distortion 选择并不矛盾。对未来 codec 的启示是：外部 contract 应稳定，内部算法、精度和 SIMD 可以迭代；每次改变输出语义时必须更新 implementation fingerprint。

### 6.3 Wuffs：安全来自受限状态机和工具链，不来自语言标签

Wuffs 强调 memory safety、显式状态、测试和 fuzzing，但也明确其格式范围与成熟度边界。Fovea 不应假设“使用安全语言”即可自动抵御 decompression bomb、逻辑越界、资源耗尽、无限循环或语义差异。

### 6.4 libjxl/libavif：渐进、分层和插件后端需要完整生态

成熟 codec 工程不仅有核心算法，还包括 CLI、benchmark、reference corpus、fuzz target、sanitizer、coverage、跨平台 CI 和版本化 API。Fovea 的接入门必须评价整套可运行资产，而不是只看一个 decoder 函数。

## 7. 2026 前沿论文：可研究，不应泄漏进当前 Fovea contract

### ProGIC

Residual vector quantization 可自然产生 coarse-to-fine bitstream，并针对低码率感知质量和轻量模型优化。它适合作为未来 codec 的实验 lane，但引入了模型权重、确定性、CPU/GPU 部署、供应链、训练数据和生成细节真实性问题。

### Coarse-to-Fine semantic codec

该工作优化的是机器分类的语义层级可扩展性。它说明“progressive”可能有完全不同的目标函数：用户视觉预览、机器粗分类、ROI 或可编辑层。Fovea 的 UI progressive API 不应预设 codec 的 semantic hierarchy，更不应把机器任务准确率等同于显示质量。

### LoRA variable-rate compression

单模型多码率与参数高效适配可能降低模型存储和训练成本，但其 rate control、模型版本、可重复性和设备适配仍属于 codec 项目。Fovea 只需要接收明确的 codec identity、能力与资源事实，不应感知 LoRA 或训练方法。

## 8. hostile-input 与 fuzzing 要求

未来 codec 至少需要以下独立层次：

1. parser/probe fuzz：长度、offset、整数溢出、递归、chunk/order、metadata；
2. full decode fuzz：像素维度、frame count、progressive state、取消、重复 reset/close；
3. differential corpus：与规范参考、ImageIO、libjpeg-turbo/libjxl/libavif 中适用实现比较；
4. metamorphic：分块方式、线程数、输入 padding、metadata 排序不应改变规定结果；
5. resource oracle：在硬上限下不能先分配后失败；
6. sanitizer：ASan/UBSan/MSan/TSan 按语言和平台可行性执行；
7. seed corpus 与 coverage：正常、边界、历史 CVE、人工生成和 held-out corpus 分离。

Fovea host 仍需验证 codec 声明，不能把 codec fuzz 通过当作 host admission 正确性的替代证据。

## 9. Swift executor 与取消边界

将同步 ImageIO/codec 工作隔离到专用 executor 可以避免占用 Swift cooperative executor，但它不自动提供：

- 正在运行的 C/C++ decode 可中断；
- 严格 FIFO 或优先级继承；
- actor 不重入；
- prepared state 自动释放；
- 线程安全的 codec instance 复用。

因此 contract 把取消保证显式区分为 operation-boundary 与 interruptible；Fovea 在调用前后检查取消，只有未来后端确实有内部中断点时才能升级声明。

## 10. 当前证据边界

本轮已经证明的是：

- 当前有限 capability algebra 的可执行性质；
- ImageIO 适配器的保守声明；
- format/probe、resource lower bound、prepared-state cleanup 与 identity separation；
- Fovea 可以在不重写 fetch/cache/persistence 的情况下携带 backend fingerprint。

尚未证明的是：

- 新 codec 的任何真实格式、正确性、质量或性能；
- progressive/animation/HDR 的生产集成；
- 真机能耗、峰值 RSS、GPU/CPU 调度；
- 恶意 corpus 的全面性；
- 任一总体 superiority claim；
- 自动 backend selection 的正确性或最优性。

这些缺口由并行路线图和项目记忆继续追踪。
