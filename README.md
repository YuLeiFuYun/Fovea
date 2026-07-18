# Fovea

**状态：Phase 0a-bootstrap，本地产品与治理闭环已建立。**

Fovea 是面向 Apple 平台的图片加载系统。当前无稳定公共 API；功能型设计继续冻结，实现范围以 [`phase-0a-surface.md`](docs/specifications/phase-0a-surface.md) 为准。

当前已打通：

```text
public / authenticated URL
→ FetchVariantKey / FetchExecutionKey
→ bounded staging + spill + streaming SHA-256
→ namespace-scoped OriginalEncoded + opaque PhysicalBlobID
→ ImageIO target-pixel decode
→ namespace-scoped RenderedMemory
→ SwiftUI FoveaImage
```

本地质量门已包含：

- Swift 6 strict concurrency 与 Swift 6.2 isolation semantics；
- macOS 与 iOS Simulator 全量测试；
- W1 Feed Scroll、W2 Detail Hero、W3 Auth Gallery smoke artifact；
- curated critical mutants；
- rollback gate；
- Release、TSan、ASan 与严格 `swift-format`；
- 本地 Evidence Bundle（仅 `agent-declared / unproven`）。

统一验证入口：

```sh
RUN_CRITICAL_MUTANTS=1 scripts/verify-phase0a.sh
```

当前仍未达到 `0a-complete`。剩余阻塞项是远程受保护 required check、branch protection、可信 CI run locator、accountable human attestation 和与实现环境隔离的 held-out evaluator；本地成功不得冒充这些证据。

- [Phase 0a 实现面](docs/specifications/phase-0a-surface.md)
- [架构入口](docs/ARCHITECTURE.md)
- [实现者最短路径](docs/README.md)
- [测试 ID 注册表](docs/TEST_CATALOG.md)
