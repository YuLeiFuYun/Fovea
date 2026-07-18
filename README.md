# Fovea

**状态：Phase 0a-bootstrap，可运行垂直切片已建立。**

Fovea 是面向 Apple 平台的图片加载系统。当前无稳定公共 API，功能型设计继续冻结；实现范围以 [`phase-0a-surface.md`](docs/specifications/phase-0a-surface.md) 为准。

当前已打通：

```text
public URL
→ FetchVariantKey / FetchExecutionKey
→ bounded streaming + spill + SHA-256
→ OriginalEncoded + opaque PhysicalBlobID
→ ImageIO target-size decode
→ namespace-scoped RenderedMemory
→ SwiftUI FoveaImage
```

本地验证：

```sh
scripts/verify-phase0a.sh
```

该入口会使用完整 Xcode，执行 Phase 0a surface 检查、严格 `swift-format`、macOS SwiftPM 测试和 iOS Simulator 测试。

当前仍未达到 `0a-complete`。剩余阻塞项包括：真实远程 required check/branch protection、关键 mutant 自动化执行、rollback gate、W1/W2 harness 与受保护 Evidence Bundle。

- [Phase 0a 实现面](docs/specifications/phase-0a-surface.md)
- [架构入口](docs/ARCHITECTURE.md)
- [实现者最短路径](docs/README.md)
