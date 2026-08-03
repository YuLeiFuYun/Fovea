# Image Codec Conformance v1

该 kit 在独立临时 SwiftPM 测试包中验证实现 `ImageCodec` 的 backend，不导入 Fovea 模块或 backend 私有测试支持。

backend 仓库提供 factory source：

```swift
import ImageCraftCore
import YourCodecProduct

enum CodecUnderTest {
    static func make() -> any ImageCodec {
        YourCodec()
    }
}
```

运行：

```sh
python3 ConformanceKits/ImageCodec/v1/run.py \
  --codec-package-path /path/to/codec \
  --codec-product CodecProduct \
  --factory-source /path/to/CodecUnderTest.swift
```

v1 验证 descriptor、2,304 项有限能力域、声明格式的 probe/decode、资源估计组合和硬限制失败关闭。报告绑定 contract pin、backend source、factory、harness、Fovea kit tree、工具链和日志。

机器状态：`release-qualified: false`。参考小图不替代 hostile corpus、sanitizer、fuzz、真机资源、Fovea composition、shadow/canary 或 ImageIO fallback 证据。
