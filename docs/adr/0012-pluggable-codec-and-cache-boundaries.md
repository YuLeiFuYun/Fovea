# ADR-0012：可插拔 Codec、独立 ImageIO 产品与渲染缓存边界

- **状态：Accepted**
- **日期：2026-07-27**
- **修订关系：**修订 ADR-0011 中“codec contract 保持 package-only、首个外部后端只能由包内 adapter 映射”的可见性决策；ADR-0011 的能力代数、资源准入、身份隔离和失败关闭规则继续有效。

## 背景

Fovea 的核心价值是网络获取、身份、缓存一致性、资源准入、共享任务、诊断和平台显示生命周期，而不是绑定某一个图像解码实现。ImageIO 当前是成熟且覆盖 Apple 平台的默认实现；AxiomRaster 尚在开发，未来可能在部分或全部格式上成为默认；用户也可能选择其他 codec。

此前 `ImageDecoding` 虽然可以注入最低功能 decoder，但精确能力描述、资源估算和 prepared-state 复用仍是 package-only。结果是第三方后端可以“工作”，却不能完整参与 Fovea 的能力协商、缓存身份和保守资源准入。另一方面，RenderedMemory 直接绑定内部 SIEVE 实现，官方安全组合根也只接受固定 ImageIO decoder。

该状态不满足以下目标：

1. FoveaCore 只依赖稳定的 codec contract，不依赖 ImageIO；
2. ImageIO 可以独立发布、测试、优化和回滚；
3. AxiomRaster 完成后可以通过一次默认装配变更接替 ImageIO，而不迁移原始编码缓存；
4. 用户可以替换渲染缓存，同时不能绕过 namespace、generation 和 codec fingerprint；
5. 插件化不能退化为全局可变 registry、运行时随机选择或弱化安全边界。

## 决策

### 1. Codec contract 是独立公共产品

`ImageCraftCore` 作为单 target SwiftPM library product 发布，公开：

- `ImageDecoding`：最低 probe/decode 契约；
- `ImageCodec`：稳定 descriptor、有限能力集合和资源估算；
- `PreparedImageDecoding`：一次性 prepared state 的可选高性能路径；
- capability、failure、resource、generation、timing 和输出值类型。

FoveaCore 只依赖 `ImageCraftCore`。codec 不获得 URL、HTTP header、security namespace、持久提交、UI 或诊断后端权限。

未采用 `ImageCodec` 的 legacy `ImageDecoding` 实现仍可使用，但只能获得按动态类型隔离的保守 descriptor 和 host 通用资源估算。完整插件应采用 `ImageCodec`，否则不能声明更强能力。

### 2. ImageIO 是独立参考实现

`ImageCraftImageIO` 作为单 target SwiftPM library product 发布，只依赖 `ImageCraftCore`。它不依赖 FoveaCore、FoveaHTTP、Akashic 或平台 UI。

顶层 `Fovea` 产品现阶段包含 `ImageCraftImageIO`，且 `FoveaSystemPipeline.open` 的默认 decoder 为 `ImageIOImageDecoder()`。因此普通用户仍只需导入 `Fovea`；需要独立使用或测试 ImageIO adapter 的调用方可以直接依赖 `ImageCraftImageIO`。

AxiomRaster 达到默认门后，只需改变官方组合根的默认 decoder。原始编码数据和 HTTP 表征记录不绑定 decoder；DecodeKey/RenderKey 已包含 codec fingerprint，旧派生像素不会与新后端碰撞。

### 3. 选择是显式、不可变的装配决策

`FoveaSystemPipeline.open` 接受可替换的：

- `decoder`；
- `transformer`；
- `renderedImageCache`。

更底层的 `FoveaPipeline` 继续接受自定义 transport、原始编码存储、表征记录存储和安全策略。所有组件只在 composition root 注入，并在 pipeline 生命周期内冻结。

当前不引入全局 mutable registry、按请求动态切换、基于负载的“最快后端”猜测或隐式 fallback 链。第二个生产后端出现后，如确有一个 pipeline 内多后端选择需求，再以独立 ADR 定义确定性 policy。

`FoveaPipeline.codecDescriptor` 公开当前实际装配后端的只读描述，供诊断、证据和 rollout 检查；它不是修改入口。

### 4. Prepared state 是公开的可选快路径

`PreparedImageDecoding` 与 `ImageDecodePreparation` 公开。实现必须满足：

- preparation 与具体 decoder 实例绑定；
- 令牌一次性消费；
- probe、limits 或实例不匹配时失败关闭；
- 准入失败、取消或不再需要解码时可幂等 discard；
- prepared state 不能把未验证字节或裸指针泄漏给 Fovea。

Fovea 在支持该协议时复用 preparation；否则回退到普通 probe/decode，不改变正确性。

### 5. RenderedMemory 使用公共缓存契约

`RenderedImageCaching` 是同步、线程安全、线性化的热路径协议。键为 `RenderedImageCacheKey`，强制包含：

- `SecurityNamespaceID`；
- `NamespaceGeneration`；
- 完整 `RenderKey`，其中含 content、geometry、color、transformer 和 codec fingerprint。

自定义实现不得忽略任一字段。协议支持读取、插入、单项删除、谓词清理、完整清理摘要、成本与条目计数。

默认实现仍为基于 Akashic `MemoryCache` 的 SIEVE 缓存。该实现是策略默认值，不是 Fovea 语义的一部分。

协议保持同步是刻意选择：RenderedMemory 命中位于滚动显示热路径，不能强制 actor hop。异步或持久型第三方缓存应在前方提供同步、锁保护的内存层，再把慢工作委托给后端。

### 6. 不把所有内部状态都做成插件

以下状态继续由 Fovea 内部拥有：

- request→render alias；
- transport-verified transient handoff；
- namespace revocation barrier；
- shared-task registry；
- original/record commit transaction。

它们不是普通替换策略，而是跨层正确性状态机。开放替换会允许插件绕过 no-store、授权隔离、提交顺序或取消语义。

### 7. ImageIO 当前优化

ImageIO prepared 路径在 probe 时创建并验证 `CGImageSource`，decode 时复用同一不可变 source，不再重复：

- `CGImageSourceCreateWithData`；
- source type 识别；
- frame count 读取。

创建 source 时根据已完成的有界容器扫描传入 type identifier hint。数据仍由 preparation store 持有，保证 source 生命周期；一次性 `take` 在锁内移除条目，防止并发双消费。独立库的 `decode(data:request:limits:)` 便利入口也直接复用同一次 inspection，不再先 `probe` 后由另一个重载重新扫描容器、重建 source 和重读属性。

该优化只消除已证明重复的 ImageIO 工作，不放宽容器、metadata、dimension、pixel、frame、color 或 trailing-byte 校验。

## 默认后端迁移门

AxiomRaster 或其他 codec 成为默认前，至少必须：

1. 通过公共 contract/conformance suite；
2. descriptor 不夸大能力；
3. malformed corpus、fuzz 和 sanitizer 无未处置故障；
4. probe、像素、orientation、color 和 metadata 差异全部分类；
5. 资源估计不低于实测峰值加安全余量；
6. prepared/cancellation/discard 生命周期无泄漏；
7. codec fingerprint 与派生缓存隔离测试通过；
8. 在同设备、同 corpus、同质量参数下给出延迟分布、CPU、峰值 RSS 和能耗证据；
9. canary、关闭开关和 ImageIO 回滚演练通过。

默认迁移不删除 ImageIO 产品。至少一个稳定发布周期内保留显式 ImageIO 回退能力。

## 后果

- FoveaCore 不再依赖具体 codec；
- ImageIO 与未来 AxiomRaster 可以独立版本化和比较；
- 普通用户保持单一 `Fovea` 导入路径；高级用户可只依赖 contract 或指定 adapter；
- 自定义缓存可以替换算法和存储实现，但不能改变安全身份；
- public API 增加，需要精确 DocC 预算、兼容性审查和 contract version 治理；
- 显式注入比 registry 更简单，但同一个 pipeline 暂不支持按格式自动选择多个后端；
- ImageIO 优化必须继续以正确性、资源和真机数据为约束，不能用单一 microbenchmark 宣称整体最优。

## 验证

- **CODEC-PT-010**：外部公共 `ImageCodec + PreparedImageDecoding` 驱动完整 FoveaPipeline；
- **CODEC-PT-011**：官方组合根接受自定义 codec 与渲染缓存，并公开实际 descriptor；
- **CODEC-PT-012**：官方组合根的默认/新入口要求完整 `ImageCodec`，旧 decoder 必须通过显式 `legacyDecoder` 兼容边界并获得 legacy descriptor；
- **CACHE-PT-043**：自定义 `RenderedImageCaching` 接管插入、命中和 purge；
- **DIAG-PT-014**：ImageIO prepared decode 与普通 prepared decode 结果一致，且重复 source/type/frame 阶段耗时为零；
- capability 有限域、资源上界、identity 分离和 unsupported failure 继续由 ADR-0011 的模型与测试验证；
- Release 二进制、完整 Swift 套件、DocC、架构边界、结构质量和生产覆盖持续作为合并门。
