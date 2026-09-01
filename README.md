# Fovea

**状态：Phase 0b 收口中；Phase 1 准备已开始，但尚未获准正式进入；公共 API 尚未稳定。**

Fovea 是面向 Apple 平台的图片加载系统。当前无稳定公共 API；实现与规格以单一活动版本持续收敛。Phase 0a 的首个垂直切片基线记录在 [`core-surface.md`](docs/specifications/core-surface.md)，当前 0b 实现边界以 [`ARCHITECTURE.md`](docs/ARCHITECTURE.md) 和各领域活动规格为准。

阶段转换以 [`PHASE0B_GRADUATION_AND_PHASE1_ENTRY.md`](docs/PHASE0B_GRADUATION_AND_PHASE1_ENTRY.md) 和机器状态 [`phase0b-status.json`](docs/phase0b-status.json) 为准。当前能力与未实现边界以 [`IMPLEMENTATION_STATUS.md`](docs/IMPLEMENTATION_STATUS.md) 为准。特别注意：生产 `FoveaPipeline` 当前不提供渐进解码事件或动画播放，File/Data/Asset/Photos source 仍是候选设计。跨学科工程原则、证伪边界和可复用“金蛋”由 [`interdisciplinary-engineering.md`](docs/specifications/interdisciplinary-engineering.md) 与机器注册表 [`engineering-knowledge.json`](docs/engineering-knowledge.json) 共同治理；类比不构成实现证据。

当前已打通：

```text
public / authenticated URL
→ FetchBaseKey / Vary-selected FetchVariantKey / FetchExecutionKey
→ bounded staging + spill + streaming SHA-256
→ StoreGeneration-scoped OriginalEncoded + representation record + opaque PhysicalBlobID
→ cross-process-serialized StoreGeneration selection + fail-closed single-writer lease + crash-safe publication
→ transport-context-aware FetchStage / DecodeKey single-flight
→ request-level network permissions + pre-cache Profile ACL + exact origin policy
→ versioned codec capability negotiation before pixel allocation
→ conservative max(generic, backend) decode working-set admission
→ ImageIO target-pixel reference adapter + backend/version fingerprinted DecodeKey
→ explicit color/alpha/pixel-format contract + fail-closed reserved capabilities
→ RenderKey-scoped transform single-flight + output revalidation
→ generic Akashic MemoryCache + namespace-scoped render identity
→ FoveaSystem safe composition root + ambient-state-free URLSession + proxy/destination policy
→ FoveaObservability OSLog/Signpost exporter + correlation-stable sampling
→ shared display-session state machine for SwiftUI/UIKit/AppKit
→ iOS 15+ FoveaWorkbench deterministic scenario/feed lab + macOS Gallery + scheduled public HTTPS matrix + deterministic network chaos matrix
```

图像解码与通用缓存机制已经物理拆分为独立公开 MIT 仓库。Fovea 通过 `Package.swift`、`Package.resolved` 与 `docs/project-memory/component-pins.json` 三重一致的完整提交固定，消费 ImageCraft `c16a868f1a1c0ed6b1a916ad082f762969ac5a7e` 与 Akashic `0376b960ec8abe54f2d4a9d7d66e97f395215eaf`；仓库内不再保留五个组件生产源码目录。`ImageCraftCore` 定义有限 codec、能力、资源和生命周期契约，`ImageCraftImageIO` 提供 Apple ImageIO 参考实现；目标几何、transform、网络、授权、缓存身份、namespace revoke 与发布事务仍由 Fovea 拥有。当前 ImageIO 只声明已兑现的完整主帧 SDR 能力，progressive、animation、HDR、pixel-buffer/planar output 和可中断取消仍是明确非能力。缓存默认路径使用 `AkashicOriginalEncodedStore -> AkashicDisk.FileBlobStore` typed adapter 与新的 store generation；Fovea 领域的 `OriginalEncoded*`、namespace 指纹和 revoke persistence 契约位于最小环切割模块 `FoveaStorage`，不会泄漏到 Akashic 公共 API。当前精确 pins 的公开 clean-copy、ImageCraft/Akashic 回退与 forward-current 恢复均通过宿主验证，两个组件的 required `core` check 也已通过；Fovea 公共根/CI、物理设备资源与真实断电证据仍是发布前开放项，任何本地成功都不构成 power-loss 或稳定版声明。详见 [`ADR-0011`](docs/adr/0011-codec-capability-contract.md)、[`ADR-0014`](docs/adr/0014-domain-neutral-akashic-contract.md)、[组件 pin](docs/project-memory/component-pins.json) 与[下一步行动方向](docs/roadmaps/fovea-next-action-direction-2026-08-01.md)。

本地质量门已包含：

- Xcode 27 / Apple Swift 6.4、Swift 6 strict concurrency、显式 isolation semantics、async defer、不可变弱引用与 package-only implementation API；
- priority-aware fetch/decode hard cap、带权解码 working-set 预算、动态 subscriber 优先级、饥饿后容量保留/drain 与零订阅者任务租约回收；
- macOS 与 iOS Simulator 全量测试，以及独立进程 StoreGeneration 收敛与 writer 排他门禁；
- iOS 15+ FoveaWorkbench 的可重现 Xcode 工程、普通单元/生产管线集成与 iPhone/iPad UI 自动化；四 origin 真实网络测试由计划任务、手动实验或 0b/release 完成门执行；
- W1 Feed Scroll、W2 Detail Hero、W3 Auth Gallery；Comparative Lab 的 A 级矩阵包含 Apple URLSession + URLCache + ImageIO、Apple AsyncImage、Nuke、Kingfisher、SDWebImage、PINRemoteImage 与 Fovea。六项 headless 实现使用统一 adapter 合同，Apple AsyncImage 与 FoveaResponsiveImage 使用独立配对 SwiftUI surface；AlamofireImage 仅作为 B 级补充证据保留；
- 生产源码聚合/逐文件覆盖率门、DocC archive、50% 源码声明文档覆盖门与逐模块 public API 预算；
- required-reason API 扫描与 target 级 Privacy Manifest 一致性门；
- 101 项 curated critical mutants；
- 跨学科工程知识 gate：14 条可证伪原则、36 项具备资产/证据/边界的发现注册；
- rollback gate；
- Release、TSan、ASan 与严格 `swift-format`；
- 本地 Evidence Bundle（仅 `agent-declared / unproven`）。


SwiftPM 集成默认只选择官方产品；只有自定义 transport/store/decoder 或底层存储实验才选择高级入口：

```swift
.package(
    url: "https://github.com/YuLeiFuYun/Fovea.git",
    revision: "<verified-fovea-commit>"
)

.product(name: "Fovea", package: "Fovea")
// 只有自定义 transport/store/decoder 组合才选择：
.product(name: "FoveaAdvanced", package: "Fovea")
```

只消费 codec 契约或 Apple ImageIO 实现时，应直接依赖独立的 `https://github.com/YuLeiFuYun/ImageCraft.git`，而不是假设 Fovea 重新导出其产品。

`Fovea` 是安全默认分发面，包含 System、UI、Observability 及其公开签名所需模块；`FoveaAdvanced` 明确表示调用方承担组合边界与安全策略。默认持久化使用 typed Akashic adapter；高级持久化替换必须实现 `FoveaPersistentStoreBundleProviding`，一次交付同代际 encoded、records、namespace generation 与 lifetime，不能分别注入裸 store。Akashic 的通用 Core/Memory/Disk 能力只通过高级入口暴露。外部精确依赖已经落地；完成当前 pin 的 clean-copy、回滚、required-check 与设备证据前，不把该组合描述为稳定发布。

生产 OSLog / Instruments 诊断出口：

```swift
import FoveaObservability

let diagnostics = OSLogDiagnosticsSink(
  configuration: try OSLogDiagnosticsConfiguration(
    subsystem: "com.example.app",
    sampling: .oneIn(20)
  )
)
let system = try await FoveaSystemPipeline.open(
  cacheRoot: cacheRoot,
  diagnostics: diagnostics
)
```

分层确定性验证入口（默认不访问公网）：

```sh
scripts/verify.sh
# 合并前全量根测试与确定性集成门：
FOVEA_VERIFY_PROFILE=premerge scripts/verify.sh
# 发布候选首次形成或资格证据失效时运行最大矩阵：
FOVEA_VERIFY_PROFILE=qualification scripts/verify.sh
# 同一源码树已有有效资格证据时执行发布复核：
FOVEA_VERIFY_PROFILE=release scripts/verify.sh
```

默认 `smart` profile 根据实际变更选择测试；未知路径自动升级，不会静默漏测。完整 UI、双 sanitizer、当前组件 clean-copy 和 mutation 只在源码绑定的 qualification 中执行。详细契约见 [`docs/specifications/verification-profiles.md`](docs/specifications/verification-profiles.md)。

持久化 provider 的跨仓合约由独立 consumer kit 验证：

```sh
python3 ConformanceKits/PersistentStoreProvider/v1/run.py \
  --provider-package-path /path/to/provider \
  --provider-product ProviderProduct \
  --factory-source /path/to/ProviderUnderTest.swift
```

该报告绑定 Fovea/provider/ImageCraft/工具链和日志身份；通过不等于 crash-consistency、跨进程 writer exclusion 或发布资格。

Image codec backend 使用独立 contract kit：

```sh
python3 ConformanceKits/ImageCodec/v1/run.py \
  --codec-package-path /path/to/codec \
  --codec-product CodecProduct \
  --factory-source /path/to/CodecUnderTest.swift
```

codec v1 覆盖 descriptor、2,304 项有限能力域、声明格式的 probe/decode、资源估计组合和硬限制；通过不替代 hostile corpus、fuzz、sanitizer、真机资源或 Fovea composition 证据。

示例与外部网络实验：

```sh
open Examples/FoveaWorkbenchApp/FoveaWorkbench.xcodeproj
scripts/verify-ios-example.py --skip-live-network
swift run FoveaGalleryDemo  # 启动后仍需显式允许第三方网络
scripts/run-live-network-lab.py --timeout 240
```

确定性 loopback chaos matrix 是合并门，负责可重复验证 304、no-store、慢响应、缺失 MIME、错误 MIME、响应体超限、401 和不安全 redirect。真实 HTTPS 矩阵用于计划任务、手动实验和 Phase 0b 完成证据，覆盖多个独立 origin、系统 DNS/代理/VPN、TLS、HTTP/2、重定向、CDN、URLSession metrics、single-flight 与目标像素约束；它不再把第三方服务瞬时故障等同于代码回归。需要显式运行时使用 `scripts/run-live-network-lab.py --timeout 240 --attempts 2` 或独立 live-network workflow。

Phase 0b 的本地协议、外部 WPT required corpus 与调度实现已大体落地；当前只执行完整 W1-W15 矩阵中的 W1-W3 baseline。存在性结论仍受正式 W1/W2/W3 真机比较、第二台较低性能设备、稳定 iOS 复跑、远程受保护 required check、accountable human attestation 与独立 held-out evaluator 阻塞。W4-W15 的能力缺口、专项计划与开放事项由 `Benchmarks/workload-registry.json` 和 `docs/project-memory/` 持续追踪；本地成功不得冒充这些外部证据或完整路线完成。

- [Phase 0a 历史实现基线](docs/specifications/core-surface.md)
- [Phase 0b 收口与 Phase 1 入口](docs/PHASE0B_GRADUATION_AND_PHASE1_ENTRY.md)
- [架构入口](docs/ARCHITECTURE.md)
- [当前实现状态与明确非能力](docs/IMPLEMENTATION_STATUS.md)
- [贡献指南](CONTRIBUTING.md)
- [MIT License](LICENSE)
- [实现者最短路径](docs/README.md)
- [测试 ID 注册表](docs/TEST_CATALOG.md)
- [Demo 与真实网络实验](Examples/README.md)
- [2026-07 图片管线参考审计](docs/research/image-pipeline-reference-audit-2026-07.md)
- [Codec 能力契约 ADR](docs/adr/0011-codec-capability-contract.md)
- [Codec 边界研究档案（2026-07）](docs/research/image-codec-boundary-research-2026-07.md)
- [Fovea 与独立 Codec 并行路线图](docs/roadmaps/fovea-codec-parallel-roadmap.md)
- [世界级工程审查（2026-07）](docs/research/world-class-engineering-audit-2026-07.md)
