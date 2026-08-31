# 图片加载管线参考审计（2026-07）

> **状态：Research。** 本文记录参考来源、观察和取舍，不构成稳定 API 承诺。

## 1. 参考基线

本轮审计固定到以下上游提交，避免“参考最新版”成为不可复现叙述：

| 项目 | 审计提交 | 重点 |
|---|---|---|
| Nuke | `63a8fcbd6621340a2410bc3e9575ac97058615f4`（13.0.6） | pipeline、request options、prefetch、metrics、UI |
| Kingfisher | `410984bf301f4fa224fe56277b3f8672cc465c79`（8.11.0） | downloader/cache、request modifier、processor、SwiftUI |
| SDWebImage | `2de3a496eaf6df9a1312862adcfd54acd73c39c0`（5.21.7） | 多 loader/cache/transformer、平台覆盖、示例生态 |
| PINRemoteImage | `c0d5cfa1947f2456ddb321a85b347b3d60d83254` | 下载优先级、任务合并、渐进加载、缓存 |

平台语义以 Apple 官方 `URLSessionConfiguration`、`URLRequest`、`URLSessionTaskMetrics`、ImageIO 和 Swift Concurrency 文档为首要依据；RFC 9110/9111 决定 HTTP 语义。

## 2. 结论

Fovea 在 namespace 撤销、HTTP record、持久发布、目标像素准入和证据治理上形成了较强的局部契约，但在生态成熟度、格式覆盖、prefetch、平台样例、真实应用验证和长期 API 稳定性上仍明显落后于成熟项目。因此不能声称整体超越或“世界最好”。

本轮补齐的能力：

- 请求级 cellular/constrained/expensive 权限进入精确执行身份；
- 官方 URLSession 会话具备明确的连接等待、超时和每主机连接上限；
- URLSession 事务摘要暴露 task 总时长、redirect、协议、连接复用、代理、网络成本标记与可选阶段时长，但不暴露 URL、IP 或 header；
- 解码按保守 working-set 估算进行带权准入；
- Profile ACL 在缓存和网络访问前 fail closed；
- 可编译 Gallery、交互默认真实图片、自动化默认确定性的 FoveaWorkbench，以及计划任务/完成门使用的多 origin HTTPS 实验。

## 3. 为什么没有加入通用拦截器 DAG

成熟库普遍提供 request modifier、delegate 或 processor 扩展点。这些能力有价值，但直接照搬到 Fovea 会产生两个风险：

1. 在 key 冻结后修改 URL、header、网络权限或授权语义，会使实际请求与缓存/共享身份不一致；
2. 任意用户回调进入 actor、锁或 commit 区间，会破坏取消、重入和故障边界。

当前策略是使用有类型的窄接缝：不可变 `ImageRequest`、`ImageRequestNetworkPolicy`、`ProfileAccessPolicy`、`RefreshingImageLoader`、`ImageTransforming`、`HTTPTransporting` 与显式 composition root。未来若加入 request preparer，必须在 key 冻结前运行，或提供版本化、非敏感 execution fingerprint；不得提供无法审计的 post-key mutation。

## 4. 网络路由与代理假设

- 官方 transport 使用系统 `URLSession` 路由，遵循系统代理/PAC/VPN；不自建 socket，也不绕过代理。
- 远程图片默认只允许 HTTPS；明文 HTTP 仅限精确 loopback host，用于可控本地 origin 和确定性协议实验。
- 自定义 `URLSessionConfiguration` 默认 `.taskLocal`，因为代理、`URLProtocol`、client identity 和共享 session state 可能改变响应语义。
- 调用者显式启用复用时，context identifier 必须覆盖这些语义，但不得包含秘密。
- 请求级 constrained/expensive/cellular 权限不会进入持久缓存身份，但必须进入 exact execution identity。
- Fovea 当前不实现自定义代理池、按域路由器、SOCKS 隧道或网络沙箱；这些属于宿主/系统网络栈责任。

## 5. 尚未达到的证据

- 与 Nuke、Kingfisher、SDWebImage 在同一真机、同一数据集、同一网络条件下的预注册比较；
- 真实应用长期滚动、后台/前台、内存警告与账户切换试用；
- HTTP/3、复杂企业代理、TLS client identity、VPN 切换和网络路径变化矩阵；
- 动图、AVIF/JXL/SVG/HDR 等成熟格式覆盖；
- 端到端能耗、CPU 时间、峰值 RSS 和主线程 trace；
- 独立维护者对全部 R3 契约的理解签署与外部审计。
- ImageIO incremental source 已进入 candidate provenance；生产渐进解码仍需完成 preview cadence、累计数据上限、working-set、取消和最终身份一致性设计与测试。

这些缺口存在时，任何“世界最好”结论都不成立。
## 6. 2026-07-20 上游能力复核

当前官方资料仍显示：Nuke 13 已把 request coalescing、优先级、prefetch、resumable download、progressive JPEG、HEIF/WebP/GIF 和 SwiftUI 作为成熟产品能力；Kingfisher 8 提供多层缓存、处理器、预取、Low Data Mode、SwiftUI 与 Live Photo；SDWebImage 提供 progressive/animated image、thumbnail decoding、多 cache/loader 与广泛 coder 插件。Fovea 不得把这些通用能力描述为独占创新。

可继续验证的差异候选限定为：namespace revoke commit fence、persistent/execution identity 分离、分配前资源预算、bounded HTTP metadata、tree-bound mutation/evidence。它们必须通过同设备 adapter 实验或对照行为测试，不能仅凭架构叙述升级为 superiority claim。

参考入口：

- https://github.com/kean/Nuke
- https://github.com/onevcat/Kingfisher
- https://github.com/SDWebImage/SDWebImage
- https://developer.apple.com/documentation/imageio/cgimagesource


## 7. 2026-07-25 精确适配器复核

Comparative Lab 已以完整提交固定 Nuke 13.0.6 与 Kingfisher 8.11.0，并为 Fovea、Nuke、Kingfisher 建立同一 `ComparatorAdapter` 契约。三者分别编译，避免一个 App 同时链接多个图片库造成启动、二进制和全局状态污染。

当前只可确认：

- Nuke 的 async task、像素 thumbnail、memory/data cache 和取消可映射；
- Kingfisher 的 DownsamplingImageProcessor、独立 cache/downloader、共享下载取消和 cache source 可映射；
- Fovea 的显式 target、稳定 logical source、结构化 failure 和 Swift Task 取消可映射；
- dirty Fovea 构建必须绑定 tree digest，不能只写 HEAD；
- Kingfisher 固定源码在 Xcode 27/macOS 27 SDK 下会产生 UTI deprecated 和捕获语义警告；适配器自身无警告。

这些是 adapter 可执行性证据，不是 W1/W2/W3 胜负结论。正式结论仍需真机 App、相同数据集和 trace、交错重复、外部 Instruments/网络计量与置信区间。

## 8. 2026-08-09 Revision 36：一等 prefetch 与扩展竞品差距复核

本轮不再把“成熟项目有 prefetch、Fovea 没有”停留在审计结论，而是将这一高频产品缺口收敛为 `FoveaPipeline.prefetch(_:maximumConcurrentRequests:)`。实现没有建立第二套 downloader、cache 或 permit pool：每个唯一请求仍走 `image(for:)`，因此继续受既有 request identity、namespace/auth、shared-task coalescing、动态优先级、HTTP/cache、decode/transform resource admission 与 cancellation fence 约束。

### 8.1 当前可执行契约

Revision 36 的 prefetch 具有以下可机械验证的边界：

- 在 batch 入口按稳定 `displayIdentity` 去重，并保留第一个请求；不同 security namespace 不会被合并；
- 调用方给出的 batch fan-out 与 `PipelineConfiguration.maximumConcurrentFetches` 共同形成上限，不创建无界任务集合；
- prefetch 优先级使用 `min(originalPriority, .low)`：normal/high/user-initiated 被降到 low，但已经是 background 的请求不会被反向抬高；
- 可见的高优先级订阅者若加入同一 shared task，可把同一底层 transport 从 low 提升到 user-initiated，而不是启动第二个下载；
- 单项 HTTP / decode / transform 失败只计入该项，不中止其余批次；父任务取消时停止继续调度，并在所有子任务收敛后以取消结束，而不是返回“成功 aggregate”；
- 成功 prefetch 后，同身份 `onlyIfCached` 可直接消费已预热结果，不需要再次网络请求；
- 返回值只暴露 requested / unique / success / failure / cancellation 计数，不把像素、凭证、URL 或底层错误对象带出批次边界。

本地机械证据：新增 `ImagePrefetchingTests` 8/8 通过；既有动态 priority regression 1/1 通过；一次严格 root `swift test` 为 764/764、0 failure；controller 事务应用后独立 root 再次为 764/764、0 failure。此前使用 HTTP 500 的 failure-isolation oracle 曾观察到第三次 transport 调用，原因是既有 retry policy 正确重试 5xx；测试随后改用非重试型 404，只隔离验证 batch failure semantics，没有削弱生产重试策略。

### 8.2 固定源码的 prefetch 机制对照

为避免“看 README 猜实现”，Nuke 与 Kingfisher 仍使用本仓库已固定的源码快照逐行比较；adapter 文件保持只读，不把其它并行 dirty work 归入本次 workflow。

| 维度 | Fovea rev36 | Nuke 13.0.6 固定源码 | Kingfisher 8.11.0 固定源码 |
|---|---|---|---|
| 默认并发 | 4，同时受 pipeline fetch 上限约束 | 2 | 5 |
| 调度形式 | structured async batch；完成一个再补一个 | `TaskQueue` + stateful `ImagePrefetcher` | serial prefetch queue + bounded active downloads |
| 默认优先级 | 不高于 low，且 background 不被抬高 | prefetcher 默认 low，并将请求 priority 替换为当前 prefetcher priority | 由 options/downloader 体系控制 |
| 同请求复用 | 复用现有 Fovea shared-task identity；可见订阅可动态提权 | 复用 pipeline；`TaskLoadImageKey` 防重复 | downloader/cache 体系复用，同 cache key 任务受 manager 管理 |
| batch 去重 | `displayIdentity`，包含 Fovea 的 namespace / execution 相关身份边界 | `TaskLoadImageKey` | source/cache-key 任务表 + cache skip |
| cache hit | 复用完整 `image(for:)`，render/original cache 均由现有 pipeline 裁决 | 启动前检查 pipeline image cache | 显式区分 memory / disk / none 并记录 skipped |
| 取消 | 父 Swift Task 结构化取消；不再调度后续项 | per-request stop、stop-all、deinit cancel | `stop()` 取消活动项并阻止后续调度 |
| pause/resume | **尚无一等 API** | 有 `isPaused` | 无同形 pause property；可 stop |
| 动态修改整批 priority | **尚无独立 batch handle**；可见请求可通过 shared task 提权 | 有，修改 prefetcher priority 会更新 outstanding tasks | 主要通过 options/downloader 控制 |
| data-only / disk-only prefetch | **尚无真正 durable encoded-only 模式** | 有 `.diskCache`，避免 image decode | 可利用 cache/original-image 选项，但模型不同 |
| 完成信息 | 聚合 counts，不暴露资源对象 | `didComplete` 无逐项数组 | skipped / failed / completed 资源数组 |

这个表不把“默认并发更大”当成性能优势；最优并发取决于网络、decode working set、设备热状态和下游消费速率。Fovea 的当前可证明差异是**资源上限与安全身份直接复用主 pipeline，且 prefetch 不会把 background 请求提升到 low；可见请求可以在不增加底层请求数的情况下提升同一 shared transport priority**。Nuke 在 pause、per-item stop、动态 batch priority 和 data-only destination 上仍更完整；Kingfisher 在 cache-skip 可观察性、逐项资源结果与成熟 UI prefetch 接入上仍更完整。

### 8.3 扩展到其它成熟项目后的差距

当前官方项目资料显示的能力重点继续作为产品方向参考，而不是跨平台 benchmark 结论：

- SDWebImage 的强项仍是 progressive/animated pipeline、thumbnail decoding、多 cache / loader、可组合 transformer，以及覆盖 WebP、HEIF、JPEG-XL、AVIF、SVG 等的大规模 coder/plugin 生态；
- PINRemoteImage 继续代表 iOS 上成熟的任务合并、优先级、progressive image 与异步 decode 路线；
- Coil 把 memory/disk cache、downsampling 与 lifecycle 自动暂停/取消作为默认性能能力；
- Glide 把 decode、memory/disk cache 与 resource pooling 组合为面向滚动流畅度的体系；
- Fresco 仍把两级 cache、progressive JPEG、animated GIF/WebP 与内存管理作为核心能力。

这些项目跨 Apple/Android 平台，不能直接用不同 runtime 的单次 wall-clock 数字排名。因此 revision 36 只把**可比较的机制**纳入差距清单；CPU、峰值 RSS、能耗、首屏/滚动延迟、网络字节、cache hit latency、prefetch-to-visible handoff latency 等胜负必须在同设备、同 fixture、同缓存状态、同并发和预注册统计口径下产生。

### 8.4 下一轮优先级：从“有 prefetch”到 Pareto 领先

Revision 36 关闭的是一等 full-image prefetch API 缺口，不是终局。下一批高杠杆差距按以下顺序处理：

1. **durable encoded-data-only prefetch**：在不 decode pixels 的情况下完成受 HTTP policy / namespace / generation 约束的 original-byte 持久预热，对齐并尝试优于 Nuke `.diskCache` 的资源语义；现有公开 `encodedData(for:)` 在 network miss 时明确不持久化，不能冒充该能力。
2. **HTTP Range / If-Range resumable original download**：Fovea 文档已经描述相关协议语义，但当前生产 source 尚未形成完整 resumable path；Nuke 已将 resumable downloads 作为成熟能力，因此这里仍是实质产品差距。
3. **stateful prefetch control**：只有在真实列表 workload 证明有收益时，再增加 pause/resume、per-item stop 或动态 batch priority handle；不能为了 API 对齐复制第二套 scheduler。
4. **隔离的 same-workload comparator harness**：新建本 workflow 自己拥有的 harness，读取固定 Nuke/Kingfisher/SDWebImage pins，不修改当前数百条外部/untraced work；统一记录吞吐、P50/P95 handoff latency、network bytes、decode CPU、peak RSS、energy proxy、cache hit rate 与 cancellation waste。
5. **codec/plugin breadth**：继续用 typed capability + versioned fingerprint 扩展，而不是照搬不可审计的任意 post-key plugin mutation。SDWebImage 的成熟 coder 生态是覆盖度标杆，Fovea 的目标是在相同格式集合上同时保持更严格的 hostile-input/resource contract。

长期目标是让 Fovea 在所有**已经建立同口径实验的可比较指标**上形成 Pareto 优势，并把任何落后指标继续转成可执行 objective。没有同设备/同 workload 证据时，不写“全面领先所有项目”；这条限制本身是防止 benchmark 选择性报告和错误优化方向的质量门。

## 9. 2026-08-09 Revision 37：validated-original prefetch

Revision 37 将 revision 36 的 full-image prefetch 扩展为两个显式 destination，而不是另起一套下载/缓存系统：

- `.renderedImage` 保留既有完整 `image(for:)` 语义；
- `.validatedOriginal` 只执行受现有 transport hard limit 约束的网络接收、HTTP/cache/Vary/auth/namespace/generation 校验，以及 codec 的 bounded probe/capability admission；验证通过后才发布 OriginalEncoded + RepresentationRecord，**不执行 pixel decode 或 transform**。

这条边界比“把下载字节直接塞进 disk cache”更严格：`no-store`、task-local transport、invalid/unsupported image probe 都不会形成 reusable original；父任务取消、namespace generation 变化和持久化事务失败继续 fail closed。成功持久化后，后续同身份 `onlyIfCached` 可不再联网，并在真实消费者到来时才进入 decode。一个专用 probe-only test codec 的 `decode` 永远失败：validated-original prefetch 本身仍成功，而随后 `onlyIfCached` 消费才在 decode stage 失败，由此机械证明 prefetch 没有偷偷做 pixel decode。

同时，revision 36 的 batch orchestration 被拆为小型 state/worker helpers。workflow-bundle 的同一 structural analyzer 对本轮关键函数给出的复杂度为：`prefetch=1`、`runPrefetchBatch=4`、`prefetchOutcome=4`、`performPrefetch=4`、`prefetchValidatedOriginal=7`、`reusableOriginalIsFresh=4`、`persistValidatedOriginalOnly=7`；全部低于当前新函数阈值 10。此前 final verify 唯一 transaction-owned quality regression（`prefetch=12`）因此被直接消除，而不是放宽 quality policy。

### 9.1 与固定 Nuke / Kingfisher 源码的机制差异

固定 Nuke 13.0.6 的 `ImagePrefetcher` 支持 `.memoryCache` / `.diskCache` 两种 destination；`.diskCache` 的核心价值是避免完整 image decode，并配有 pause、per-item stop 和动态整批 priority。固定 Kingfisher 8.11.0 的 `ImagePrefetcher` 则强调 bounded active downloads、cache skip、stop、retry，以及 skipped/failed/completed 结果；Kingfisher 的正常 retrieval 还可通过 `cacheOriginalImage` 保存 original data。

Fovea revision 37 当前可证明的差异不是“更快”，而是**持久 original 之前的验证边界更强**：它把 image probe、codec capability、HTTP cacheability、security namespace 和 generation fence 纳入同一 transactional publication path，并继续让可见请求与 prefetch 共用主 pipeline 的 priority/resource authority。这个安全/正确性差异不能自动推出吞吐、CPU、RSS 或能耗领先。

仍有三项明确差距：

1. **conditional revalidation**：validated-original 在 durable original 缺失/过期时当前使用无条件请求；若已有 stale ETag/Last-Modified，未来应复用 304 revalidation，减少网络字节。
2. **staged-file validation / measurement**：当前 staged transport body 在 `materializedBody()` 中通过 `Data(contentsOf:options:.mappedIfSafe)` 建立完整文件映射视图，而不是可以断言为“整份 heap copy”；随后 Akashic staging API 仍以 `Data` 为输入。真实 peak RSS / dirty-page / durable-write 成本必须先测量，再决定是否值得跨 ImageCraft/Akashic 增加 staged-file capability。
3. **stateful batch control / resumable transfer**：Nuke 的 pause/per-item stop/dynamic batch priority 与 resumable download 仍未被 Fovea 一等 API 覆盖；Fovea 只会在真实列表/弱网 workload 证明收益后增加这些控制，不为表面对齐复制第二套 scheduler。

### 9.2 本轮证据

本地 `ImagePrefetchingTests` 为 12/12，包含原有 bounded fan-out、priority promotion、namespace isolation、failure isolation 和 structured cancellation，以及新增的 validated-original persistence/no-decode、no-store rejection、invalid-probe rejection、task-local rejection。该 suite 额外执行 5 次 skip-build stress 均通过；`PriorityPropagationTests` 1/1 通过；一次 strict root 为 768/768、0 failure。controller 随后事务应用四个 task-owned Swift 文件，并独立执行 root `swift test`，再次得到 768/768、0 failure。

这些结果证明 revision 37 的语义与本地回归兼容，不证明跨库性能胜负。下一阶段若继续竞争性优化，优先选择能够同时降低网络浪费或峰值资源且不削弱 Fovea 安全身份模型的机制；所有“领先”结论仍要求同设备、同 fixture、同缓存状态、同并发与统一指标采集。

## 10. 2026-08-09 Revision 38：validated-original 条件再验证

Revision 38 消除了 revision 37 已明确记录的 conditional-revalidation 缺口，但只在 `.validatedOriginal` 的既有安全边界内扩展，没有增加第二套下载器或缓存 authority。当前语义是：

- matching `RepresentationRecord` 仍 fresh 且 physical original 存在时，prefetch 零网络返回；
- stale record 只有在含 `ETag` 或 `Last-Modified` 时才作为 conditional record 进入现有 `FetchStage`，因此继续复用 Vary、credential-header fingerprint、namespace、generation、single-flight、retry 和 priority identity；
- conditional request 由现有 `FetchRequestPreparation` 写入 `If-None-Match` / `If-Modified-Since`，validator 只进入 revalidation execution fingerprint，不进入 persistent content identity；
- bodyless `304` 在 validated-original 路径只读取/验证已经持久化的 original、重算 HTTP refresh metadata 并原子刷新 representation record，**不执行 pixel decode 或 transform**；
- `304` 可以更新 ETag/freshness，但 `contentID`、`variantKeyDigest` 与 payload length 保持不变；
- `304 Cache-Control: no-store` 会撤销 reusable state，而不是继续保留旧 original；
- 如果 `304` 到达后 original body 已丢失或不可读，旧 record 先删除，随后最多进行一次无条件、受既有 transport hard limit 约束的 `200` recovery；recovery 重新走 revision 37 的 bounded probe/capability admission，验证成功后才持久化，仍不做 pixel decode。

### 10.1 机械证据

`ImagePrefetchingTests` 当前为 16/16。新增四个 oracle 分别覆盖：ETag conditional 304、Last-Modified conditional 304、304 no-store 撤销、304 后 cached body 缺失时的一次 unconditional probe-only recovery。ETag oracle 使用 v1→v2 validator 更新并断言刷新前后 `contentID`、`variantKeyDigest`、payload length 不变；第三次 validated-original prefetch 命中新 freshness 且不再联网。ProbeOnly test codec 的 `decode` 永远失败，因此 304 prefetch 自身成功、而随后真实 `onlyIfCached` 消费才在 decode stage 失败，机械证明 304 path 没有偷跑 pixel decode。

同一实验树还执行了 ordinary HTTP/cache regression：`PipelineTests + CacheCancellationTests + HTTPConformanceTests`（过滤表达式同时命中 `FoveaSystemPipelineTests`）共 41/41，覆盖现有 visible 304 content-ID reuse、304 no-store、304 missing-body unconditional recovery、WPT 304 matrix 与取消语义。一次本地 full root 为 772/772、0 failure；controller 对 task-owned 三个 Swift 文件事务应用后独立执行 `swift test`，再次得到 772/772、0 failure（XCTest 28.600 秒）。本轮关键新函数结构复杂度最高为 9，单函数最长 69 行，均低于当前 10 / 80 门槛。

这些测试中的 304 stub 是空 body，因此证明“304 path 不重新传入 encoded payload 到 Fovea transport result”；它不是互联网链路级字节计量，也不能单独推出真实网络能耗或吞吐胜负。

### 10.2 与固定 Nuke / Kingfisher / SDWebImage 源码的边界

固定 Nuke 13.0.6 的 Performance Guide 明确说明默认 L2 unprocessed-data cache 使用 native `URLCache`，stale response 由 Foundation URL Loading System 通过 `If-Modified-Since` / `If-None-Match` 条件请求与 `304 Not Modified` 完成 validation。这个机制成熟且符合 HTTP cache 语义；它的 authority boundary 主要在 native `URLCache`。Nuke 的 optional `DataCache` 是另一条 aggressive disk-cache 路径，并会关闭默认 `URLCache`。

固定 SDWebImage 5.21.7 的 downloader 源码默认使用 `NSURLRequestReloadIgnoringLocalCacheData` 来避免 `NSURLCache + SDImageCache` 双重缓存；启用 `SDWebImageDownloaderUseNSURLCache` 时才使用 `NSURLRequestUseProtocolCachePolicy`。`SDWebImageRefreshCached` 会把 cached image 先返回，同时给 `NSURLCache` 一次从服务器 refresh 的机会；其 downloader operation 还显式处理“server 304、URLSession/URLCache 可能呈现 200”的平台行为，以及没有 cached data 的 304 error。这里同样不能把 Foundation 行为误写成 SDWebImage 自己维护一套 persistent validator identity。

固定 Kingfisher 8.11.0 的 `ImageDownloader` 默认 `URLSessionConfiguration.ephemeral`；固定源码中没有直接的 `If-None-Match` 实现命中，original-data persistence 则由 `cacheOriginalImage` 等 Kingfisher cache 语义提供。这只证明当前固定源码的默认/显式机制边界；调用方仍可替换 session configuration 或 request modifier，因此不能写成“Kingfisher 永远不能 HTTP revalidate”。

Fovea revision 38 当前可证明的差异是：conditional validator、Vary/auth-aware representation selection、namespace generation、custom original store、content identity 和 no-decode validated-prefetch 被放进同一套**库自身可审计、可单元测试的 authority**，而不是依赖一个外部 HTTP cache 黑盒来决定这些 Fovea-specific identity/fence。这个正确性与可审计性差异仍不等于 P50/P95、CPU、RSS、energy 或互联网 network-byte 领先。

### 10.3 下一轮高杠杆差距

1. **staged-file / bounded-prefix measurement**：validated-original `200` 的 staged body 当前以 `.mappedIfSafe` 形成完整 `Data` 映射视图，ImageCraft 完整 probe 与 Akashic `stage(Data)` 仍要求完整数据抽象。下一步先用同 workload 测量 peak RSS、mapped/dirty pages 与写放大；只有证据显示它是瓶颈，才跨依赖演进 prefix/file-backed validation API。
2. **Range / If-Range resumable transfer**：对弱网或大图取消/重启 workload 建立明确 partial-byte ownership、validator binding、range completeness 与 hostile-server oracle 后，再加入断点续传；不能把 partial bytes 当成已经 validated original。
3. **stateful batch control**：Nuke 的 pause / per-item stop / dynamic batch priority 仍比 Fovea public prefetch control 更丰富。只有真实列表 workload 证明它优于当前 structured cancellation + shared priority promotion 时才增加 API，避免复制第二套 scheduler。
4. **isolated same-workload comparator harness**：继续把 Nuke/Kingfisher/SDWebImage pins 当只读 comparator，统一采集 P50/P95 handoff latency、network payload/wire bytes、decode CPU、peak RSS、energy proxy、cache hit rate、cancellation waste。没有同设备、同 fixture、同缓存状态和同并发参数时，不发布跨库“全面领先”结论。

Revision 38 因而把一个真实网络浪费缺口转成了可验证机制，并把下一阶段从 feature checklist 进一步收敛到**可直接测量的 peak-RSS/copy 与 resumable-byte waste**。长期目标仍是所有已经建立公平同口径实验的指标上形成显著 Pareto 优势；未建立实验的维度保持未知，而不是预设胜出。

## 11. 2026-08-09 Revision 39：validated-original 有界断点续传

Revision 39 把 Nuke 已成熟的一项真实网络能力吸收到 `.validatedOriginal`，但继续服从 Fovea 自己的 security/cache authority。它没有新增公开下载器：仅当 durable conditional record 不存在、transport 是 package-owned progress-observation implementation、且调用方没有自己提供 `Range` / `If-Range` 时，validated-original miss 才允许使用 pipeline-local partial state。

### 11.1 状态机与安全边界

失败/取消后的 prefix 只有同时满足以下条件才可进入 `ValidatedOriginalResumeStore`：响应为 identity encoding、`Accept-Ranges: bytes`、存在强 ETag 或可用 Last-Modified、正的完整 `Content-Length` 不超过 `maximumTransportBytes`、prefix 非空且未完整。弱 ETag 不可直接作为 `If-Range` validator；若同时存在 Last-Modified 则退到日期，否则禁用本次 resumable candidate。

partial store 默认最多 100 项、总计最多 32 MiB，FIFO 有界淘汰；key 绑定 exact request execution digest、security namespace 与 namespace generation。candidate 是 one-shot `take`，不会写入 OriginalEncodedStore、不会满足 `onlyIfCached`，也不参与 persistent content identity。下一次请求只把 `Range: bytes=N-` / `If-Range` 加入 transient execution，并把 resume fingerprint 加入 exact fetch execution key，防止 range fetch 与 ordinary fetch 误 single-flight。

server 返回 `200` 表示忽略或拒绝 Range：旧 prefix 被丢弃，当前完整响应按普通 validated-original 处理。server 返回 `206` 时，Fovea 只接受严格的 `Content-Range: bytes N-(total-1)/total`，其中 N 必须精确等于 prefix 长度、total 必须等于初始声明总长、suffix `Content-Length` 必须等于 `total-N`；错误起点、非终止 range、wildcard total、越界或长度不一致都 fail closed。成功时先拼接完整正文并重新计算整体 SHA-256，再把规范化后的完整 `200` 交回 revision 37/38 已有的 complete image probe / codec capability / namespace-generation / transactional persistence 路径。因此 partial 本身永远不是“已验证图像”。

### 11.2 机械证据与 payload-byte 结果

当前 `ImagePrefetchingTests` 为 24/24。核心续传 oracle 人工让第一请求只收到完整 PNG 的前缀后断线，确认此时 `onlyIfCached` 仍 miss；第二请求必须带精确 `Range` / `If-Range`，transport 只交付剩余 suffix，随后完整 reassembly + probe 成功。测试直接记录两次 payload byte count 为 `[prefixCount, fullBody.count-prefixCount]`，因此在该确定性 workload 下第二请求 payload 严格小于重新下载完整 body。另有 200 fallback、错误 206 无持久残留、不同 request identity 不串 candidate、namespace generation key 隔离、byte/count budget eviction、weak ETag 规则，以及“收到 prefix 后父任务取消→下一次安全续传”覆盖；成功续传与取消续传额外做了 5 轮 skip-build stress，共 10/10 selected tests。

相关 Identity / Retry / URLSession / Resource / Pipeline / CacheCancellation / HTTP conformance 回归在生产代码冻结后为 129/129。第一次高负载 full root 在一个未触碰的 SwiftUI 固定 10 ms 观察窗测试上出现 1 次 `empty` vs `loading`，其余 779 项通过；该测试随后独立 10/10，第二次 full root 780/780。controller 事务应用六个 task-owned 文件后独立 root 再次得到 780/780、0 failure（约 26.6 秒 XCTest）。这次孤立 timing 事件保留为环境/oracle 观察，没有通过修改非 task-owned SwiftUI 源来隐藏。

结构质量在生产代码最终版本上保持门内：新增/修改的 resumable parser、capture/store、FetchStage request preparation 与 coordinator helpers 均不超过 complexity 10 / 80 行。`TransportResponse` 的 package reassembly initializer 对完整拼接正文重新算 SHA-256，但 `metrics.receivedBytes` 保留本次网络实际 suffix bytes，为下一步同 workload network-byte comparator 提供正确计量基础。

### 11.3 与固定 Nuke 13.0.6 的差异

固定 Nuke 13.0.6 的 `ResumableData` / `TaskFetchOriginalData` 已实现非常实用的核心机制：取消或失败时，在 `Accept-Ranges: bytes` + ETag/Last-Modified 条件下保存非空未完整数据；下一次写入 `Range: bytes=N-` 与 `If-Range`；只有 `206` 才把旧 prefix 与新 data 拼接，`200` 则丢弃旧 prefix。其默认 resumable cache 也是 100 项、cost 约 1% physical memory 且 cap 32 MiB。这是 revision 39 直接借鉴的成熟设计。

Fovea 当前**可证明更严格的协议/隔离语义**包括：

- `If-Range` 不接受 weak ETag，必要时退到 Last-Modified；
- candidate key 显式绑定 exact execution identity + security namespace + namespace generation；
- `206 Content-Range` 必须同时精确匹配 start、terminal end、total 与 suffix `Content-Length`，而不是只以 status code 决定拼接；
- partial 永远不能满足 Fovea durable cache API；
- reassembly 后重新计算完整 content digest，并再次执行完整 image probe/capability admission，成功前不进入 OriginalEncodedStore。

这些是 pinned-source 层面可以机械验证的 fail-closed 差异。它们**不能**推出 Fovea 比 Nuke 更快、更省 CPU/RSS/energy。相反，Nuke 的 resumable implementation 已经经历成熟产品使用，Fovea 目前只建立了确定性本地 transport 证据。

### 11.4 下一步：从功能追赶切到同 workload benchmark

继续堆 feature 的边际收益已经低于建立公平 comparator。下一 revision 应优先构建 workflow-owned、与现有 parallel dirty comparator adapter 隔离的 loopback harness：对 Fovea 与固定 Nuke/Kingfisher/SDWebImage 使用同一图片、同一中断 offset、同一 cache state、同一并发和同一设备，至少记录 request count、payload/wire bytes、P50/P95 completion latency、CPU proxy、peak RSS、cache hit 与 cancellation waste。第一组 workload 就用“下载大图到固定 offset 后断线，再请求同一图”，因为 Fovea 与 Nuke 都有明确 resumable 语义，network-byte 指标可以直接公平比较。

只有 comparator 数据显示 Fovea 在某指标显著落后时，后续 objective 才针对该瓶颈优化；若 staged `.mappedIfSafe` / Akashic `stage(Data)` 确实造成 peak RSS 或写放大，再把 ImageCraft/Akashic file-backed capability 作为版本化跨仓改进，而不是预设它必然更差。这样“所有可比较指标显著领先”的长期目标由可重复测量驱动，而不是 feature checklist 或未经测量的零拷贝叙述。
