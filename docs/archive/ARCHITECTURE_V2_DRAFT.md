# Fovea 图片加载系统 · 前瞻架构设计 V2

> **状态**：Proposed。核心方向已收敛，公共协议须经 Phase 0 原型与真机基准验证后才能进入 Accepted。
>
> **目标**：构建一套面向 Apple 平台的高性能图片加载系统。它不仅要正确解决今天的网络图片加载、解码、缓存和显示问题，还要能够吸收学习型编码、感知质量、异构计算、可信媒体、HDR/空间图片等正在成熟的技术，而不让这些能力污染基础热路径。
>
> **平台基线**：iOS/iPadOS 15、macOS 12、watchOS 8、tvOS 15、visionOS 1。较新的系统能力通过运行时 capability detection 或独立可选插件启用。
>
> **语言与工具链**：Swift 6 严格并发；Swift Package Manager；Apple 平台专属。

---

## 0. 核心判断

一个“顺应时代”的图片库，不等于把 AI、超分、智能裁剪和最新 codec 全部塞进核心。真正具有预见性的架构应做到：

1. **稳定核心只依赖确定性语义**：来源、内容身份、目标像素、缓存、调度、解码和显示必须在没有任何模型时完整可用。
2. **前沿能力通过能力协商与策略接入**：AI 可以给出建议、生成候选方案或提供新 codec，但不能绕过身份、缓存、安全和资源预算。
3. **所有改变输出内容的算法都必须进入身份键**：模型版本、算法参数、运行后端和语义类别必须可追踪，避免缓存污染和不可复现。
4. **所有学习型决策都必须有确定性回退**：模型缺失、设备不支持、热压力过高或结果置信度不足时，系统退回稳定策略。
5. **研究成果必须经过工程毕业流程**：论文复现、真机成本、安全边界、回退策略、可观测性和维护承诺缺一不可。

因此，Fovea 的长期定位不是“带 AI 的图片加载器”，而是：

> **一个面向多表示、感知自适应、可信且资源受控的视觉资产交付管线。**

“视觉资产”在本项目中仍限定为静态图、动图及其附属平面，不扩张为视频播放器、生成式图片工具或数字资产管理系统。

---

## 1. 架构原则

### 1.1 不产生不需要的像素

目标尺寸解码、区域解码、低质量预览和渐进细化优先于全尺寸解码后缩放。所有后续优化都不能违反这一原则。

### 1.2 URL 不是内容身份

URL、请求头和认证域决定如何获取候选表示；真正的内容身份来自响应记录与内容摘要。HTTP validator 不是内容摘要，`Vary` 也不是请求前即可完整确定的字段。

### 1.3 加载是阶段图，不是单一线性任务

相同来源、不同目标尺寸或不同处理链的请求，应在可共享阶段合并，在语义发生分歧的阶段分叉。

### 1.4 策略与机制分离

传输、解码、缓存存储是机制；表示选择、预取、准入、增强和计算后端选择是策略。策略可以升级甚至由模型辅助，机制不能被策略隐式改写。

### 1.5 资源是多维预算

系统同时管理网络字节、磁盘 I/O、内存、CPU、GPU、ANE、能耗和交付截止时间，而不是只控制“最大并发数”。

### 1.6 前沿能力必须可拔除

移除 FoveaAdaptive、FoveaTrust、实验 codec 或智能处理模块后，基础加载、缓存和 UI 集成仍应完全工作。

### 1.7 安全与真实性是一等需求

图片是外部不可信输入；AI 时代还需要处理来源证明、变换记录、模型供应链和内容语义变化。安全不能作为发布前补丁。

---

## 2. 项目群与成熟度边界

维持三个生产仓库，并增加一个不进入生产依赖图的研究工作区。

```text
ImageCraft   图像容器、编解码、处理和辅助平面
Akashic      通用缓存与持久化引擎
Fovea        来源解析、表示选择、加载 DAG、HTTP、调度和 UI
FoveaLab     论文复现、实验 codec、模型与策略原型；生产仓库不得依赖
```

### 2.1 ImageCraft

```text
ImageCraftCore
ImageCraftImageIO
ImageCraftProcessing
ImageCraftAnimation
ImageCraftAuxiliary
ImageCraftTesting

可选插件：
ImageCraftAVIF
ImageCraftJXL
ImageCraftSVG
ImageCraftJPEGAIExperimental
```

职责：

- 格式探测与安全限制；
- 目标尺寸、区域和增量解码；
- 编码与目标尺寸衍生物生成；
- 规范化变换计划和后端执行；
- 动图容器与帧调度；
- HDR gain map、深度、视差、matte、立体图等辅助数据；
- codec capability 描述。

ImageCraft 不知道 URL、HTTP、缓存实现和 UI 生命周期。

### 2.2 Akashic

```text
AkashicCore
AkashicMemory
AkashicDisk
AkashicTraceKit
AkashicTesting
```

职责：

- 通用键值存储；
- 以字节和重算成本为基础的缓存管理；
- content-addressed blob store；
- SQLite WAL 元数据和崩溃恢复；
- namespace、quota、TTL 和隐私清理；
- 可回放访问 trace；
- 策略候选的离线评估。

Akashic 不知道图像、URL、HTTP、用户界面和处理器。

### 2.3 Fovea

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

可选：
FoveaAdaptive
FoveaTrust
FoveaPlaceholders
FoveaVisionCrop
FoveaRasterStoreExperimental
```

职责：

- ImageIntent、DisplayContext 和表示候选；
- 来源加载与 HTTP 语义；
- 阶段 DAG、single-flight、取消和优先级；
- 资源预算与质量阶梯；
- ImageCraft 与 Akashic 的组合；
- UI 生命周期和可见性信号；
- 可观测性与可复现实验接口。

### 2.4 FoveaLab

FoveaLab 是研究孵化区，不发布稳定产品，不被生产仓库依赖。适合：

- JPEG AI、学习型 codec 和 sandwich compression 原型；
- 学习增强缓存、预取和表示选择；
- 端侧超分、修复、感知质量模型；
- 新 Vision/Core ML API 的试验；
- 论文复现和设备成本评估。

实验能力只有满足“毕业标准”后才迁移到生产仓库。

---

## 3. 研究能力毕业标准

任何前沿技术进入生产模块前，必须依次通过：

1. **可复现**：论文或标准结果能在公开数据集与固定脚本中复现。
2. **真机可行**：在最低支持设备和当前主流设备上测量冷启动、峰值内存、能耗和尾延迟。
3. **能力边界明确**：以 capability 或 policy 接口接入，不要求核心感知具体模型。
4. **确定性回退**：模型不可用、超时、低置信度或资源紧张时有明确退路。
5. **身份完整**：凡改变输出像素或语义的能力，其实现与模型 fingerprint 进入缓存键。
6. **安全可控**：输入限制、模型签名、错误处理和恶意样本测试完整。
7. **可观测**：能够回答何时启用、为什么启用、耗费多少、结果来自哪个版本。
8. **维护承诺**：具备持续更新模型、codec 或原生依赖的责任边界。

成熟度标签：

```text
Research      仅 FoveaLab
Experimental  可选产品，API 可破坏
Incubating    API 基本稳定，默认关闭
Stable        兼容性与性能承诺
Deprecated    有迁移方案
```

---

## 4. 从 ImageRequest 升级为 ImageIntent

传统图片库通常把请求建模为 URL 加处理参数。Fovea 将调用者真正需要的结果建模为 `ImageIntent`，具体字节表示可由策略选择。

```swift
public struct ImageIntent: Sendable, Hashable {
    public let source: ImageSource
    public let display: DisplayContext
    public let objective: DeliveryObjective
    public let transform: TransformIntent
    public let cachePolicy: CachePolicy
    public let trustPolicy: TrustPolicy
    public let enhancementPolicy: EnhancementPolicy
}
```

### 4.1 DisplayContext

```swift
public struct DisplayContext: Sendable, Hashable {
    public let targetPixels: PixelSize
    public let contentMode: ContentMode
    public let displayScale: Double
    public let colorGamut: ColorGamut
    public let dynamicRange: DynamicRangePreference
    public let edrHeadroom: Double?
    public let viewport: NormalizedRect?
}
```

它描述显示目标，而不是某个 UIKit/AppKit 控件。

### 4.2 DeliveryObjective

```text
interactive       首个可用结果和滚动稳定性优先
balanced          默认平衡
fidelity          最终质量优先
backgroundPrefetch 网络和能耗友好，默认不解码最终位图
analysis          为机器处理请求元数据或特定表示
```

目标可以内部转换为多维预算，而不是向普通用户暴露几十个权重。

### 4.3 EnhancementPolicy

```text
disabled
allowFaithfulEnhancement
allowReconstructiveEnhancement
explicit(processorID)
```

默认不允许会“猜测”不存在细节的算法。超分或修复必须显式启用。

---

## 5. 多表示资源模型

未来的图片来源不应被假定为“一个 URL 对应一个固定文件”。服务端可能提供多尺寸、不同 codec、SDR/HDR、渐进层或机器使用表示。

```swift
public struct ImageResource: Sendable {
    public let logicalID: LogicalAssetID
    public let candidates: [RepresentationCandidate]
    public let metadata: ResourceMetadata
}

public struct RepresentationCandidate: Sendable {
    public let locator: ResourceLocator
    public let declaredFormat: ImageFormat?
    public let pixelSize: PixelSize?
    public let bitDepth: Int?
    public let colorGamut: ColorGamut?
    public let dynamicRange: DynamicRange?
    public let delivery: DeliveryCapabilities
    public let estimatedBytes: Int?
    public let integrity: IntegrityHint?
}
```

候选可以来自：

- 单一 URL；
- 应用提供的 srcset 类清单；
- CDN manifest；
- Asset Catalog；
- Photos；
- 文件或 Data；
- 未来的 JPEG AI/scalable representation。

### 5.1 RepresentationSelector

默认实现是确定性启发式：

- 不选择低于最终目标所需的表示，除非允许预览或增强；
- 不下载远高于目标像素的文件；
- 考虑格式支持、预计字节、动态范围、网络约束和缓存命中；
- 尊重 Low Data Mode、低电量和 deadline。

FoveaAdaptive 可以提供学习型建议，但不得直接执行传输。

---

## 6. 身份、响应记录与缓存键

采用五层模型，明确区分逻辑资产、获取变体、实际内容和派生结果。

### 6.1 LogicalAssetID

表示调用者认为“同一个资产”的稳定身份。它可以来自业务 ID、标准化 URL、文件 ID 或自定义 key。

### 6.2 FetchVariantKey

请求执行前即可计算：

```text
LogicalAssetID
+ locator
+ method
+ 已知会影响响应的请求字段
+ security namespace
+ request body digest（若支持）
```

网络 single-flight 在这一层开始。`Vary` 尚未返回，不能预先假装完整。

### 6.3 RepresentationRecord

这是响应完成后保存的记录，不是简单哈希：

```text
status / MIME / headers
Vary 字段及原始请求值
freshness metadata
ETag / Last-Modified
content digest
partial/range state
trust/provenance locator
```

### 6.4 ContentID

由完整内容摘要和必要的容器语义组成。相同字节可以跨不同 URL 复用，但是否允许跨 namespace 复用由隐私策略决定。

### 6.5 DecodeKey 与 RenderKey

```text
DecodeKey
= ContentID
+ DecodePlan
+ decoder fingerprint
+ requested auxiliary planes

RenderKey
= DecodeKey
+ canonical TransformPlan
+ output pixel format / color policy
+ processor fingerprints
+ enhancement fingerprint（若有）
```

模型版本、Vision request revision、Core ML 模型 hash 和实现后端只要会改变像素，就必须进入 RenderKey。

---

## 7. 来源与传输边界

### 7.1 ImageSource 与 SourceLoader

```swift
public protocol ImageSource: Sendable {
    var logicalID: LogicalAssetID { get }
}

public protocol SourceLoader: Sendable {
    func supports(_ source: any ImageSource) -> Bool
    func resolve(_ source: any ImageSource) async throws -> ImageResource
}
```

默认 loader：

```text
NetworkSourceLoader
FileSourceLoader
DataSourceLoader
AssetSourceLoader
PhotosSourceLoader（可选）
```

只有 NetworkSourceLoader 使用 FoveaHTTP/FoveaTransport。非网络来源不伪装成 HTTP。

### 7.2 FoveaTransport

Transport 只搬运字节，不负责缓存、解码、表示选择和业务重试。

```swift
public struct TransportResponse<Body: AsyncSequence>: Sendable
where Body.Element == ByteChunk {
    public let head: ResponseHead
    public let body: Body
    public let metrics: TransportMetricsHandle
}
```

要求：

- 有界缓冲和背压；
- 可取消；
- 可提供进度和 metrics；
- 支持 Range，但不自行决定是否恢复；
- 数据超过阈值自动 spill 到 staging file；
- 下载过程中同时增量 hash、写缓存 staging、向 decoder 提供增量数据；
- 不强迫整张图聚合成单个巨大 `Data`。

### 7.3 FoveaHTTP

FoveaHTTP 实现 RFC 9111 语义：

- freshness；
- `Cache-Control`、`Expires`、`Age`；
- `ETag`、`Last-Modified` 和 304；
- `Vary` 与 `Vary: *`；
- `stale-while-revalidate`、`stale-if-error`；
- `no-store`、认证响应和私有缓存；
- 206/Range/If-Range；
- 避免与 `URLCache` 形成无法解释的双重缓存。

命中且新鲜的响应直接使用，不能一律条件请求。

---

## 8. 阶段 DAG 与质量阶梯

主路径不是固定数组，而是根据 capability 和目标生成的 `ExecutionPlan`。

```text
ResolveSource
  → SelectRepresentation
  → SelectCachedRepresentation
  → Fetch / Revalidate
  → AccumulateAndHash
  → Probe
  → PlanDecode
  → Decode
  → PlanTransform
  → Transform
  → OptionalEnhancement
  → ConditionalDisplayPreparation
  → CommitCaches
  → Deliver
```

### 8.1 节点契约

每个节点必须定义：

```text
NodeIdentity
typed input/output
是否可共享
是否可缓存
取消传播
优先级传播
重试与 fallback
部分结果语义
提交边界
资源预算
```

### 8.2 Quality Ladder

Fovea 不把“渐进式”限定为 progressive JPEG。统一交付序列：

```text
placeholder
preview
target
refined
```

```swift
public struct ImageUpdate: Sendable {
    public let image: DisplayImage
    public let stage: QualityStage
    public let completeness: Double
    public let fidelity: FidelityClass
    public let trust: AssetTrustState
    public let isFinal: Bool
}
```

低分辨率候选、progressive scan、scalable codec、目标尺寸最终图和可选增强，都可以进入同一质量阶梯。

### 8.3 截止时间感知

系统优化的不只是 final-image latency，还包括：

- first meaningful pixel；
- deadline 前可用的最佳结果；
- refine 是否值得继续；
- 用户已滚离屏幕后是否应停止。

若在截止时间内无法完成目标图，可以先交付 preview，而不是阻塞到完整结果。

---

## 9. 并发与资源治理

### 9.1 并发状态

- actor 只保护任务图注册、订阅关系和生命周期；
- 网络、I/O、解码、处理和模型推理在 actor 隔离区外执行；
- 热缓存路径使用稳定地址锁或经过基准验证的同步原语；
- `URLSessionTask.priority`、Swift `TaskPriority` 和 Fovea 调度优先级是不同层级，不能混为一谈。

### 9.2 ResourceGovernor

```text
NetworkBudget
DiskBudget
MemoryBudget
CPUBudget
GPUBudget
NeuralEngineBudget
EnergyBudget
DeadlineBudget
```

预算根据以下信号动态调整：

- 前台/后台；
- 可见性与滚动速度；
- thermal state；
- Low Power Mode；
- constrained/expensive network；
- memory pressure；
- 平台和设备能力；
- 当前 GPU/ANE 竞争。

Core ML 可选择 CPU、GPU、ANE 等 compute units；选择权属于 ResourceGovernor 和模型策略，不属于具体 processor。

### 9.3 取消策略

最后一个订阅者离开后，不总是立即取消。策略可选择：

```text
cancelImmediately
finishIfNearCompletion
finishAndCacheEncodedOnly
detachConsumerAndLowerPriority
```

昂贵增强默认立即取消；接近完成且可复用的编码数据可继续低优先级写入缓存。

---

## 10. ImageCraft：面向未来 codec 的能力模型

### 10.1 CodecCapabilities

```swift
public struct CodecCapabilities: OptionSet, Sendable {
    public static let targetSizeDecode
    public static let regionDecode
    public static let incrementalDecode
    public static let progressiveQuality
    public static let scalableResolution
    public static let tiledRandomAccess
    public static let hdr
    public static let animation
    public static let auxiliaryPlanes
    public static let machineRepresentation
}
```

Core 不假设每个 decoder 都支持相同能力，而是根据 capability 生成 DecodePlan。

### 10.2 视觉资产与辅助平面

现代图片可能包含：

- 主图；
- HDR gain map；
- depth/disparity；
- portrait/semantic matte；
- 多帧动画；
- stereo pair 与空间元数据；
- provenance manifest。

采用轻量主图加延迟附件：

```swift
public struct VisualAsset: Sendable {
    public let primary: ImageSurface
    public let attachments: AttachmentStore
    public let metadata: ImageMetadata
}
```

普通网络头像只产生 primary，不为未来能力支付常驻成本。调用者必须显式请求辅助平面。

### 10.3 HDR 与 gain map

ISO 21496-1:2025 已标准化用于动态范围转换的 gain map 元数据；Apple Core Image/ImageIO 也能读写 HDR gain map。Fovea 应：

- 保留原始 gain map 和 metadata；
- 根据 DisplayContext 的动态范围与 EDR headroom 决定展开或 SDR 回退；
- 将 HDR policy 纳入 DecodeKey；
- 不因生成 L2 衍生缓存而静默丢失 gain map；
- 为旧设备生成可预测的 SDR 表示。

### 10.4 空间图片

Apple 空间照片是包含左右眼图像和空间元数据的多图 HEIC。Fovea v1 不负责沉浸式渲染，但身份与容器模型不能假定“一文件只有一张主图”。

默认只加载主视图；显式 spatial intent 才请求 stereo pair。

### 10.5 TransformPlan

TransformPlan 是规范化、可哈希、可序列化的内部 IR，不是任意协议：

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

Planner 将其拆成 DecodePlan 和 RenderPlan，尽量把区域、方向和缩放下推到 decoder，减少中间位图。

### 10.6 后端选择

ImageIO、vImage、Core Graphics、Core Image、Metal 各有优势。选择依据：

- 像素数量；
- 变换类型；
- 当前 GPU 压力；
- 是否已有纹理或 pixel buffer；
- 能耗和 deadline；
- 结果是否可直接显示。

MetalFX 是面向 Metal 渲染结果的空间/时间上采样，不作为普通静态图片超分的通用替代。

---

## 11. 学习型编码与 JPEG AI

JPEG AI Part 1 已于 2025 年成为国际标准，目标包括学习型端到端编码、移动设备实现、任意分辨率解码以及面向机器任务的压缩域表示。它代表的趋势应进入架构，但不应直接成为 v1 默认 codec。

### 11.1 工程策略

```text
ImageCraftJPEGAIExperimental
```

作为独立实验插件，只有在以下条件满足后进入 Incubating：

- Apple 设备上的解码延迟、峰值内存和能耗可接受；
- 模型和 decoder 二进制体积明确；
- 许可证、互操作和 conformance 测试清晰；
- malformed bitstream 和模型安全测试完备；
- 相比 AVIF/JXL/HEIF 在实际网络工作负载中有可测收益。

### 11.2 预留能力而非预留类型污染

FoveaCore 只需要识别：

- scalable resolution；
- progressive quality；
- random-access tile；
- 可选 machine representation；
- codec/model fingerprint。

机器特征或 latent 通过 opaque attachment 暴露，核心不直接依赖张量框架。

### 11.3 标准 codec 与神经前后处理

“Sandwiched Compression”表明，传统 codec 前后增加学习型变换可能改善特定内容或感知目标。工程上把它视为一个明确的表示格式：

```text
preprocess model fingerprint
+ conventional codec parameters
+ postprocess model fingerprint
```

它不能伪装成普通 JPEG，否则其他 decoder 无法正确解释。

---

## 12. FoveaAdaptive：AI 只能是受约束的顾问

FoveaAdaptive 定义建议接口，不掌握机制。

```text
RepresentationAdvisor
PrefetchAdvisor
CacheAdvisor
CropAdvisor
QualityAdvisor
ComputeAdvisor
```

### 12.1 DecisionEnvelope

所有建议返回：

```swift
public struct DecisionEnvelope<Value: Sendable>: Sendable {
    public let value: Value
    public let confidence: Double
    public let modelFingerprint: ModelFingerprint?
    public let featureSchemaVersion: UInt16
    public let expiresAt: ContinuousClock.Instant?
    public let rationaleCode: RationaleCode
}
```

Core 验证约束后决定是否接受。

### 12.2 决策分类

#### 调度型决策

例如预取顺序、并发分配、缓存准入。它们不改变最终像素，因此通常不进入 RenderKey，但必须记录 decision trace。

#### 表示型决策

例如选择低码率候选、HDR/SDR 表示。选择结果进入 RepresentationRecord。

#### 输出型决策

例如内容感知裁剪、超分、修复。模型 fingerprint、参数和 revision 必须进入 RenderKey，并标记内容变换语义。

### 12.3 不做隐式全局注册

`import FoveaAdaptive` 不得自动改变所有请求。调用者必须：

- 在 Pipeline configuration 中安装具体 advisor；或
- 在单个 ImageIntent 中显式启用。

这保证相同代码路径可复现。

### 12.4 在线学习约束

默认不做跨应用或云端遥测训练。若支持本地自适应：

- 明确 opt-in；
- 数据留在设备；
- 可清除；
- 模型更新原子化；
- 具备版本回滚；
- 不把 URL、鉴权信息和私有图片内容写入训练日志。

---

## 13. 内容感知裁剪、占位符与增强

### 13.1 内容感知裁剪

Vision 已提供 attention/objectness saliency；2026 年的新 Vision API 继续强化图片质量与显著性分析。工程接入为 `FoveaVisionCrop`：

- 默认关闭；
- 输出 crop proposal，不直接裁图；
- 支持人脸、主体和安全边界规则；
- 保存 Vision request revision；
- 不在主滚动热路径上同步运行；
- 结果缓存键为 ContentID + model/revision + crop intent；
- 对不同肤色、多人图和非摄影内容建立偏差测试。

### 13.2 ThumbHash/BlurHash

占位符不是 AI，应独立为 `FoveaPlaceholders`。优先使用服务端或资源 manifest 提供的短 hash，客户端不应为每张下载图额外编码占位符。

### 13.3 超分与修复

必须区分：

```text
faithful enhancement      去噪、传统高质量缩放，尽量保持证据
reconstructive enhancement 模型推测细节，可能改变内容
creative/generative        不属于 Fovea 核心范围
```

重建型增强的规则：

- 显式 opt-in；
- 仅在目标像素明显高于源像素且网络替代不可得时考虑；
- 有 deadline、内存和 energy 上限；
- 显示结果标记为 reconstructed；
- 缓存键包含模型 hash、compute units 和精度配置；
- 若资源包含可信 provenance，不得把增强结果冒充原始内容。

Core ML compute units 由 ResourceGovernor 选择；后台或 GPU 高压时可限制为 CPU/ANE 或直接跳过。

---

## 14. 学习增强缓存与预取

前沿缓存论文显示，学习增强策略可以降低 object/byte miss ratio，但工程开销不可忽略。FAST'25 的 3L-Cache 即使显著降低了相对学习策略开销，仍报告为 LRU 的数倍。因此移动端默认策略不能依赖重模型。

### 14.1 默认策略

v1 使用低开销、可解释的候选策略，通过真实图片 trace 选择：

- S3-FIFO；
- SIEVE；
- size-aware TinyLFU；
- ARC/CAR 风格自适应；
- LRU 基线。

不在文档阶段预定唯一赢家。

### 14.2 Image-aware hints

Fovea 可以给 Akashic 提供机制无关的提示：

```text
encoded bytes
resident bytes
recompute cost
download cost
reuse class
visibility
privacy class
expiry risk
```

缓存策略以这些提示优化加权成本，而不理解 `UIImage`。

### 14.3 CacheAdvisor

学习型 CacheAdvisor 只能建议：

- 准入概率；
- 预计复用；
- 类别权重；
- 预算分配。

最终淘汰仍由有界、同步安全的 MemoryCachePolicy 执行。advisor 超时或缺失时使用确定性策略。

### 14.4 PrefetchAdvisor

通用库无法仅凭图片 URL 推断业务语义。默认预取基于 UI 提供的可见性、滚动方向、距离和速度。学习型预取必须由应用显式提供特征或模型，Fovea 只提供执行和限流机制。

错误预取的代价纳入指标：浪费字节、能耗、缓存污染和已取消解码，而不仅是命中率。

---

## 15. 缓存层次

```text
L0 Rendered Memory       目标尺寸、处理完成、可显示
M0 Metadata Memory       格式、尺寸、颜色、validator、能力信息
L1 Raster Experimental   固定尺寸热点未压缩 slab，默认关闭
L2 Derived Encoded       目标尺寸压缩衍生物，需准入
L3 Original Content      原始响应 blob + RepresentationRecord
A0 Analysis Cache        saliency/质量/模型结果，独立预算
```

### 15.1 L2 不是无条件写入

只有满足以下收益条件才生成衍生物：

- 原图远大于目标；
- 解码/处理成本高；
- 预计复用足够；
- 变体数量未超限；
- 编码成本和写放大可接受；
- 颜色、HDR 和辅助平面不会被不正确丢失。

### 15.2 分析缓存

AI 分析结果不与显示位图混用预算。键必须包含：

```text
ContentID
+ model fingerprint / Vision revision
+ request parameters
+ feature schema
```

模型升级后旧结果自然失效。

### 15.3 RasterStore

继续作为 v1 后实验：

- 固定尺寸、固定格式、热点小图；
- mmap slab/table；
- 可清空重建；
- 与 L2 做端到端收益比较；
- 测量 page fault、工作集和磁盘膨胀，不能只测解码时间。

---

## 16. 可信媒体与变换证明

AI 时代的图片库不能只返回像素，也需要可选地返回“这些像素从哪里来、是否被改变”的状态。

JPEG Trust Part 1 于 2025 年发布；C2PA Content Credentials 定义了可验证的 provenance、签名、assertion 和派生资产链。Fovea 不自行发明新 provenance 标准。

### 16.1 FoveaTrust

```swift
public enum AssetTrustState: Sendable {
    case unavailable
    case unverified
    case validating
    case valid(TrustSummary)
    case invalid(TrustFailure)
    case indeterminate(TrustReason)
}
```

TrustPolicy：

```text
ignore       不解析
observe      图片可先显示，异步更新 trust state
requireValid 验证成功前不交付最终结果
```

### 16.2 原始与派生内容

几何裁剪、颜色变换、超分和修复都可能使原始 manifest 不再直接绑定最终字节。Fovea 应：

- 保留原始 Content Credentials 和验证结果；
- 生成结构化 TransformationReceipt；
- 提供 claim generator hook，由应用决定是否签署新的派生资产声明；
- 不在没有签名能力时伪造“可信”状态。

### 16.3 缓存与 trust

验证结果可缓存，但要绑定：

```text
ContentID
+ validator implementation version
+ trust list/version
+ verification time
```

撤销信息或 trust list 更新可能使结果过期。

---

## 17. 安全、隐私与模型供应链

### 17.1 DecodeLimits

```text
maximum encoded bytes
maximum width/height
maximum pixel count
maximum frame count
maximum metadata bytes
maximum auxiliary planes
maximum progressive scans
maximum nesting/recursion
allowed formats
```

在任何大内存分配前检查。

### 17.2 格式安全

- MIME、UTType 与 magic number 交叉验证；
- SVG 禁止或限制外部资源、脚本、递归引用；
- 第三方 C/C++ codec 建立 fuzzing、ASan/UBSan 和恶意 corpus；
- 增量 decoder 能处理截断、重排和畸形数据；
- codec 插件拥有独立安全更新周期。

### 17.3 缓存隐私

- security namespace；
- 登录退出完整清理；
- `no-store` 不落盘；
- 可配置文件保护与备份排除；
- 日志不记录完整私有 URL、token、cookie；
- 跨 namespace 内容去重默认关闭，除非调用者明确允许。

### 17.4 模型供应链

- 模型由应用打包或显式管理，不由 Fovea 隐式远程下载；
- 模型文件有 hash、版本和签名信息；
- 更新原子化并可回滚；
- 模型 metadata 声明输入尺寸、颜色空间、允许 compute units、峰值内存和语义类别；
- 模型执行有超时、预算和输出验证。

---

## 18. 可观测性与决策可解释性

每个加载任务生成统一 trace：

```text
source resolution
candidate representations
selection reason
cache level and key class
network/revalidation outcome
bytes and timings
probe/decode/transform backend
decision advisor/model version
resource budget changes
cancellation reason
trust state
quality ladder deliveries
```

公开 API 以事件流和摘要形式提供，内部用 `os_signpost` 与 MetricKit 对接。

### 18.1 可复现模式

测试和 benchmark 支持：

- DeterministicClock；
- 固定 policy seed；
- 禁用 adaptive advisor；
- 记录/重放 pipeline trace；
- 固定网络与缓存状态；
- 导出 ExecutionPlan 和 DecisionEnvelope。

AI 决策不应让性能回归无法复现。

---

## 19. 基准与质量评价

### 19.1 系统指标

- first meaningful pixel；
- final image latency p50/p95/p99；
- deadline miss rate；
- 主线程 hitch；
- 峰值 physical footprint、dirty memory、page fault；
- CPU/GPU/ANE 时间与能耗；
- 网络/磁盘字节；
- object hit rate 与 byte hit rate；
- 重复下载/解码；
- 取消后浪费；
- 模型冷/热启动成本；
- 二进制和模型体积。

### 19.2 视觉质量

不能只用 PSNR/SSIM。JPEG AIC 和近期 JPEG AI 主观研究说明，高保真范围内客观指标可能过于乐观。评估层次：

```text
像素指标      PSNR/SSIM 仅作诊断
感知指标      MS-SSIM、VMAF、CVVDP 等
主观评价      JND、成对比较、任务场景评分
任务质量      人脸/文字/细节等特定任务
```

任何“码率降低多少”的宣传必须同时报告 decoder 复杂度、设备、功耗、主观质量方法和置信区间。

### 19.3 AI 特有指标

- crop 主体保持率与偏差；
- 超分 identity/detail preservation；
- 重建伪影和文本错误；
- advisor 推理成本与收益；
- 错误预取代价；
- 模型不可用时的回退一致性；
- provenance 状态是否正确传播。

---

## 20. 公共扩展点：严格类型化

不提供“任意阶段可改写一切”的通用拦截器。公共扩展点限定为：

```text
SourceLoader
RepresentationSelector
RequestAuthorizer
Transport
HTTPPolicy
CachePolicy
DecodePolicy
TransformPlanner
EnhancementProcessor
TrustValidator
PipelineObserver
DecisionAdvisor
```

约束：

- CDN/URL 改写在 FetchVariantKey 计算前完成；
- Observer 只观察；
- 任何影响字节或像素的扩展必须提供 fingerprint；
- 扩展不能在缓存键冻结后静默修改结果语义；
- 所有扩展均可被替换为测试实现。

---

## 21. API 草图

```swift
let pipeline = ImagePipeline(
    sources: .defaults,
    representationSelector: BalancedRepresentationSelector(),
    cache: FoveaCache(akashic: cache),
    transport: URLSessionTransport(configuration: configuration),
    governor: AdaptiveResourceGovernor(),
    trustValidator: nil,
    advisors: []
)

let intent = ImageIntent(
    source: URLImageSource(url),
    display: DisplayContext(
        targetPixels: .init(width: 600, height: 400),
        contentMode: .fill,
        displayScale: 3,
        colorGamut: .displayP3,
        dynamicRange: .automatic,
        edrHeadroom: nil,
        viewport: nil
    ),
    objective: .interactive,
    transform: .roundedRectangle(radius: 24),
    cachePolicy: .automatic,
    trustPolicy: .observe,
    enhancementPolicy: .disabled
)

for try await update in pipeline.images(for: intent) {
    imageView.display(update.image)
    trustBadge.state = update.trust
}
```

普通场景仍提供三行式 UI API。复杂模型只存在于 Core 之下，不能把使用者迫使进策略细节。

---

## 22. 路线图

### Phase 0：协议闭合与风险原型

- Source/Representation/Identity 模型；
- RFC 9111 cache record 原型；
- 有界流式传输与 spill-to-disk；
- DAG、取消和提交语义；
- Target-size ImageIO 解码；
- 真机 benchmark harness；
- 文档 ADR 化。

验收：证明身份模型和阶段共享不会导致错误复用；证明大图下载解码不需要常驻完整 Data。

### Phase 1：确定性生产核心

- 静态图 URL/File/Data/Asset；
- Rendered memory + original disk cache；
- UIKit/AppKit/SwiftUI；
- target-size decode；
- single-flight、取消、优先级；
- 安全限制和诊断。

不包含 AI、RasterStore 和重型 codec。

### Phase 2：HTTP 正确性与丰富图片

- freshness/validator/Vary/range；
- namespace 与隐私；
- progressive quality ladder；
- animation；
- HDR gain map 与辅助平面；
- Photos 和空间图片主图读取；
- L2 derived cache admission。

### Phase 3：低风险前沿能力

- FoveaPlaceholders；
- Vision crop proposal；
- 可选 C2PA/JPEG Trust 验证；
- representation manifest 与自适应选择；
- trace replay 与策略实验。

### Phase 4：学习增强策略

- CacheAdvisor / PrefetchAdvisor 离线与本地模型；
- no-reference quality advisor；
- 资源 governor 的数据驱动调参；
- 明确回退和 A/B framework。

只有真实工作负载显示净收益才进入 Incubating。

### Phase 5：重建与新 codec

- 端侧超分/修复实验；
- JPEG AI 插件；
- compressed-domain/machine representation；
- RasterStore 与学习型 codec 的联合收益分析。

这一步不承诺进入稳定版。

---

## 23. 关键架构决策

| 决策 | 结论 |
|---|---|
| AI 是否进入核心 | 否。进入 advisor、processor、codec 或 trust 插件，核心保留确定性回退 |
| 是否泛化成媒体框架 | 否。支持图片及辅助平面，不承担视频播放与生成式创作 |
| 学习型 codec | 预留 capability；JPEG AI 先在 FoveaLab/实验插件验证 |
| 缓存默认使用学习策略 | 否。低开销策略先经 trace 对比；模型只提供建议 |
| 内容感知裁剪 | 可选 proposal，不隐式执行；模型/revision 进入 key |
| 超分 | 重建型增强，显式 opt-in，默认关闭 |
| 可信媒体 | 采用 C2PA/JPEG Trust，不自创新标准；支持异步 trust state |
| HDR/空间图 | 容器与身份模型原生支持辅助平面；按需解码 |
| 最低系统 | 维持 iOS 15 等基线；最新能力 capability-gated |
| 实验如何隔离 | FoveaLab 不进入生产依赖；按毕业标准迁移 |
| 文档是否定稿 | 否。Phase 0 完成前为 Proposed |

---

## 24. 本方案相对 V1 的实质变化

1. 将“智能层”从功能清单改为有约束的 advisor/processor/codec 模型。
2. 引入多表示资源与 representation selection，适应 CDN、scalable codec 和学习型 codec。
3. 将加载目标从单一 final image 升级为 deadline-aware quality ladder。
4. 把 CPU/GPU/ANE/能耗纳入统一资源治理。
5. 将 JPEG AI、JPEG Trust、C2PA、HDR gain map 和空间图片纳入长期能力模型。
6. 把模型版本、Vision revision 和增强语义纳入身份与缓存正确性。
7. 增加模型供应链、偏差、真实性和 AI 输出语义边界。
8. 引入 FoveaLab 与研究能力毕业制度，防止论文原型污染稳定库。
9. 明确学习型缓存与预取不是默认答案，必须计算净收益。
10. 将基准从纯性能扩展为性能、感知质量、能耗、真实性和回退一致性。

---

## 25. 参考资料与技术信号

### 标准与官方资料

- RFC 9111: HTTP Caching — https://www.rfc-editor.org/rfc/rfc9111.html
- JPEG AI overview / ISO/IEC 6048 — https://jpeg.org/jpegai/
- JPEG AI becomes an International Standard — https://jpeg.org/items/20250219_press.html
- JPEG Trust / ISO/IEC 21617 — https://jpeg.org/jpegtrust/
- JPEG AIC — https://jpeg.org/aic/
- C2PA Specifications — https://spec.c2pa.org/
- ISO 21496-1:2025 gain map metadata — https://www.iso.org/standard/86775.html
- Apple Vision saliency — https://developer.apple.com/documentation/vision/vngenerateattentionbasedsaliencyimagerequest
- Apple Core ML compute units — https://developer.apple.com/documentation/coreml/mlcomputeunits
- Apple MetalFX — https://developer.apple.com/documentation/metalfx
- Apple spatial photos — https://developer.apple.com/documentation/imageio/writing-spatial-photos
- Apple HDR gain maps — https://developer.apple.com/documentation/coreimage/ciimageoption/expandtohdr

### 论文与系统工作

- Sandwiched Compression: Repurposing Standard Codecs with Neural Network Wrappers, 2024 — https://arxiv.org/abs/2402.05887
- Subjective Visual Quality Assessment for High-Fidelity Learning-Based Image Compression, 2025 — https://arxiv.org/abs/2504.06301
- What Matters in Practical Learned Image Compression, 2026 preprint — https://arxiv.org/abs/2605.05148
- CACHEUS, FAST 2021 — https://www.usenix.org/conference/fast21/presentation/rodriguez
- 3L-Cache, FAST 2025 — https://www.usenix.org/conference/fast25/presentation/zhou-wenbin
- ARC, FAST 2003 — https://www.usenix.org/conference/fast-03/arc-self-tuning-low-overhead-replacement-cache
- CAR, FAST 2004 — https://www.usenix.org/conference/fast-04/car-clock-adaptive-replacement
- S3-FIFO, SOSP 2023 — https://s3fifo.com/
- SIEVE, NSDI 2024 — https://cachemon.github.io/SIEVE-website/

### 工程对照

- Nuke — https://github.com/kean/Nuke
- Kingfisher — https://github.com/onevcat/Kingfisher
- SDWebImage — https://github.com/SDWebImage/SDWebImage
- Coil — https://github.com/coil-kt/coil
- Glide — https://github.com/bumptech/glide
- Fresco — https://github.com/facebook/fresco
- libvips — https://www.libvips.org/
- FastImageCache — https://github.com/path/FastImageCache

---

## 26. 最终结论

Fovea 的代际优势不应建立在“拥有最多 AI 功能”上，而应建立在以下能力上：

- 今天：比现有图片库更严格地处理目标像素、内容身份、HTTP、缓存、取消和资源预算；
- 明天：无需重写核心即可接入多表示资源、HDR/空间图、可信媒体和新的 codec；
- 后天：学习型编码、感知策略和端侧增强成熟时，能够以可验证、可回退、可追踪的方式工程化。

真正的预见性不是提前押注某个模型，而是让未来技术只能通过正确边界进入系统。Fovea 应当对新能力保持开放，对核心语义保持保守，对性能和质量声明保持可证伪。