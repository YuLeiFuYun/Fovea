# Fovea

**状态：Phase 0b 实施中；公共 API 尚未稳定。**

Fovea 是面向 Apple 平台的图片加载系统。当前无稳定公共 API；实现与规格以单一活动版本持续收敛。Phase 0a 的首个垂直切片基线记录在 [`core-surface.md`](docs/specifications/core-surface.md)，当前 0b 实现边界以 [`ARCHITECTURE.md`](docs/ARCHITECTURE.md) 和各领域活动规格为准。

当前已打通：

```text
public / authenticated URL
→ FetchBaseKey / Vary-selected FetchVariantKey / FetchExecutionKey
→ bounded staging + spill + streaming SHA-256
→ StoreGeneration-scoped OriginalEncoded + representation record + opaque PhysicalBlobID
→ cross-process-serialized StoreGeneration selection + fail-closed single-writer lease + crash-safe publication
→ transport-context-aware FetchStage / DecodeKey single-flight
→ ImageIO target-pixel decode + explicit color/alpha/pixel-format contract
→ fingerprinted TransformStage
→ generic Akashic MemoryCache + namespace-scoped render identity
→ FoveaSystem safe composition root
→ shared display-session state machine for SwiftUI/UIKit/AppKit
```

本地质量门已包含：

- Swift 6 strict concurrency、Swift 6.2 isolation semantics 与 package-only implementation API；
- priority-aware fetch/decode hard cap、动态 subscriber 优先级与有界防饥饿；
- macOS 与 iOS Simulator 全量测试，以及独立进程 StoreGeneration 收敛与 writer 排他门禁；
- W1 Feed Scroll、W2 Detail Hero、W3 Auth Gallery smoke artifact；
- curated critical mutants；
- rollback gate；
- Release、TSan、ASan 与严格 `swift-format`；
- 本地 Evidence Bundle（仅 `agent-declared / unproven`）。

统一验证入口：

```sh
RUN_CRITICAL_MUTANTS=1 scripts/verify.sh
```

Phase 0b 的本地协议与调度实现正在推进；存在性结论仍受外部 HTTP corpus、竞品适配器、真机性能复现、远程受保护 required check、accountable human attestation 与独立 held-out evaluator 阻塞。本地成功不得冒充这些外部证据。

- [Phase 0a 历史实现基线](docs/specifications/core-surface.md)
- [架构入口](docs/ARCHITECTURE.md)
- [实现者最短路径](docs/README.md)
- [测试 ID 注册表](docs/TEST_CATALOG.md)
