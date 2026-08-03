# 当前实现状态

> **权威性：当前实现事实。** 本页用于区分已交付能力、局部实现与候选设计；若与 Research 文档的愿景叙述冲突，以活动规格、Accepted ADR、代码和可执行证据为准。

## 跨仓 Conformance 状态

- `PersistentStoreProvider` contract v1 已通过独立生成的 SwiftPM consumer：5 项义务覆盖 descriptor、首次发布、无网络重开、持久撤销与有界打开参数。
- `ImageCodec` contract v1 已通过独立生成的 SwiftPM consumer：6 项义务覆盖 descriptor、2,304 项有限能力域、声明格式 probe/decode、资源估计组合与硬限制失败关闭。
- 两套 kit 都在 `ConformanceKits/current-contracts.json` 中登记为唯一当前契约，且 `releaseQualified: false`。
- 双组件候选组合门现使用 source identity v2 与 schema-4 组合报告：Fovea 不执行候选身份工具，而是独立验证外部身份文档、完整覆盖范围、精确排除、逐文件字节摘要与可执行位，再从已验证字节物化快照。候选 manifest、`package edit`、依赖检查和完整测试均在 `FOVEA-COMPONENT-CANDIDATE-SANDBOX-V1` macOS Seatbelt 中执行：网络、宿主源码读取、宿主写逃逸、候选快照写入及隔离 Fovea 源码写入由七个实际探针验证为拒绝，只有专用 State 写入成功；Fovea 不可变源码前后摘要一致，测试后两个组件身份再次一致。当前 Git-free 候选对（Akashic `5887e2facb07` / 84 文件、ImageCraft `045aa7013b19` / 94 文件）分别通过完整 release-readiness 与 clean-copy，隔离组合回归通过 478/478；六类身份负向样例仍在构建前被拒绝。该结果绑定 deprecated SwiftPM `native` build system，候选仍可读取隔离 Fovea 源码，因此不声明双向保密、默认 `swiftbuild` 等价或 release qualification。相同候选字节现已分别发布为 Akashic `2715f23d50b5`（`0.1.0-alpha.5`）与 ImageCraft `e147b349d4ff`（`0.1.0-alpha.4`），两个组件 GitHub Verify 均通过；Fovea protected CI 仍待本次根提交。
- 自宿主 fixture 通过不证明真实第三方实现、断电/崩溃一致性、跨进程 writer exclusion、hostile corpus、fuzz/sanitizer、真机资源或 Fovea protected qualification。

## 当前阶段

- 当前工程阶段是 **Phase 0b closeout**。Phase 1 准备已获准，正式阶段声明仍被机器状态拒绝；权威入口见 `PHASE0B_GRADUATION_AND_PHASE1_ENTRY.md` 与 `phase0b-status.json`。
- 跨会话连续性已由仓库接管：`docs/project-memory/` 保存来源摘要、讨论决策、长期要求、能力缺口和开放事项；`scripts/project-session-bootstrap.sh` 在任务开始前生成强制上下文，本地 `verify.sh` 与 CI 执行连续性和 workload 门。
- 完整 workload 路线是 W1-W15。W1-W3 已有旧五实现 Simulator baseline；W7 已具备版本化 1,000 请求 V6 runner，W10 已具备 Apple AsyncImage/Fovea 配对 SwiftUI surface。W4 渐进 JPEG、W5 动图、W6 完整中断恢复仍是明确 capability gap，其余 workload 继续按 registry 中的状态推进。`Adaptive Representation` 是辅助 X1，不占用 W4。
- Comparative Lab 的 A 级矩阵现为 Apple URLSession + URLCache + ImageIO、Apple AsyncImage、Nuke 13.0.6、Kingfisher 8.11.0、SDWebImage 5.21.7、PINRemoteImage `releases/p14.31` 与 Fovea。Apple headless adapter 已改为真正的 URL Loading System 协议缓存：`URLSessionConfiguration.urlCache` + `.useProtocolCachePolicy`，通过 `URLSessionTaskMetrics.resourceFetchType` 观测来源，不再手工查找或写入缓存；真实 loopback 测试证明首次 network、清空解码内存后第二次 disk，且 origin 只收到一次请求。W2 六项 headless 与 AsyncImage/Fovea SwiftUI surface 现共用同一 `NWListener` HTTP origin。六项 headless 实现绑定统一 request/target/cancel/result 合同；Apple AsyncImage 与 FoveaResponsiveImage 绑定同一 loopback origin、trace、采样器和配对 SwiftUI surface。AlamofireImage 4.4.0 降为 B 级补充，不能替代任何 A 级槽位。七项本地 target 均已构建。W7 V6 校准先揭示取消墓碑会误伤取消前已开始但较晚到达 registry 的 survivor cohort；admission-aware replacement cohort 修复已通过 SCHED-PT-021/022 与定向 Fovea W7。V6 随后还证明内部 permit grant 顺序不能直接等同于并发 URLSession 的 origin start 顺序；V7 保持内部八次 grant 上限，并将跨库黑盒上限按八槽并发严格推导为十五。最终六项 headless、双 SwiftUI 与 W7 V7 aggregate 仍需在不再变化的修复后 source-tree digest 下重跑，因此旧 25-run 五库 aggregate 和修复前聚合只保留为历史 provisional 证据。
- 当前唯一物理设备是 iPhone 16e / iOS 27 beta，角色为 `primary-current-mid`，已生成脱敏设备捕获；签名/provisioning 尚阻止正式 App 运行。beta 结果即使执行也只能标为 provisional；稳定 iOS 复跑和第二台较低性能真机仍是毕业硬条件。
- Cache Lab V4 保留 PINDiskCache 原生 D1 为描述项，并以独立 D5 proof wrapper 做同语义比较。V2 最终运行通过 12/13 项且存在计时边界不一致；V3 虽预生成 corpus，但计划声明 20 rounds、实现只执行 1 round，且最终仍有三个支配失败。V4 真正执行 20 个 fresh-cache rounds，将磁盘 p99 扩展到 8 轮、1536 个同步样本，并固定 8 分片。20 个独立 clean process block 的正式 campaign 在 13/13 个适用比较中跨过 20% 支配下界，正确性与统计失败均为 0。Akashic Git-free 候选又通过完整 release-readiness 和 Fovea 独立副本 478/478；Akashic 已发布为 `2715f23d50b5` / `0.1.0-alpha.5`，Fovea 已精确 pin 且公开 pin 回归 478/478；Fovea clean trusted CI、真实进程终止矩阵扩展和 held-out corpus 仍待完成。
- 统计声明策略已升级为 L1 hard / L2 primary portfolio / L3 secondary frontier / L4 research 四层证书。全局无边界 “world best” 声明被机器禁止；只允许绑定能力、workload、对手、设备/OS 与全部摘要的 `best-within-scope`、`noninferior-within-scope` 或共同 Pareto 前沿结论。
- 原生上游测试被独立保留，共 10 套：4 套通过、5 套失败、1 套因 iOS 27 UIScene 环境阻断。除既有 Nuke、Kingfisher、SDWebImage、AlamofireImage 结果外，PINRemoteImage 原始 iOS workspace 在仅覆盖 deployment target 后运行 62 项，2 个方法、7 个断言失败；源码和测试均未修改。失败不被 Fovea 语义移植测试覆盖或改写。
- 当前工作树含未提交改动。比较身份必须记录 HEAD、tree digest 和 dirty 状态；本地工件不能冒充 final commit 或 trusted CI 证据。

## 产品面

| 能力 | 状态 | 当前事实 |
|---|---|---|
| HTTP/HTTPS URL 图片 | 已实现 | HTTPS 默认；仅允许严格 loopback HTTP；支持 redirect、Vary、freshness、validator、retry、有界 staging、精确 origin allowlist 与显式代理信任策略 |
| 认证图片与 namespace 隔离 | 已实现 | `AuthorizationContextID`、credential generation、Profile ACL、缓存前 destination ACL、无回绕且耐重启的持久 revoke generation、持久清理、有界 refresh handoff、短期凭证复用窗口与 remembered-scope 硬上限 |
| 目标像素静态图解码 | 已实现 | ImageIO probe、格式/尺寸/像素/metadata/frame 上限、目标像素下采样与颜色策略 |
| 内存与磁盘缓存 | 已实现子集 | 公开 pin 下 RenderedMemory 与 alias 仍使用单锁 SIEVE 参考实现；8 分片 SIEVE + 磁盘 v2 已通过 V4 本地 13/13 endpoint 支配门、Akashic release-readiness 与 Git-free Fovea 478/478 候选集成，待公开 Akashic revision、Fovea 精确 pin 与 trusted CI 后才可正式启用 |
| SwiftUI/UIKit/AppKit 显示适配 | 已实现 | 共享 display session、身份栅栏、取消、复用、accessibility 与 reduce-motion 契约 |
| 渐进图像加载 | 已实现最终质量 preview + durable final | `FoveaPipeline` 在像素验证、目标解码、变换和命名空间围栏后发送 `UInt16.max` preview，并在持久化发布完成后发送 final；`image(for:)` 仍只返回 final |
| 动画播放 | 未实现 | 当前只交付静态 `DecodedImage`；默认 `maximumFrameCount = 1`，动画规格仍为 Phase 2/Experimental |
| File/Data/Asset/Photos source | 未实现 | `source-identity.md` 中对应章节是候选设计；当前生产 source 仅为 URL |
| AVIF/JXL/SVG 与完整 HDR 生态 | 未实现 | 不应从格式探测或候选规格推断为已支持 |
| OSLog/OSSignposter exporter | 已实现 | `FoveaObservability` 提供显式采样、静态低基数 signpost、失败/取消闭合、全局活动区间硬上限、drop 时主动闭合与字段二次脱敏；所有动态日志/signpost payload 使用 private privacy；不隐式上传或管理 retention |
| iOS 实验 App | 已实现 | `FoveaWorkbench` 与库同为 iOS/iPadOS 15+；默认确定性、真实 HTTPS 显式 opt-in；所有普通/专题/工坊路由共享 App 根部运行时宿主；只通过官方 `FoveaSystemPipeline` 组合根装配；证据 run 串行，核心套件真实顺序执行 13/13；维护动作发布稳定 Accessibility 状态；Evidence Bundle 不含 simulator UDID 或诊断 key digest；固定 XcodeGen 重现 PBX/scheme/workspace；oracle 1.2.0 对 iPhone/iPad 各七个检查点执行截图、几何和 Accessibility 三联审查 |


## SwiftPM 分发面

- 普通应用只依赖 `Fovea` product；它是 System、UI 与 Observability 的官方安全集成面。
- `FoveaAdvanced` 是显式逃生口。新的 codec 入口要求完整 `ImageCodec`；持久化替换通过 `FoveaAdvancedSystem` 的 qualified provider bundle 进入，encoded、records、namespace generation、generation identity 与 lifetime 不可拆分注入。选择它仍意味着宿主承担 provider conformance、ACL、destination、凭证、资源与生命周期组合责任。
- 内部按职责保留 9 个 Fovea production target，但不再把每个 target 单独发布为顶层 library product；模块边界与分发产品边界不混为一谈。

## FoveaWorkbench 示例边界

- 示例 App 是独立 Xcode 工程，不是 SwiftPM 产品，也不依赖 `FoveaTesting`；核心库不得反向依赖它。
- `WorkbenchAppHost` 是唯一 UI 运行时宿主，统一启动模型、传播 scene phase、呈现错误并发布 `runtime.state`；DEBUG 直达路由只替换导航入口，不替换生命周期。
- 当前本地证据包括 475 项核心测试、54 项 Workbench 宿主测试、15 项 iPhone compact-width 行为测试、5 项 iPad regular-width 行为测试，以及 iPhone/iPad 各七个视觉检查点。数字描述当前本地树，不等同于可信 CI、稳定系统或真机发布证书。
- revision 26 完成结构重构，revision 27 仅重绑定本地就绪证书；结构质量门对本次触及面采用更严格的上限：单文件不超过 600 行、单函数不超过 80 行、圈复杂度不超过 10。`FoveaPipeline` 的依赖装配被拆为同文件内的有界 assembly helpers，避免增加 FoveaCore 文件预算；Workbench 的 UI 驱动 helper 位于独立 extension，全部可追踪 XCTest 方法仍留在原证据文件；视觉与 iOS 发布验证器分别拆成类型、PNG、oracle、进程、Xcode、视觉和报告模块。官方结构检查覆盖 10 个源码模块、107 个源文件；DocC 与公共 API 预算只治理 9 个 Fovea 生产模块，严格增量扫描为零违规。
- 结构重构后的独立本地证据包括重复 475/475 SwiftPM 回归、Xcode `build-for-testing` 成功、428/428 机器追踪、12 项视觉 oracle 自测和重复 XcodeGen 字节一致性。一次控制器运行曾在既有共享 fetch 取消测试的临时目录删除阶段出现 `NSCocoaErrorDomain Code=4`；同一控制器第二次完整运行及四次隔离复跑均通过，因此保留为环境/清理竞态证据，不修改或放宽测试。
- revision 27 将“执行最强本地验证并如实报告外部阻塞”归类为 `project_native` 本地就绪义务；GitHub verify/live-network-lab、真机、公网环境、签名和发布仍是独立 release lifecycle，未完成时 `release_ready` 必须保持 false。环境边界固定为本机 Xcode beta 与本地 Simulator；公网 live-network、本次真机、外部 CI、长时间 soak 和发布签名均未执行。视觉 oracle 自测与截图采集分离，证明有限故障类检测逻辑，但不证明主观美观。Xcode 工程仍只由固定 XcodeGen 版本和 `project.yml` 生成；revision 26 与 revision 27 前 checkpoint 及原子 write-set 提供回滚边界，未执行 commit、tag 或 push。
- 视觉报告当前保留两张 960 px 宽本地素材的分辨率 warning；现有捕获未证明目标容器像素不足，因此不宣称“零警告”。
- 架构中的 `FoveaLab` 继续专指前沿研究孵化区；可构建的 iOS 示例固定命名为 `FoveaWorkbench`，避免研究原型与产品集成证据混淆。
- Workbench 默认入口是当前 schema 2 的生态超载图谱：8 卷、32 个专题、28 份来源、6 类证据性质、160 个唯一媒体身份和 8 种详情媒体表面；旧九章内容与兼容模型已删除。专题强制包含机制、分配、争议、综合判断和图片测试契约，首页另有案例、系统地图、概念索引和方法页。底层仍保留 419 张独立 Commons 网络图片、29 张人工策展随包图片、11 类产品布局和最多 2,000 Cell / 300 唯一网络资源的 Feed。`--ui-testing`、确定性集成测试与合并门使用 `fovea-demo.test`，公网 Live XCTest 由显式授权执行并归类为 environment-dependent。
- SwiftUI `.empty` 不再立即构造 loading，占位只在延迟到期后出现；新鲜持久记录先由 ContentID 查询 rendered-memory，未命中才读取原编码磁盘。稳定资源身份不包含视图刷新 token；同运行时回屏不回源，管线重开可从磁盘恢复。
- Fovea 自有 9 个公开生产模块的 DocC 门通过：公开类型 110/110，公开符号 386/723（53.39%）；ImageCraft 与 Akashic 的 DocC/API 预算由各自仓库独立负责。
- `AkashicCore`、`AkashicDisk` 与 Workbench App 都打包 `PrivacyInfo.xcprivacy`。库对容器文件元数据声明 FileTimestamp / `C617.1`；App 另对自身 `UserDefaults` 声明 `CA92.1`。门禁会把源码调用、SwiftPM/XcodeGen 资源与 Release App 根清单绑定验证，并要求无 tracking、无 collected data。
- App 内置 origin 覆盖缓存、ETag/304、Vary、认证、慢响应、分块、状态码、错误 MIME、体积上限和不完整 body，但不冒充真实 OAuth、后台 URLSession、切网或企业代理实验。
- `scripts/verify-ios-example.py` 校验 iOS 15 deployment target、固定 XcodeGen 版本、PBX/scheme/workspace 的字节级重现与 canonical target 成员、Release Build、Release 二进制不含测试路由/测试插件、App 根隐私清单、普通/生产管线单测、真实网络和 UI 行为矩阵；行为矩阵把 15 项 compact-width iPhone 测试分成三个五测试分片，把 4 项原生 iPad 测试分成两个两测试分片，并以独立 iPad 分片执行 `DEMO-PT-024`，最终仍汇总为 15/5 两个 phase 计数。分片间重启对应 Simulator，基础设施故障只重跑所属分片。iPad Feed 契约必须先观察“脚本 快速反向 已完成”和本地化“内存占用 +”状态，再验证 UIKit host 与末项 cell；旧英文状态片段不再构成有效证据。未跳过 UI/visual 时还执行严格双设备视觉矩阵。结构化 phase 报告写入 `.artifacts/ios-example/verification.json`，视觉报告写入 `.artifacts/ios-example/visual-audit/primary.json`。Live target 没有 `RUN_LIVE_NETWORK=1` 时全部跳过；`FOVEA_IOS_RUNTIME_VERSION` 可固定 simulator runtime。

## 公共装配契约

- 应用默认入口是 `FoveaSystemPipeline.open`；它使用清除 URLCache/Cookie/credential store/session-wide headers 的 URLSession、同一 StoreGeneration 下的 stores、耐崩溃 namespace generation store、ImageIO decoder，并默认 `.publicOnly`。组合根可显式注入已清洗的 session configuration、staging root 与 transport reuse identity；`invalidateAndCancel()` 提供确定性关闭，不把底层 transport 生命周期 API暴露为公共产品面。
- `URLSessionTransportPolicy.destinationPolicy` 在官方组合根中同时约束缓存前访问、初始 URLSession task 与每次 redirect；策略摘要进入精确 execution identity。task route 缺失或迟到 redirect 回调失败关闭，不回退到更宽松策略。
- 直接构造 `FoveaPipeline` 时必须显式提供 `ProfileAccessPolicy`。自定义组合根不能依靠隐式 `.unrestricted`。
- package 内部构造器可为测试提供默认值，但不属于外部 API。



## 长期运行状态与资源生命周期

- namespace registry 具有显式硬上限；已跟踪 generation 与撤销墓碑不会被淘汰。revoke 在 persistent cleanup 前先原子发布新 generation；即使 cleanup 失败或进程终止，重启后旧 generation 仍不可达。容量耗尽时新的 namespace 在缓存和网络之前 fail closed；
- fetch/decode shared-task 的按 key cancellation 计数仅是显式测试 instrumentation，生产默认关闭，避免高基数永久侧表；
- permit 是 Swift 不可复制值，`release`/`withPermit` 消耗所有权；成功、失败和取消路径精确释放，调用点不能复制或二次消费许可；
- credential refresh 结果只在短期窗口内复用，remembered scope 有硬上限，logout 可按 namespace 取消刷新并清除内存凭证；已取消调用者在 refresh 入口、remembered 快路径和认证重放前均失败关闭；
- persistent store registry 只保存弱引用，writer lease 的生命周期锚定在实际 store actor；释放最后一个 store 后可回收文件描述符并以新运行时预算重开；
- blob 内容损坏与暂时性 POSIX I/O 故障分开处理，权限/资源耗尽等故障不会误删有效 manifest 条目。

## 网络路由、代理与隔离边界

- 默认遵循系统代理、PAC、VPN、Private Relay 和设备管理路由，不尝试私自绕过系统网络治理；
- `.requireNoProxyInTaskMetrics` 只有在 URLSession transaction metrics 可用且全部事务均未标记为代理时才接受响应；缺少指标或观测到代理均失败关闭；
- 该严格模式是响应接受策略，不是连接前强制直连。需要 IP/CIDR、DNS rebinding、Network Extension 或企业 egress 保证时必须由宿主基础设施提供；
- 精确 origin allowlist 最多 256 项，不支持通配域名和隐式子域继承，避免规则歧义；
- 自定义 `URLSessionConfiguration` 的 ambient credential store、Cookie、URLCache 与 `httpAdditionalHeaders` 会被清除；所有请求变体和凭证必须显式进入 `ImageRequest`。

## 生产可观测性

`FoveaObservability` 是独立 target/module，避免 `FoveaCore` 直接依赖 OSLog；它通过官方 `Fovea` product 分发。应用可显式创建生产 sink：

```swift
import FoveaObservability

let diagnostics = OSLogDiagnosticsSink(
  configuration: try OSLogDiagnosticsConfiguration(
    subsystem: "com.example.app",
    category: "image-pipeline",
    sampling: .oneIn(20),
    signpostsEnabled: true
  )
)
```

普通成功事件按短期 correlation digest 一致采样；失败、取消、安全异常、缓存降级和 diagnostics drop 始终记录。subsystem/category 只接受有界 ASCII 标识符，事件输出不会包含 raw URL、header、ContentID、namespace 或自由错误文本；短期 digest、尺寸、状态码、网络路径与时序等动态字段仍统一标记为 private。
URLSession 完成事件包含 task 总时长、transaction/redirect 数、协议、连接复用、代理与网络成本标记；DNS、connect、TLS、request、TTFB 和 response 阶段时长仅在 URL Loading System 实际提供时记录为可选值，不把连接复用或代理路径上的缺失伪装成零。


## HTTP 元数据与 representation 索引边界

- request/response header 均限制为最多 64 项、累计 64 KiB、单字段名 256 bytes、单字段值 16 KiB，并拒绝 NUL/CR/LF；自定义 transport 也不能绕过 response head、body hard cap、实际字节数和内容 digest 校验；
- `Vary` 最多 32 个规范化字段，敏感值只能持久化经验证的 SHA-256 fingerprint；除固定集合外，header 名中的 auth/credential/csrf/key/password/secret/session/signature/token/xsrf 组件也保守归类为敏感；无法规范表达的 `Vary` 响应按 no-store 处理；
- 单条 representation 持久元数据限制为 128 KiB，manifest 写入同时限制 100,000 条和 64 MiB；
- record store 按 base key 与 content reference 维护提交后更新的内存索引，替换、删除、重开均有一致性测试；具体 manifest actor 位于 `FoveaPersistence` 且不是公开 API，`FoveaHTTP` 只拥有模型与协议；持久布局仍是单 JSON manifest，不据此宣称数据库级规模能力。

## URL 与稳定身份

默认 `LogicalSourceID` 是规范化后的完整 URL，包含 query，但不包含 fragment。该默认值刻意保守：未知 query 参数可能改变实体，库不能自动猜测哪些字段只是签名或过期时间。

对轮换签名 URL、临时 CDN locator 或同一资产的多次授权 URL，调用者必须提供稳定业务身份：

```swift
let request = try ImageRequest.publicImage(
  url: signedURL,
  logicalSource: LogicalSourceID("asset:avatar:42"),
  target: target,
  appID: appID
)
```

不同 locator 会产生不同 `FetchExecutionKey`，但相同显式 `logicalSource` 可保持 `FetchBaseKey` / representation 身份稳定。Fovea 不提供自动剥离 `token`、`sig`、`expires` 等参数的默认策略，因为错误白名单会造成跨资源复用。

## 磁盘存储边界

当前 `FoveaPersistentStores` 中的 `AkashicOriginalEncodedStore` 使用：

- 默认总量软目标：128 MiB；
- 默认单 blob 上限：64 MiB；
- manifest 读取/写入上限：64 MiB；
- manifest 条目硬上限：100,000；
- 受支持单 blob metadata 硬上限：1 GiB；实际写入仍受配置中的更小上限约束；
- 每次成功读取在内存聚合访问时间；blob mtime 最多每 5 分钟时间桶 best-effort 更新一次，不全量重写 manifest；
- 启动时按持久 mtime 恢复近似 recency，并在预算降低后立即收敛；运行期 GC 即使没有 manifest victim 也会重试清理临时文件与孤儿 blob。

manifest 仍是单 JSON 文件并在变更时全量原子重写，因此当前实现面向中小规模 App cache，而不是百万条目数据库。达到以下任一条件前必须先提交 benchmark 和迁移 ADR：接近 100,000 条、manifest 接近 64 MiB、启动/提交延迟超出产品预算，或需要多 writer。

## 证据边界

- `CACHE-PT-017` 已有固定 canonical bytes/SHA-256 golden vectors；CI 分别在 arm64 与 x86_64 runner 执行同一测试。
- 本地 arm64 通过不等价于远端 x86_64 已通过；只有对应 CI run 成功后才能声称该提交获得双架构证据。
- DocC 必须为全部生产模块成功生成 archive；源码声明的公开类型/协议文档覆盖要求 100%，公开符号覆盖要求至少 50%；逐模块与总 public surface 受 `docs/public-api-budget.json` 约束，工件与日志摘要绑定当前 tree；
- Cache Lab V4 继续使用 report schema 4：Fovea/Akashic 组件身份、依赖解析模式、plan digest、claim-family digest 与 process-block 主机证据必须同时绑定。V4 机器锁定 20 个 fresh-cache 热扫描 rounds、8 轮磁盘 p99 采样和 8 分片参数；本地 20-process 正式组合门已通过 13/13，Akashic 81 文件 Git-free 候选也通过完整 release-readiness 与 Fovea 478/478 集成。edited/dirty source、公开精确 pin、protected trusted CI、iOS 真机端到端性能、稳定系统复制、企业代理矩阵、独立安全审计与 accountable human attestation 仍未完成。
- 跨学科工程元规格已落地为 14 条带证伪条件和适用边界的 `FOVEA-LAW-*`，当前 36 项 `FOVEA-EGG-*` 发现均绑定真实源码/工具资产和测试证据；`check-engineering-knowledge.py` 进入统一验证，拒绝悬空测试 ID、丢失资产、无反例原则和无证据 promoted 发现。
- 测试控制面已提炼 `waitUntil`/`waitUntilOnMainActor`；单元测试目录不再使用 1ms 固定睡眠推测阶段到达，优先级序列使用 continuation 通知。真实延迟、退避和 UI transition 测试仍可保留明确的时间语义。

## 发布与法务

仓库已包含 MIT `LICENSE`、`CONTRIBUTING.md` 与第三方资产声明，供应链门禁会拒绝缺失或被替换的许可、贡献或素材边界。许可证解决代码分发与贡献授权边界，但不替代商标、出口管制、隐私、专利清查或第三方资产审计。

## 第三轮安全与生命周期复审补强

- namespace revoke 现在持有引用计数 cleanup barrier，并在进入 cleanup 前原子持久化新 generation；持久清理未完成期间新请求失败关闭，cleanup 失败或进程终止后重启也不会恢复旧代可达性；
- 系统内存压力 monitor 由长期存活的 `FoveaPipeline` 锚定，不再依赖调用者保留临时组合根包装对象；
- diagnostics schema 6 区分 `itemCount` 与 `byteCount`，直接构造和 Codable 解码共享数值、reason、协议名与 schema 清洗；
- NetworkLab 对自定义目的地只输出每次运行随机化的 origin correlation，使用精确 origin allowlist，跨 origin redirect 必须显式 `--allow-origin`，单次最多 64 个 case；
- FoveaWorkbench 自定义 URL 是会话态，不写入 UserDefaults；Workbench/Gallery 不再展示任意底层错误字符串；
- 预发布 representation schema 4 解析分支已删除，直接打开旧目录失败关闭；正式组合根通过 StoreGeneration 兼容指纹切换；
- 仓库验证新增敏感材料扫描与供应链 allowlist；当前没有远程 Swift package，也没有外部 GitHub Action；结构门禁同时审计 Tests、Tools 与 Examples 的并发逃逸，并只允许一个精确登记的 `URLProtocol` 兼容桥。

## 第二次边界复审后的当前事实

- representation record 当前 schema 为 6；`requiresRevalidation` 持久化 origin 的 `no-cache`/`must-revalidate` 约束，304 仅在明确返回 Cache-Control 时替换该约束；
- public transport、record store、decoder、transformer 与 encoded store 都是可插拔边界，但 pipeline 不信任其声明，必须重新核验 URL、header、body、digest、namespace、generation、probe、输出 surface 与结果计数；
- transport staging 是每个 transport 独占目录，活跃状态同时由进程内 registry 与跨进程 owner lock 保护；崩溃失主目录在下一次租约取得时清理；
- `RefreshingImageLoader<Base>` 只有在 `Base: NamespaceRevoking` 时才获得统一 revoke 能力；当 `Base: ProgressiveImageLoading` 时也保留 progressive 事件能力并复用同一 401 refresh/replay 契约；
- Fetch、Decode 与 Transform 均按各自稳定身份 single-flight；相同 `ScopedRenderKey` 的并发 transform 只执行一次，namespace revoke 会取消对应变换且禁止迟到内存发布；
- current critical mutation catalog 为 101 项；最终证据仍必须绑定当前 workspace tree，旧 tree 的 81/81 报告不得复用。
