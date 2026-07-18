# Fovea 图片加载系统架构

> **状态：Proposed（唯一工作架构文档）**  
> 本文是当前唯一的架构入口。只有经过可运行原型、自动化正确性测试和真机基准验证的局部决策，才可在对应 ADR 中标记为 `Accepted`。整份蓝图在 Phase 0 完成前不称“定稿”。
>
> **平台基线：** iOS/iPadOS 15、macOS 12、watchOS 8、tvOS 15、visionOS 1。  
> **语言：** Swift 6 严格并发。  
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

如果 Fovea 不能在至少两个 canonical workload 上相对成熟竞品产生可复现的净收益，就不应继续扩大公共 API。

---

## 2. 文档与决策治理

### 2.1 单一权威来源

- `docs/ARCHITECTURE.md`：唯一工作架构。
- `docs/archive/`：历史版本，只用于追溯，不指导实现。
- `docs/adr/`：局部决策及其证据。
- `docs/specifications/`：可执行规范，如缓存语义、基准和安全默认值。
- `docs/TECHNOLOGY_RADAR.md`：前沿技术跟踪，不构成产品承诺。

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

---

## 3. 成熟度分层

### 3.1 Stable Core

当前必须做对、并形成稳定契约：

- Source 与简单表示候选；
- FetchVariantKey、RepresentationRecord、ContentID、DecodeKey、RenderKey；
- RFC 9111 HTTP 语义；
- 有界流式传输、落盘 staging 和增量摘要；
- 固定阶段加载管线；
- target-size 解码；
- RenderedMemory 与 OriginalEncoded；
- single-flight、取消、优先级；
- UIKit、AppKit、SwiftUI 生命周期；
- DecodeLimits、安全 namespace、诊断和基准。

### 3.2 Capability Slots

Core 只预留技术无关的最小接缝，不承诺具体实现：

- 多表示候选与 representation selection；
- codec capabilities；
- 可选辅助平面；
- 异步 enhancement processor；
- opaque provenance attachment；
- processor/model fingerprint；
- 资源需求提示；
- advisor 建议接口。

Capability slot 不得迫使普通请求承担额外内存、依赖、线程或分支成本。

### 3.3 Experimental Modules

已有实现和基准，但默认关闭、API 可破坏：

- `FoveaPlaceholders`；
- `FoveaVisionCrop`；
- `FoveaTrust`；
- `FoveaAdaptive`；
- `FoveaRasterStoreExperimental`；
- ImageCraft 的重型 codec 插件；
- 端侧超分和重建处理。

### 3.4 Technology Radar / FoveaLab

论文复现、标准跟踪、模型和策略竞赛放在 FoveaLab。生产仓库不得依赖 FoveaLab。

实验一旦满足毕业标准，可以迅速迁移，不必等待固定版本周期；不满足则删除，不因沉没成本保留。

---

## 4. 项目边界与开发形态

长期发布边界仍是三个生产项目：

```text
ImageCraft   图像探测、编解码、处理、动画和辅助平面
Akashic      通用缓存与持久化机制
Fovea        来源、HTTP、加载调度、组合与 UI
```

但 Phase 0 不立即建立三套独立发布节奏。采用统一 workspace、path dependency 或固定 commit pin 联调；公共契约稳定后再独立发版。这样保留长期边界，同时避免早期版本矩阵拖慢重构。

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

---

## 5. 默认简单 API

架构复杂度不能转嫁给普通使用者。首先保证：

```swift
FoveaImage(url: url)
```

```swift
imageView.fovea.setImage(from: url)
```

```swift
let image = try await Fovea.shared.image(for: url)
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
- 自动推导目标像素时绑定当前 view 尺寸和 scale；
- 目标像素未知时不静默缓存巨大全尺寸渲染结果；
- UI 复用会取消旧订阅；
- SwiftUI identity 改变会取消旧任务；
- placeholder、transition、错误和 retry 行为可预测；
- 默认不启用重建型增强和 trust 验证。

---

## 6. 身份与缓存键：唯一模型

废弃 V1 的 `RequestIdentity / ResourceIdentity` 模型。validator 与内容身份不可混合，`Vary` 也不能在首次请求前完整获知。

### 6.1 FetchVariantKey：请求前可计算

用于网络 single-flight 和初始缓存选择：

```text
logical source identity
+ resolved locator
+ HTTP method
+ 请求前已知且会影响响应的字段
+ security namespace
+ request body digest（若支持）
```

CDN 重写、鉴权适配和 locator 解析必须在 FetchVariantKey 冻结前完成。

### 6.2 RepresentationRecord：响应后建立

它是记录，不是内容哈希：

```text
status、MIME、响应头
Vary 字段与原请求值
freshness metadata
ETag / Last-Modified
content digest
Range/partial state
隐私和 trust metadata locator
```

### 6.3 ContentID：实际字节身份

完整内容经摘要后得到 ContentID。相同内容可在一个安全域中跨 locator 复用。

**安全铁律：跨 security namespace 的 ContentID 去重默认关闭。** 即使字节摘要相同，也不得因共享 blob、访问时间或元数据造成账户侧信道或生命周期耦合。

### 6.4 DecodeKey

```text
ContentID
+ normalized DecodePlan
+ decoder fingerprint
+ requested auxiliary attachments
```

DecodePlan 包含实际输出像素范围、orientation、颜色/HDR 策略、静态/动画策略等。语义已经由 target pixels 完整表达时，不重复加入仅用于 UI 的 point scale，避免等价结果产生重复 key。

### 6.5 RenderKey

```text
DecodeKey
+ canonical TransformPlan
+ output pixel/color policy
+ processor fingerprints
+ enhancement fingerprint（若改变像素）
```

processor identity 必须是结构化、版本化、可规范化的值，不允许任意字符串拼接。

### 6.6 三种共享不可混淆

```text
FetchVariantKey  → 网络请求共享
ContentID        → 已获取字节去重
DecodeKey        → 解码结果共享
RenderKey        → 最终显示结果复用
```

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

非网络来源不得伪装成 Transport。

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

### 7.3 HTTP 缓存状态机

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

必须覆盖：

- `Cache-Control`、`Expires`、`Age`；
- `no-cache` 与 `no-store` 的区别；
- `private`、认证响应和 shared/private cache 规则；
- `Vary`、`Vary: *`；
- ETag、Last-Modified、304 metadata merge；
- 206、Content-Range、If-Range；
- 重定向跨 origin 时 Authorization 的处理；
- 与 `URLCache` 的边界，默认避免无法解释的双重缓存。

Akashic 提供事务和存储；FoveaHTTP 拥有 HTTP 语义。

---

## 8. v1 固定加载阶段

v1 不实现通用 DAG 运行时。内部可用依赖图解释共享关系，但执行阶段固定、数量受控：

```text
1. ResolveSource
2. SelectCache
3. FetchOrRevalidate
4. AccumulateHashAndStage
5. Probe
6. DecodeAtTarget
7. Transform
8. Commit
9. Deliver
```

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

- 相同 FetchVariantKey 共享网络获取；
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

认证、`private`、`no-store` 内容不得在无人订阅后继续落盘。

### 9.2 优先级是三层概念

```text
Fovea scheduler priority  决定本地排队、预算和抢占
Swift TaskPriority        执行上下文提示
URLSessionTask.priority   网络栈提示
```

三者不可互相等同。可见内容高于预取；离屏预取可取消或降级。

### 9.3 提交边界

- blob staging 完整且摘要验证后才成为 ContentID；
- RepresentationRecord 与 blob 引用原子提交；
- 解码失败不污染 RenderedMemory；
- DerivedEncoded 半写文件不可见；
- 取消和崩溃后 staging 可回收。

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
no-store                       → reject disk
不可见 speculative result      → conservative admission
```

### 11.2 DerivedEncoded

方向有价值，但写入默认关闭或极保守。只有满足以下条件才允许生成：

- sourcePixels / targetPixels 达到阈值；
- targetPixels 在上限内；
- 已有复用证据；
- ContentID 的变体数量未超限；
- 编码成本、磁盘预算和当前 thermal/IO 状态允许；
- HDR、色彩和辅助平面语义不会被错误丢弃。

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

当实验增强或新 codec 证明需要时，再升级 governor，而不是预先冻结八维最优控制 API。

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

SwiftUI 行为不能只是 UIKit wrapper 的附录。

---

## 14. 安全与隐私

默认拒绝矩阵由 `docs/specifications/security-defaults.md` 定义并进入测试。

核心规则：

- MIME、UTType、magic number 交叉验证；
- `text/html` 等非图像响应默认拒绝；
- SVG script、external entity/resource 默认禁止；
- 重定向到不同 origin 默认不继承 Authorization；
- `no-store` 不落盘；
- 认证响应不进入共享 namespace；
- 日志不记录 token、cookie 和完整私有 URL；
- 第三方 codec 版本钉定、fuzz、ASan/UBSan 和恶意 corpus；
- 模型不由 Fovea 隐式远程下载。

安全是 Stable Core，不是可选插件。

---

## 15. Canonical workloads 与存在性门槛

详见 `docs/specifications/benchmark-workloads.md`。Phase 0 固定三个门禁：

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

Fovea 至少需要在 Feed Scroll 与 Detail Hero 中产生一项显著、可复现且无明显反向代价的性能收益，并在 Auth Gallery 中证明身份与缓存隔离正确，才证明值得独立存在。

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
| HDR gain map / 辅助平面 | lazy attachment | Capability Slot / Incubating |
| JPEG AI | codec capabilities、fingerprint | FoveaLab / Experimental codec |
| C2PA / JPEG Trust | opaque provenance、trust state | Experimental，默认零成本 |
| Vision 裁剪 | Async proposal processor | Experimental，显式启用 |
| ThumbHash/BlurHash | placeholder source | Incubating extras，不属于 AI |
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
FetchVariantKey class（不泄露敏感值）
cache outcome
HTTP freshness/revalidation outcome
bytes and timings
probe/decode/transform backend
decoded pixel count
single-flight joins
cancellation reason and wasted work
budget changes
final delivery stage
```

支持：

- `os_signpost`；
- 结构化事件流；
- DeterministicClock；
- trace record/replay；
- 固定 cache/network state；
- advisor 关闭模式；
- 导出匿名化执行摘要。

没有可观测性，不允许宣称策略更优。

---

## 18. 实施顺序

### Phase 0：唯一工程重点

1. 统一 workspace，接入当前 ImageCraft/Akashic 原型但不承诺兼容。
2. 定义并测试 FetchVariantKey → RepresentationRecord → ContentID → DecodeKey → RenderKey。
3. 完成 URL → OriginalEncoded → target decode → RenderedMemory → UI 最小闭环。
4. 实现有界传输和 spill-to-disk，证明大图不需要常驻完整 Data。
5. 建立三个 canonical workloads 与 Nuke/Kingfisher 对照适配器。
6. 身份、HTTP、auth 隔离测试优先于复杂缓存算法。
7. 更新 Reality Gap ADR，决定现有代码逐项复用或重写。

### Phase 1：确定性生产核心

- URL/File/Data/Asset；
- target-size static decode；
- OriginalEncoded、RenderedMemory；
- single-flight、取消和优先级；
- UIKit/AppKit/SwiftUI；
- DecodeLimits、安全矩阵和诊断；
- RFC 9111 核心 freshness/validator/Vary。

### Phase 2：经数据选择的优化

- 内存策略 trace 竞赛；
- progressive preview；
- animation；
- DerivedEncoded 保守准入实验；
- Photos；
- richer HTTP Range/recovery；
- capability matrix。

### 并行 FoveaLab

从 Phase 0 起即可并行研究 JPEG AI、trust、HDR/空间图、Vision crop、超分和学习策略。它们通过毕业门禁随时迁移，不绑定固定年份或 Phase 5。

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
- 因 AI 提高编码速度而跳过真机、稳定性和安全验证。

---

## 20. 最终判断

Fovea 的野心不应缩小，但必须被正确安置：

- **Stable Core 极小、严格、可证明；**
- **Capability Slots 面向未来但不绑定具体技术；**
- **Experimental Modules 可高速演进且随时删除；**
- **FoveaLab 并行吸收论文、标准和新平台能力。**

AI 已经改变了原型和验证的速度，因此 JPEG AI、可信媒体、学习策略和端侧增强可以现在就开始，而不是等待若干年。但它们何时成为公共承诺，仍由正确性、净收益、安全和维护成本决定。

Fovea 首先必须以更小的身份、HTTP、目标像素、取消和安全契约证明自身价值；只有完成这一点，前沿能力才会成为架构优势，而不是范围膨胀。
