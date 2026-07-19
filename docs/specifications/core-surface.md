# Phase 0a 实现面与符号预算

> **状态：Active，Phase 0a 的规范性范围表。**
> 本文只回答“第一条可运行垂直切片允许实现什么、明确不实现什么”。它不替代架构和各领域规格；冲突时按 `docs/README.md` 的权威顺序处理。

## 1. 目标

Phase 0a 只证明以下闭环真实可运行：

```text
public URL
→ stable request identity
→ exact fetch single-flight
→ bounded streaming + staging + hash
→ safe OriginalEncoded commit
→ ImageIO target-size decode
→ RenderedMemory
→ SwiftUI FoveaImage
```

0a 不证明完整 Core v1、完整 RFC 9111 profile、全部 Apple UI surface 或性能领先。

## 2. 首个 UI surface

Phase 0a 选择 **iOS 15+ SwiftUI** 作为唯一 UI surface：

```text
FoveaImage
FoveaImagePhase
request token / identity replacement
placeholder → final / failure / cancelled
```

UIKit、AppKit、tvOS/watchOS/visionOS UI adapter 在 0a 只要求模块边界可容纳，不编写产品实现。W1 初始 harness 可以使用 SwiftUI；若真机 trace 证明 SwiftUI 本身造成不可控噪声，必须用 ADR 改选 UIKit，不能同时维护两个 0a surface。

## 3. 允许出现的生产模块

```text
ImageCraftCore
ImageCraftImageIO
AkashicCore
AkashicMemory
AkashicDisk
FoveaCore
FoveaHTTP
FoveaSwiftUI
FoveaTesting
```

不得为了占位创建空的 Trust、Adaptive、Vision、Derived、Animation、Codec plugin 或 FoveaLab product。

## 4. 允许实现的最小符号

### 4.1 Identity

```text
LogicalSourceID
SecurityNamespaceID
NamespaceGeneration
AuthorizationContextID
CredentialGeneration
FetchVariantKey
FetchExecutionKey
ContentID
DecodeKey
RenderKey
```

0a 只要求 versioned canonical encoding、稳定摘要和必要字段。不得提前引入通用 manifest、学习型 selector 或动态 identity plugin graph。

### 4.2 HTTP record

`RepresentationRecord` 的最小字段：

```text
recordSchemaVersion
namespace fingerprint / NamespaceGeneration
FetchVariantKey digest
statusCode
responseDate / requestTime / responseTime
freshness data required by max-age / Expires / Age
ETag / Last-Modified
cache disposition: reusable | noStore | privateNamespace
ContentID
payload length / content type
```

0a 支持 GET、200、304、fresh hit 和 `no-store`。完整 `Vary` corpus、206/Range、stale extensions 和 heuristic freshness 属于 0b/Core v1。

### 4.3 Transport and staging

```text
TransportRequest
TransportResponseHead
BoundedStagingAccumulator
StagedBody
streaming SHA-256
TransportMetrics
```

必须有 encoded byte hard limit、内存阈值后 spill、逐块背压、取消和 incomplete body 清理。URLSession 实现不得按单字节消费大响应，也不得用无界事件缓冲绕过 hard limit。0a 不做跨请求 Range resume。

### 4.4 Storage

```text
OriginalEncodedStore.open
RepresentationRecordStore.open
PhysicalBlobID
NamespaceGeneration read/commit fence
MemoryCache<Key, Value>
```

从第一天起必须使用 namespace-local 随机不透明 `PhysicalBlobID`；禁止临时使用 ContentID/SHA-256 作为文件名后再迁移。0a 只实现：

- 单进程 writer；
- `AkashicMemory` 不依赖 ImageCraft、URL、HTTP 或 UI，值成本由调用者显式传入；
- blob + record 原子可见；
- 持久 metadata 只保存 namespace fingerprint，不保存稳定主体标识明文；
- 简单 store soft cap；
- 超限时按过期/最旧记录做保守 FIFO 或近似 LRU 清理；
- corruption/ENOSPC 退化为 miss，不覆盖成功 final。

namespace/category quota、lease、精确 atime、mark-and-sweep crash matrix 和多进程协调后移至 0b/Core v1。

### 4.5 Decode and UI

```text
ImageProbe
DecodeLimits
TargetPixels
ImageDecoding
ImageIOImageDecoder
DecodedImage
FoveaImage / FoveaImagePhase / FoveaImageAccessibility
```

unknown/zero target 不得触发原尺寸 decode；原尺寸 API 不进入 0a。只实现静态 JPEG/PNG/系统 ImageIO 可安全探测格式的基础路径，不实现动画、SVG、第三方 codec、HDR/gain-map 或 Analysis。

### 4.6 Configuration

```text
PipelineConfiguration
FoveaPipeline
FetchStage / DecodeStage / PipelineCache（package-only 固定职责）
PipelineFailure
WallClock / SystemWallClock（package-only 测试注入）
DiagnosticsSink / BoundedDiagnosticsSink
```

配置构造后不可变。公开 API 不暴露 stage registry、clock、namespace registry 或 staging accumulator；这些实现原语使用 Swift `package` 访问级别。0a 不提供运行时全局注册、interceptor chain 或动态 DAG。

Phase 0a 的并发与组合约束：

- package 使用 Swift 6 严格并发，并启用 Swift 6.2 `NonisolatedNonsendingByDefault` 与 `InferIsolatedConformances`；
- 公开加载入口和共享 operation 使用显式 `@concurrent`，不依赖调用者 actor 的偶然继承；
- 阻塞文件系统操作只在 Akashic/FoveaHTTP 的专用串行 executor 上运行；store 使用异步 `open`，禁止在 UI actor 同步扫描 manifest；
- `FoveaCore` 只依赖 `ImageDecoding` 协议，具体 ImageIO decoder 由 composition root 注入；
- 唯一 FetchExecutionKey 任务执行 fetch single-flight；DecodeKey single-flight 明确后移，不得把当前实现描述为完整 stage sharing；
- fetch/decode 在进入昂贵阶段前获取静态 hard-cap permit；等待取消必须释放资格且不得实际启动该阶段；
- 生产代码不得使用未经逐项审计的 `@unchecked Sendable`。

## 5. Public path 是默认路径

没有 `Authorization`、Cookie 或 client identity 时：

```text
SecurityNamespaceID = app-scoped public namespace
AuthorizationContextID = public
CredentialGeneration = absent
AuthorizationContextProvider = not required
RequestAuthorizer = not required
```

是否持久化仅由 HTTP/cache/security policy 决定。0a demo 和 W1/W2 主路径使用该模式；鉴权类型只实现足以通过 key/namespace/revoke 测试的最小接口，不构建完整登录系统。

## 6. 明确禁止进入 0a

```text
DerivedEncoded writes
Analysis cache or model execution
206 / Range resume
stale-while-revalidate / stale-if-error
complete external HTTP corpus gate
multi-process or App Group shared store
namespace/category quota and full GC
UIKit + AppKit + SwiftUI 三套 UI
animation / progressive preview product path
HDR / gain map / spatial attachments
SVG or third-party native codec
Trust / C2PA / JPEG Trust
Adaptive advisor / learned cache / prefetch
FoveaLab dependency
public stable API or compatibility promise
```

若实现需要上述能力才能继续，必须提交 blocker evidence：失败测试 ID、编译/运行日志或最小复现，并通过 ADR 收窄或修改本表。

## 7. 0a PR 审查问题

每个 PR 必须回答：

1. 修改是否属于 §4 的允许符号？
2. 是否引入了 §6 的后移能力或空抽象？
3. 是否形成第二套 identity、HTTP 状态或 cache ownership？
4. 是否可以删掉某个协议并用 concrete type 完成 0a？
5. 是否新增依赖、全局状态、隐藏 I/O 或无界任务？
6. 对应哪些 `TEST_CATALOG` ID？
7. 删除该 PR 后，垂直切片损失的唯一能力是什么？

无法给出具体答案时，PR 应继续拆分或拒绝。
