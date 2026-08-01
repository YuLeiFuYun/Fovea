# Swift 6.4 采用审计：Fovea、ImageCraft 与 Akashic

> 日期：2026-08-01  
> 状态：第一批生产迁移已实现并通过本地核心测试；受托管 CI 工具链与真机证据约束，尚不构成发布资格。  
> 路线映射：P0 工具链与证据基线、P1 ImageCraft、P4 Akashic、P6 三仓组合、P7 重新校准。

## 1. 目标与非目标

本轮不是把 `swift-tools-version` 数字机械改为 6.4，也不假设新语法天然更快。采用标准为：

1. 能由类型系统或结构化控制流直接加强资源、取消或引用不变量；
2. 不抬高 Fovea 的 iOS 15 / macOS 12 运行基线；
3. 通过现有测试、构建与跨仓组合门；
4. 性能属性必须绑定具名热点和 A/B 证据；
5. experimental 特性不能进入稳定公共契约；
6. 编译器、SDK、SwiftPM 或 CI 的限制必须作为负结果保留。

本轮明确不做：无证据的 `@inline(__always)`、泛化 `@specialized`、全仓 RawSpan 改写、为了使用 noncopyable 而串行化解码、提高最低系统版本，以及把 GitHub `xcode-27` preview 的结果伪装成 GA runner 证书。

## 2. 固定工具链与本地源码身份

本地验证使用：

- Xcode 27.0 beta，build `27A5228h`；
- Apple Swift 6.4，`swiftlang-6.4.0.27.1`；
- Swift 源码 `4ea844422a7477910d77e7561c32955af6298869`；
- swift-evolution `7607273ce9de51bc154df8d4f8b9f1de5f01fa0e`；
- swift-foundation `111c5077d14bb0cabf97ec168cb04a1dbd82d10c`；
- SwiftPM `c21af2594e8b0cab31298afff6665849de31c361`；
- swift-testing `b9c33e7d1f9ed6b533a36d78bc674a1e128a0d6e`。

三仓新增统一的 `scripts/select-xcode.sh` 与 `scripts/check-swift-toolchain.py`。验证必须选择 Xcode 27+ 且 Apple Swift major/minor 精确为 6.4；旧 Xcode 不再静默回退。所有活动 SwiftPM manifest，包括消费者与 benchmark package，统一声明 tools 6.4。

## 3. 已进入生产实现的能力

### 3.1 Fovea：async defer

`AsyncPermitPool.Permit.withPermit` 不再复制 success/catch 两套 release 逻辑，而是先提取 permit 身份和 pool，再以异步 `defer` 保证 release。这样既避免 consuming `self` 被 defer 再消费，也使未来新增 early return 时无法遗漏释放。

`DecodeStage` 的两个边界同步改造：

- shared decode subscription 总是在作用域退出时 cancel/release；
- encoded-data validation 总是 discard preparation 并 finish priority control。

收益是控制流可审计性和资源释放完备性，不宣称仅凭语法改变获得吞吐提升。

### 3.2 Fovea：weak let

内存压力 monitor 到 pipeline，以及持久 store bundle 到四个 store/lifetime 对象的弱引用，在初始化后都不应改指向。改为 `weak let` 后，非拥有关系与不可重绑定语义同时进入类型系统，减少后续重构把弱依赖误当成可变槽位的风险。

### 3.3 Akashic：不可复制 writer lease

`StoreWriterLease` 从引用类型变为 `~Copyable` 值类型。它不能被隐式复制、放入要求 Copyable 的通用容器，或通过旧 `BlockingIOExecutor.run<Value>` 的 checked-continuation 返回边界传播。

为保持阻塞文件系统获取不占用 Swift 协作式执行器，新增 `StoreWriterLeaseAcquirer` actor，并将其隔离到专用 `BlockingIOExecutor`。actor 方法直接返回线性 lease，随后由 `FileBlobStore` consuming 初始化器接管。该设计把“全进程唯一 writer 句柄”从注释约定提升为编译期所有权约束。

同一提交路径将 stage discard 改为 `defer`。publish 成功后 discard 是幂等空操作，失败后则保证清除未发布 stage。

### 3.4 Swift Build 与产品路径

SwiftPM 6.4 默认采用 Swift Build。脚本不再假设 `.build/debug` 或 `.build/out/Products/Release`，而通过 `swift build --show-bin-path` 定位 `ImageCraftEvidence` 和 `AkashicCrashProbe`。这避免构建后端、configuration 或架构改变时工具找到陈旧二进制。

## 4. 已验证但暂缓的能力

### 4.1 ImageCraft RawSpan

容器安全扫描器的 RawSpan 版本通过全部 64 项测试，证明可以用 owner-borrowed、不可逃逸的字节视图替代裸 `UnsafeBufferPointer`。但存在两个阻塞：

- Swift 6.4 新增的安全整数 load API在 Apple SDK 中标记为 macOS/iOS 27 起可用，不能用于最低 iOS 15 路径；
- 保留逐字节 checked subscript 的本地交替微基准噪声很大，中位数约慢 4.5%，paired ratio 跨越明显优劣两侧，不能证明 non-inferiority。

尝试把所有已验证索引集中到 `unsafe bytes[unchecked:]` 并强制 inline，反而出现约数量级退化。因此生产解析器保持原状；RawSpan 只保留为未来编译器/SDK版本的受控实验。

### 4.2 ImageCraft 线性 preparation

`ImageDecodePreparation` 与 instrumented wrapper 在 ImageCraft 局部可以建模为 `~Copyable`，并让 decode/discard consuming 整个令牌。组件测试可通过，但组合审计发现：

- 从含不可复制字段的诊断包装器部分消费时，Swift 6.4 前端报告 compiler bug；
- Fovea `DecodePlan` 需要跨 `DispatchWorkExecutor.run<Value>` 返回，而该 continuation/generic 边界仍要求 Copyable 结果；
- noncopyable `Continuation` 不能直接被逃逸的 `DispatchQueue.async` 闭包捕获，转为 checked continuation 又会恢复 Copyable 约束。

因此不以串行 broker 或复杂 indirection 强行落地。后续应先把 preparation 生命周期收敛为 Fovea 内部线性 lease，或等待执行器/continuation 能完整传递 noncopyable 结果。

### 4.3 cancellation shield

namespace generation 已持久推进后，revoke cleanup 理论上适合 cancellation shield。但 `withTaskCancellationShield` 在 Apple SDK 中标记为 OS 27 起可用。为保持 iOS 15/macOS 12 单一路径，本轮拒绝 `#available` 双实现。第三方自定义 store 若在 `removeAll` 中主动检查取消，仍需要未来的清理契约或自有 back-deployable shield 原语。

### 4.4 SBOM

SwiftPM 6.4 能生成 SPDX 3 JSON，但当前 Xcode beta 实测存在：

- 缺少 `SwiftPM_SBOMModel` schema bundle，工具明确跳过 schema validation；
- 独立 generate 模式警告不能表达全部 build-condition 信息；
- 三个 MIT 根包未形成 declared-license relationship，生成器自身的 Apache-2.0 关系反而可见。

故 SBOM 暂时只作诊断，不进入发布证书或供应链 required check。

## 5. 性能采用规则

以下能力不会按“Swift 6.4 新增”直接推广：

- `isTriviallyIdentical(to:)`：仅在等价性判断已经是热点、且 identity fast path 不改变语义时评估；
- `@specialized`：需要真实泛型调用分布、二进制体积与增量构建成本共同证据；
- `@inline(__always)`：默认拒绝，除非 retained A/B 同时证明延迟收益与代码尺寸可接受；
- `UniqueArray`/`UniqueBox`/`Ref`/`MutableRef`：先用于新建的内部所有权模型，不替换成熟公开集合表面；
- `~Sendable` 与 warning-control：仍属 experimental，不进入发布契约。

## 6. 前沿研究与生产实现的约束

本轮把语言演进与近期资源安全研究对照，而不是只阅读语法提案：

- *Linear effects, exceptions, and resource safety*（arXiv:2510.23517）指出，线性资源一旦与异常组合，默认析构与 move/exchange 规则本身就是语义的一部分。对应到三仓，`async defer` 和 noncopyable lease 只用于具有明确终止动作的资源；不能把“编译器禁止复制”误当成异常路径已经安全。
- *When Lifetimes Liberate*（arXiv:2509.04253）尝试把 arena、可达性与非词法生命周期统一，说明共享资源需要同时描述“谁可达”和“何时失效”。这支持 Fovea 继续把 namespace generation、StoreGeneration、writer lifetime 和 prepared state 看作组合契约，而不是拆成互不关联的插件句柄。
- *Ownership Refinement Types for Pointer Arithmetic and Nested Arrays*（arXiv:2604.22361）将 fractional ownership 与索引相关 refinement 结合，提醒图片容器扫描的安全性不仅是内存生命周期，还包括 offset、长度和嵌套结构的算术证明。因而 ImageCraft 的 RawSpan 迁移必须同时保留格式级边界测试，不能仅凭换用安全视图宣称解析安全完成。
- Apple 公开的 Swift TrueType hinting interpreter 生产迁移采用 noncopyable state、borrow 与 Span，并报告整体快于原 C 实现；其关键经验是只在少量互操作边界保留审计过的 unsafe，并通过完整基准循环决定优化。Fovea 三仓采用同样的“内部强所有权、边界少量 unsafe、测量后优化”原则，但不转移该项目的性能数字。

这些材料共同支持当前决策：writer lease 是适合立即线性化的独占资源；ImageCraft preparation 仍受编译器与跨执行器边界阻塞；解析热点只有在算术、部署和 A/B 三重证据齐全时才迁移。

## 7. 本地验证结果

第一批生产改动下：

- Fovea：475 项测试、release 与 CacheLab 7 项通过；
- ImageCraft：64 项测试、release、compatibility 与三项最低系统平台矩阵通过；
- Akashic：41 项测试、release、正负消费者、API baseline 与六项最低系统平台矩阵通过；
- Fovea + 本地 Swift 6.4 ImageCraft/Akashic：475/475 宿主测试通过；
- 原 Workbench 五测试 shard：5/5 通过；
- mutation application：101/101 通过。

这些是本地、脏工作树上的实现证据，不替代 clean-copy、iOS 15 Simulator/device、回滚、完整 mutation、真机资源和公共 CI。

### 7.1 Xcode 27 warning-policy 组合

Xcode 27 会拒绝同一 SwiftPM target 同时收到 `-warnings-as-errors` 与 `-suppress-warnings`。因此，不能通过命令行把 `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` 注入整个 package graph；ImageCraft/Akashic 等外部包由 SwiftPM 按其策略编译。Fovea 自有源码继续由 `run-swift-strict.py` 的日志归属审计和 Workbench 自有 target 的项目级 warnings-as-errors 负责。该修正不降低 Fovea-owned strictness，而是移除对外部依赖策略的错误覆盖。

### 7.2 Workbench shard 生命周期反例

第七个私有根中，`testProductPatternsUseDistinctHostLayouts` 在五测试 shard 内失败、单独运行通过。根因不是产品布局契约本身，而是 UI 测试启动的 `XCUIApplication` 没有注册测试级终止，前序长测试可能留下应用 runtime、导航状态或可访问性进程。compact 与 regular-width 启动器现在都通过 `addTeardownBlock { @MainActor in app.terminate() }` 绑定 App 生命周期。Xcode 27 下原始五测试集合按同一 shard 运行 **5/5 通过**，其中原失败测试耗时 90.572 秒并通过，日志明确记录每次 teardown 终止应用。

### 7.3 诊断 backpressure 测试反例

三仓本地组合的第一次 475 项运行仅失败于 `testExternalRelayReportsBoundedDrops_DIAG_PT_004`。实现没有组件依赖；测试以固定 120/180ms 睡眠假定 `AsyncStream` 缓冲槽已经释放。clean build 负载下 summary 可能尚未入队。测试改为最多两秒的条件等待：持续调用 `record` 触发 summary flush，并等待下游实际观察 `.diagnosticsDropped`。重新编译后定向 **20/20** 通过，随后本地 Swift 6.4 ImageCraft/Akashic 组合 **475/475** 通过。该变更保留容量、丢弃计数、`itemCount` 与 `byteCount == nil` 的全部语义断言。

### 7.4 最低系统平台矩阵

第一批迁移保持运行基线不变：

- ImageCraft：macOS 12 universal、iOS 15 Simulator universal、iOS 15 device arm64 构建通过；
- Akashic：Core/Memory/Disk 对应的 macOS 12、iOS 15 Simulator 和 iOS 15 device 共六项通过；
- Fovea：Xcode 27 下原 Workbench 五测试 shard 在 iOS 15 目标编译并执行通过；根包 475 项、release 与 CacheLab 7 项通过；
- Fovea 使用本地 Swift 6.4 ImageCraft/Akashic 的完整宿主组合 475/475 通过。

因此 async defer、weak let 与 Akashic noncopyable writer lease 没有抬高声明的最低系统版本。仍需 clean-copy、真机资源与受信 CI 才能形成发布资格。

### 7.5 Xcode 27 Simulator 诊断收尾

Fovea package 的 iOS Simulator 测试执行了 **474/474** 并全部通过，但 Xcode 27 beta 随后自动启动 `simctl diagnose --timeout=600`，使 `xcodebuild` 在测试完成后继续等待。进程采样显示唯一阻塞栈位于 `XCTHRunDestinationAllocator.collectSimulatorDiagnostics`，无 Fovea 测试进程存活。终止诊断子进程后，xcodebuild 以状态 0 输出 `** TEST SUCCEEDED **`。

package Simulator 门现显式传入 `-collect-test-diagnostics never`，继续依赖完整 xcodebuild 日志、xcresult、Workbench 附件和既有 bounded process-group 工具，而不触发可能长达十分钟的 beta sysdiagnose。复跑 **474/474** 通过并立即正常收尾。

### 7.6 比较器与 SwiftUI 表面兼容矩阵

Swift 6.4 下完成了完整比较基础设施构建：

- macOS：Apple URLSession + URLCache + ImageIO、Fovea、Nuke、Kingfisher、SDWebImage、AlamofireImage、PINRemoteImage 共 7 个 adapter；
- iOS：上述 7 个 adapter 全部构建；
- SwiftUI 表面：Apple AsyncImage 与 Fovea SwiftUI 均构建；
- 5 个外部源码 checkout 均匹配锁定提交，production dependency graph 未被修改。

`verify-comparative-lab.py` 输出 `status=passed`、`externalAdaptersBuilt=true`、`iosAdapterBuilds=true`，但 `phase1DeclarationAllowed=false`。该结果仅证明 Swift 6.4 编译与合同兼容，不是性能排名、Pareto 证书或 Phase 1 声明。

### 7.7 x86_64 身份向量与测试运行时分离

`x86_64-apple-macosx12.0` 全测试图原型失败并不表示 Fovea 库抬高最低版本：失败来自测试辅助代码使用 `Duration`，以及 Xcode 27 自带 XCTest/Testing framework 的运行最低版本。改用 `x86_64-apple-macosx14.0` 后，完整测试 bundle 交叉构建通过，`FoveaTests` 被 `file` 与 `lipo` 识别为单一 x86_64 Mach-O。

本机未安装 Rosetta，因此该产物只算交叉构建证据。两次 hosted 原型进一步确定执行边界：原生 arm64 SwiftPM 会让 arm64 `swiftpm-xctest-helper` 拒绝 x86_64 bundle，而 Xcode 27 的 Swift driver 本身也是 arm64-only，不能整体置于 Rosetta。最终门由原生 Swift driver 严格交叉构建测试图，验证 bundle 为 x86_64-only，再通过 universal `xctest` 的 x86_64 slice、平台 XCTest/Testing framework 与 Swift support library 在 Rosetta 下执行唯一的 `CACHE_PT_017` selector。测试从编译条件产生 `compiledArchitecture` 并与 `FOVEA_EXPECTED_TEST_ARCH` 比较，防止把 arm64 执行误报为 x86_64。macOS 12 universal 产品构建继续作为独立最低部署门。

## 8. CI 与发布资格

GitHub 在 2026-07-16 提供了独立的 `xcode-27` 与 `xcode-27-xlarge` public-preview labels；该镜像为 arm64，默认 Xcode 27 beta / Apple Swift 6.4。官方公告与镜像身份已固化在 `github-xcode27-hosted-runner-evidence-2026-08.json`。普通 `macos-26` 镜像仍只有 Xcode 26.x，因此不能通过切换 `DEVELOPER_DIR` 获得 tools 6.4 资格。

迁移后的 CI 采用以下失败关闭策略：

1. workflow 显式使用 `runs-on: xcode-27`，禁止依赖 `macos-latest` 漂移；
2. 每个仓库运行 `select-xcode.sh` 与 `check-swift-toolchain.py`，验证 Xcode 27+、Apple Swift 6.4 和所有活动 tools 6.4 manifests；
3. ImageCraft 与 Akashic 先通过独立迁移 PR，不直接绕过 main required check；
4. Fovea 保留 arm64 与 x86_64 两个身份向量。x86_64 由原生 Swift driver 以 macOS 14 triple 严格交叉构建，再由 universal xctest 在 ephemeral Rosetta 下执行精确 selector；macOS 12 产品下限仍由独立平台构建证明；
5. preview runner 的容量、镜像变化和 beta 工具链稳定性单独记录，不能写成 GA 发布证书。

本地已证明 x86_64/macOS 14 `FoveaTests.xctest` 完整严格交叉构建，产物为单一 x86_64 Mach-O；Xcode 27 的 xctest 与平台 XCTest/Testing 运行时均包含 x86_64 slice。GitHub Actions run `30689587302` 的 x86_64 job `91341807599` 已通过 direct Rosetta xctest 精确 selector，执行 1 项、0 失败；ImageCraft/Akashic alpha.3 也已通过 xcode-27 main CI 并打不可变标签。当前只剩隐私净化 Fovea 私有根的完整 verify/rollback/evidence 门。

Fovea 既有 UI 顺序缺陷已经由测试级主 actor App teardown 关闭，原五测试 shard 5/5 通过。仓库继续 private，直到新的 Swift 6.4 单根快照在 `xcode-27` 上完成全部 required checks、rollback 与隐私验证。

## 9. 下一步

1. 在 private Fovea 单根上验证 direct-xctest Rosetta x86_64 selector、完整 verify、rollback、mutation 与 iOS/UI 门；
2. 仅在 private root 全绿后公开 Fovea、配置 required checks 并创建首个 alpha tag；
3. 将 Akashic alpha.3 重新绑定完整 fault/crash/quota campaign，再补真实断电与真机资源证据；
4. 将 ImageCraft preparation 的线性约束先放在宿主内部 lease，而不是破坏公共协议；
5. 等待 RawSpan load back-deployment 或以新 SDK 建立双版本编译证据后再评估。
