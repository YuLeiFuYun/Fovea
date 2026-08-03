# Persistent Store Provider Conformance v1

该 kit 在独立临时 SwiftPM 包中验证 `FoveaPersistentStoreBundleProviding`，不导入 Fovea 的 package-only 测试支持或默认 Akashic adapter。

provider 仓库提供一个 factory source：

```swift
import FoveaAdvancedSystem
import YourProviderModule

enum ProviderUnderTest {
    static func make() throws -> any FoveaPersistentStoreBundleProviding {
        try YourProvider()
    }
}
```

运行：

```sh
python3 ConformanceKits/PersistentStoreProvider/v1/run.py \
  --provider-package-path /path/to/provider \
  --provider-product ProviderProduct \
  --factory-source /path/to/ProviderUnderTest.swift
```

path dependency identity 默认取 provider 目录名；只有 URL/自定义 identity 场景才需要传 `--provider-package-name`。

v1 验证 descriptor 稳定性、首次 fetch/decode/publish、释放后同 root 无网络重开、namespace revoke 后不复活，以及有界打开参数。报告绑定 manifest、harness、factory、provider source、Fovea working-tree、Swift/Xcode 和日志哈希。

通过该 kit 不证明断电安全、真实文件系统故障、跨进程 writer exclusion、能耗或真机资源资格；这些证据必须由 provider 自己的组件矩阵和 Fovea qualification 组合证明。

机器状态：`release-qualified: false`。该值只有在独立 crash-consistency、跨进程 writer exclusion、版本矩阵和 Fovea qualification 组合证据完整后才可能改变。
