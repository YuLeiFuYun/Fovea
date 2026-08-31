# 动画图像解码与播放策略

> **状态：ImageCraft codec foundation、Fovea package-internal 授权编码 preparation seam、player/runtime、UIKit/AppKit/SwiftUI presentation 与 progress-only live MJPEG 系统链已在本地实现；真实 ImageCraft adapter、固定 revision 加载和物理设备 W5 证据仍待完成。**

## 1. 目标

动画不是“多张静态图数组”。ImageCraft 当前已经实现 GIF、APNG 和上层预分帧完整 JPEG sequence 的独立动画契约；progressive JPEG 仍是单幅图渐进扫描，不能冒充 JPEG 动画。帧时序、loop、canvas、disposal/blend、增量解码、帧缓存和可见性共同决定正确性与资源成本。Fovea 不默认把所有帧完整解码进内存。

当前未发布候选绑定 ImageCraft source identity `7d0a1d3cc1b7e64eef11372582dbd67ff6d26bb0186d75dfca0c3528c454f37f`（265 files）。`IMG_ANIM_PT_001`–`IMG_ANIM_PT_026`、101/101 根测试、warnings-as-errors Release、clean-copy、外部 consumer 三平台、仓库 platform matrix、独立 oracle 与 corpus reproducibility 均通过；相对 `0.1.0-alpha.5` 的 public API delta 为 105 added / 0 removed / 0 changed。该 source identity 不是可固定依赖的 Git revision，Fovea 仍固定在 `736d0fb75e9e128642ce418ad984ce5151b1f324`，因此不能据此宣称 GIF/APNG 已接入。

Fovea 当前新增的是 decoder-neutral 的授权编码 seam，而不是 ImageCraft GIF/APNG adapter：原编码从网络或 reusable cache 返回时同时携带 ContentID、fetch-base、完整 request-execution、可选 Vary representation 与 namespace generation；decoder preparation 后再次执行 ACL、授权、请求身份和 generation 校验。provider 只有在 runtime 注册成功后才转移所有权，任何取消、身份、codec、容量或撤销失败都会取消 provider。runtime 记录 revocation generation floor，使撤销与注册并发时旧 generation 的静态和 live 会话都无法事后注册。

授权资产还绑定 `ImageRequest.renderAliasIdentity`，覆盖完整 request execution、target pixels、content mode、geometry policy 与 color policy。即使 URL、凭证和编码字节相同，按一个目标准备的 provider 也不能被另一个目标请求重新标记；`W5_PT_124` 固定该反例。

## 2. 动画表示

```text
AnimatedImageAsset
├── ContentID
├── canvas pixel size
├── frame count
├── loop count
├── frame timing table
├── disposal/blend metadata
├── decoder fingerprint
└── frame provider / decode window
```

动画对象与静态 `DecodedImage` 使用不同的缓存 value 类型和 cost model。第一帧可以作为静态 fallback，但不能冒充完整动画结果。

## 3. DecodeKey

动画 DecodeKey 至少加入：

```text
ContentID
+ target pixels
+ color/dynamic-range policy
+ animation policy version
+ timing normalization policy
+ frame decode strategy
+ decoder fingerprint
```

改变 frame timing clamp、静态化策略或 target pixels 必须自然 miss。

## 4. 帧策略

候选模式：

```text
firstFrameOnly
streamingWindow
boundedFrameCache
predecodeAll（显式允许，或在可证明成本边界内由 automaticWholeTrack 选择）
```

默认根据：

- canvas bytes；
- frame count；
- 帧依赖/disposal；
- 可见性；
- platform profile；
- 当前 memory pressure；

选择受控窗口。显式策略保持调用方合同；`automaticWholeTrack` 只有在 decoder/preparer 同时提供 whole-track decoded resident、provider-retained 和 predecode peak 三项保守上界时才可升级为 `predecodeAll`。caller 的 `maximumDecodedByteCost` 只约束 decoded frame bytes；运行时 resident gate 约束 decoded + provider-retained 稳态总和，predecode peak 另受共享 decode working-set 上限约束。任一证明缺失或超限都 fail closed 到 `boundedFrameCache`。已知 provider-retained 成本独立于策略：即使 automatic 回退或调用方显式选择 fixed/bounded，该 provider 生命周期内的 payload/palette/checkpoint bytes 仍必须占用动画 resident budget。

## 5. 时序正确性

- decoder 保留格式中的精确有理数 delay；任何最小时长 clamp 属于版本化播放策略，不在 codec 中静默修改；
- 0、负值、NaN 或极端短 delay 使用版本化的安全 normalization policy；
- normalization 不能作为无版本“经验规则”隐藏在 decoder 中；
- 播放调度使用 monotonic clock；
- 丢帧时按 timeline 前进，不通过无限加速追帧；
- 后台恢复后默认从合理时间点继续或重启，策略显式。

## 6. 生命周期

- offscreen 默认暂停播放并释放非必要预解码帧；
- view 消失取消 UI subscriber，但 OriginalEncoded 是否保留由普通缓存策略决定；
- App background 默认暂停动画 decode/display；
- memory pressure 下缩小 frame window；warning 同时推进 publication generation，禁止 warning 前已在飞的 normal-window 解码结果重新填充缓存；critical 时退化第一帧或停止；共享帧缓存禁止按单 view 直接破坏性裁剪；
- 静态动画提供 `.firstFrame`/`.playOnce`/`.normal`；live MJPEG 在 Reduce Motion 下默认发布源第一帧后关闭 transport，只有显式 `.preserveLiveMotion` 才继续；
- 多个 view 显示同一动画可以共享 encoded/container metadata，但 playback clock 默认独立，除非显式同步。

## 7. 缓存

- OriginalEncoded 按普通规则缓存；
- container metadata 可进入 MetadataMemory；
- 解码帧使用独立 `AnimationFrameMemory` 预算，不与静态 RenderedMemory 混成一个对象 cost；已知的 provider-retained payload/palette/checkpoint 上界按 handle identity 在同一 resident budget 中不可逐出地 reserve，普通 SIEVE frame 可为它让位但 active compositor pin/其它 provider reservation 不可被挤掉；provider 输出先验证目标尺寸与单帧实际 `estimatedByteCost` 可驻留性；首批之后使用已观察最大实际帧成本夹紧 upcoming window；
- frame cache key 包含 frame index、target/representation policy 和 decoder fingerprint；
- 不把播放当前位置、view clock 或 dropped-frame 状态持久化；
- DerivedEncoded 默认不为每帧生成独立文件。

## 8. 安全限制

除通用 DecodeLimits 外，ImageCraft 已实现 `maximumTimelineDecodedBytes` 与 `maximumFrameDecodeWindow`；Fovea 播放层同时限制：

```text
maximumCanvasPixels
maximumFrameCount
maximumTotalDecodedFrameBytes estimate
maximumLoopWork for preview/testing
maximumMetadataPerFrame
```

畸形 disposal、越界 frame rect、递归附件或异常 timing 返回结构化 decode/security error。

## 9. 可观测性

记录：

```text
frame strategy
frame cache bytes/hit rate
frames decoded/displayed/dropped
average decode lead time
presentation targets accepted/consumed/superseded/nonmonotonic-rejected/lifecycle-cleared
pause/resume reason
memory-pressure degradation
```

不记录资源稳定摘要或私有 URL。

## 10. 测试

1. GIF/APNG 的 timing、loop、disposal 与参考实现一致；
2. 大动画不执行无界 all-frame decode；
3. offscreen/background 停止帧工作；
4. memory pressure 缩小窗口且不崩溃；
5. 第一帧 fallback 不污染完整动画 DecodeKey；
6. 多 view 独立 clock 不互相改变进度；
7. timing policy 变化使缓存自然失效；
8. cancel/seek/finish 竞态不 double-complete；
9. malformed frame rect/timing 被安全拒绝；
10. frame cache cost 与真实 bytes 基本一致。


## 11. 当前实现与接线边界（2026-08-05）

ImageCraft 本地工作树已完成：

- GIF GCE、Netscape loop、image descriptor 和 sub-block 的有界解析；
- APNG `acTL`、`fcTL`、`fdAT` sequence、frame rect、rational delay、disposal 和 blend 的有界解析；
- 上层预分帧完整 JPEG sequence 的尺寸、方向和颜色配置一致性检查；
- 验证后的 ImageIO source 复用、单帧按需解码、最多 8 帧的默认连续窗口和整体取消；
- 静态 PNG/JPEG 误入动画入口、越界 rect、保留 disposal、sequence gap、总轨道字节和敌意帧索引的失败关闭测试。

FoveaCore 本地工作树已完成 package-internal、decoder-neutral 的播放内核：

- `AnimationDecodeKey` 绑定 content、target、geometry、color、codec、timing policy 和 frame strategy；
- `AnimationPlaybackTimeline`/`Cursor` 使用调用方提供的单调纳秒，支持精确边界、有限/无限 loop、play-once、first-frame、seek、dropped-frame 统计和非单调时钟失败关闭；
- `AnimationFrameMemory` 独立于静态 RenderedMemory，按真实 `DecodedImage.estimatedByteCost` 使用 SIEVE 预算，并绑定 namespace/generation/frame identity；compositor pin 与已知 provider-retained reservation 同属该 resident budget，provider reservation 直到对应 provider 完成取消才释放，critical frame purge 不伪造释放仍存活的 provider 状态；
- 窗口规划在 normal/warning/critical 压力下单调缩小，跨 loop 最多生成两个连续 range；首次无实际成本样本时仍使用帧数上限，观察到 `DecodedImage.estimatedByteCost` 后再以动画缓存容量/最大观察帧成本夹紧后续窗口，禁止把 `targetPixels × 4` 当通用硬预算；
- 多 view 默认共享帧但保持独立 clock；offscreen/background/explicit pause/critical pressure 可叠加，恢复后不追赶暂停期间墙钟；
- provider 协调器串行化同一会话窗口解码，验证完整 frame index 集合，并用 publication generation 拒绝 seek、暂停或取消后的迟到结果；`produce()` 在依赖 session 的 cross-actor await 返回后重新验证 cancellation + publication generation，禁止旧 invocation 在取消/撤销已经胜出后再创建 automatic whole-track predecode task。`W5-PT-175` 固定 queued-permit cancellation，`W5-PT-205` 用 64 个 yield delay 搜索 actor-reentrancy TOCTOU，并断言 provider call/cancel 与 peak used/queued 都收敛。

Fovea 官方 package-internal live MJPEG 链已经完成：

- `ImageRequest` 的 ACL、授权、destination 与网络策略在任何 transport 副作用前验证；
- live transport 与普通图片共享 `maximumConcurrentFetches` 和 queue permit，不存在第二套无界发网通道；
- URLSession 使用 progress-only capability：每个 chunk 在发布前执行硬上限与增量 SHA-256，不创建完整响应 staging；delegate 入队前 suspend、消费后 resume，严格 parser 要求每 part 唯一 `Content-Length` 和 `image/jpeg`；
- 每帧复用普通 `DecodeStage` 的 probe、codec capability、目标几何、颜色、工作集、取消与 namespace generation；
- latest-only session 只保留一个 encoded part，使用绝对 decode deadline，并显式统计 superseded frame；
- critical pressure 清除 pending encoded part且不保留新帧；namespace revoke 主动取消对应长连接；
- finite success/failure/queue rejection 自动注销 runtime，系统失效与未启动取消都关闭 transport；
- Reduce Motion 默认选择源 index 0、发布后关闭流，显式 preserve 才保持实时运动；
- UIKit/AppKit presenter 与 SwiftUI model 都复用 runtime handle、presentation generation、可见性暂停和替换取消；UIKit 使用 CADisplayLink.targetTimestamp，AppKit 在 macOS 14+ 使用 NSView.displayLink(target:selector:) 的 targetTimestamp external ticks、macOS 12–13 保留 absolute-deadline fallback；macOS 14+ 若初始 detached，则延迟 driver startup 到首次有效可见，使首帧仍由 runtime.start 立即发布而不是伪造 vsync。诊断只记录脱敏摘要和低基数 reason。

仍未完成：

- 发布并固定包含当前动画 API/owned APNG+GIF runtime 的不可变 ImageCraft revision，把已通过 source-overlay qualification 的 `EncodedAnimationPlaybackPreparing` adapter 移入 production FoveaSystem，并针对 exact clean pin 重跑资格验证；
- 在 production pin 上测量 encoded animation 的 end-to-end startup + steady-state compositor 资源端点，并把一次性 decoder/predecode 成本与长期 presentation savings 分开报告；
- Kingfisher/PINRemoteImage/Fovea player 级公平 A/B，以及支持的物理设备 deadline、内存、回收、能耗和热状态证据。

比较预注册见 `Benchmarks/ComparativeLab/animated-image-plan.json`。当前动画证据已扩展到 `W5_PT_205`；取消/自动整轨峰值竞态修复后 `AnimationPlaybackRuntimeTests` 24/24，通过 3 次连续 756/756 根套件 stress，并由 workflow controller 独立根验证；ImageCraft source-overlay adapter `W5_ADAPTER_PT_001`–`008` 通过 runner/validator/tamper contract，其中 PT_008 直接证明真实 owned GIF 在 automatic 回退到 bounded 后 provider-retained reservation 仍持续计费。production ImageCraft pin 仍不包含这些未发布动画 bytes，因此 `CH-ANIMATED-021` 继续保持 capability gap，不能升级为默认生产 URL/GIF/APNG 能力或领先结论。


## 12. 当前 W5 codec-only 方向性结果

`docs/research/w5-animated-codec-study-2026-08.json` 记录 6 个独立进程块、三方顺序轮转和格式顺序交替的本机矩阵。ImageCraft 与 PINRemoteImage 在 GIF/APNG 选中帧上逐字节一致；SDWebImage 在 26%–36% 像素上存在最多 2 LSB 的通道差，因此未通过预注册 exact-pixel 门禁。

exact-pixel 对中，ImageCraft/PIN 的 block-median 比值为：GIF prepare 0.691×、单帧物化 0.334×、24 帧物化窗口 1.032×；APNG prepare 1.130×、单帧物化 0.313×、24 帧物化窗口 1.019×。这是脏工作树、单 fixture、macOS codec-only 证据，不能替代 Fovea 网络、player、帧缓存、deadline、内存、能耗和物理设备端点。


## 13. live MJPEG latest-only 机制证据

`docs/research/w5-mjpeg-mechanism-study-2026-08.json` 记录 6 个独立进程 block、48 个内部顺序平衡 trial。每个 trial 使用 120 个、每个 4096 bytes 的 encoded frame 和相同的合成 SHA-256 decode work；accepted harness 在释放首个 gated decode 前要求 `inputFinished`、pending index 119 和 118 个 superseded frame。

latest-only 每次固定解码 2/120 帧，encoded queue peak 为 decode-every baseline 的 1/120，最终 source index 和像素摘要完全一致。paired elapsed ratio 的中位数为 0.0404×、p95 为 0.0924×、最大值为 0.1348×。该结果只证明高到达率下单槽 latest-only 的工作量上界；decode-every baseline 故意保留完整 burst、并非内存等价，且没有真实 JPEG codec、网络、display deadline、能耗、热状态或物理设备证据。

首轮未等待 ingestion 收敛的 harness 曾产生 2–4 次 decode，已登记为 `NEG-W5-MJPEG-MECHANISM-UNFENCED-INGESTION-001`，不得作为性能证据。

- 依赖错误枚举属于独立版本边界：Fovea 只对已采用的 ImageCraft error case 提供稳定显式 reason code；新依赖版本新增 case 必须先保守映射为 `unexpectedImageCraftFailure`，防止 exact-pin 升级因穷尽 switch 直接源码失编，再在正式 pin 采用时补齐产品级稳定映射。

- concrete ImageCraft adapter 的 timing normalization 失败必须发生在 handle 注册之前，并释放已准备的 decoder asset；`W5_ADAPTER_PT_004` 用有效 GIF + 零 replacement 验证 `invalidZeroDurationReplacement` fail-closed 且 runtime driver 数保持 0。

- Display-target diagnostics must remain measurement-only: UIKit `FoveaImageView` exposes a `_spi(BenchmarkDiagnostics)` SPI snapshot for accepted/consumed/superseded/nonmonotonic-rejected/lifecycle-cleared target counts, pending/last-target, display-link pause and effective visibility. AppKit macOS 14+ exposes the same bounded target-buffer snapshot package-scoped to `FoveaAnimationMacLab`; this does not widen ordinary public API. A fixed-six/no-retry Release mechanism capture validates hidden-zero-target/provider work, resume recovery and cancellation. W5_PT_145-148 additionally bind a package-only automatic-deadline control, common refresh observer and exact playback-start clock anchor. The final fixed-six-pair/no-retry physical-Mac A/B samples both schedulers on `NSView.displayLink.timestamp`: all six pairs have no-worse external start-anchored p95 error and source-frame skips, with 14.102375 ms versus 75.461355 ms median p95 and 0 versus 82 total skips. This is one-host committed-frame refresh evidence, not hardware scanout or energy/thermal evidence; physical Mac energy/thermal and stable physical iOS remain pending. Physical evidence must report refresh-buffer counters separately from timeline `droppedFrameCount`; ordinary public API must not depend on them.

- 动画生命周期监听不得隐式扩大 `FoveaUIKit` ordinary public symbol budget：`isHidden`/`alpha`/`didMoveToSuperview`/`layoutSubviews` 的 override 仅作为 `_spi(AnimationLifecycle)` 实现细节；`scripts/check-foveauikit-api-budget.py` 必须证明默认 symbol graph 仍为 12/12、SPI graph 包含诊断/override、且普通非-SPI consumer 仍可通过 `UIView` 继承面调用这些成员。

- External presentation lifecycle sampling must never move behind a previously accepted future `CADisplayLink.targetTimestamp`. `W5_PT_144` binds the driver rule `max(clock.now, lastAcceptedPresentationTarget)` for lifecycle/seek/restart/pressure mutations; cursor non-monotonic rejection remains fail-closed elsewhere.
