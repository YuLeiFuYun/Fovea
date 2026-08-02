# Public API 预算复核：FoveaStorage 域边界提取（2026-07-30）

> **状态：Accepted current-tree ceiling，不是 1.0 稳定性声明。** 本次复核取代同日 1132-symbol 过渡预算。预算绑定已经完成的外部 ImageCraft/Akashic exact pins、typed Akashic 默认路径和 FoveaStorage 域契约提取；组件公共远端、alpha 标签与 required CI 已建立，但 Fovea 公共根、后续 rollback、稳定真机证据和正式发布仍未完成。

## 1. 核心判断

原先位于 `AkashicCore` / `AkashicDisk` 的 `OriginalEncoded*`、namespace fingerprint、revoke persistence 与 legacy store 都属于 Fovea 领域。它们已完成以下迁移：

- 公共领域契约进入 `FoveaStorage`；
- `FoveaStorage` 只依赖 `AkashicCore` 的 typed physical identity；
- 旧 `OriginalEncodedStore`、旧 manifest、旧 access journal 与旧 identity 实现已删除；typed adapter 是唯一生产原编码路径；
- `AkashicCore` 与 `AkashicDisk` 新增反向域泄漏门，禁止这些 Fovea 词汇重新进入；
- 具体 `AkashicOriginalEncodedStore` 继续保持 package-only。

这不是增加一个抽象层。`FoveaStorage` 的必要性来自现有无环依赖图：`FoveaHTTP.RepresentationRecord` 与 `FoveaCore` 都需要 namespace/storage identity，而 `FoveaCore` 已依赖 `FoveaHTTP`；把契约放进任一现有模块都会形成依赖环或反向职责泄漏。

## 2. 精确公共符号预算

```text
AkashicCore              77
AkashicDisk              31
AkashicMemory            15
FoveaAppKit              13
FoveaCore               425
FoveaHTTP               171
FoveaObservability       17
FoveaPersistence          9
FoveaStorage             26
FoveaSwiftUI             45
FoveaSystem               5
FoveaUIKit               12
ImageCraftCore          284
ImageCraftImageIO        14
--------------------------------
total                  1144
```

相较 1132-symbol 过渡预算，精确镜像增加 12 个公开符号：

- `AkashicDisk` 从 25 增至 31：恢复独立包已经公开并受 API baseline 约束的 generation descriptor/manager 表面；
- `AkashicMemory` 从 9 增至 15：恢复独立包的 removal summary、成本上限调整和精确 purge 报告；
- 这些符号不是 Fovea 新设计，也不是为未来预留；它们来自把内嵌目标改为与独立 128-symbol Akashic 公共契约完全一致；
- legacy actor 与四个辅助实现删除，没有形成第二套 public API。

因此 1144 是当前 exact-mirror 树的无余量 ceiling，而不是增长预算。
## 3. 模块职责

### FoveaStorage：26

只公开：

- `OriginalEncodedStoring` / `OriginalEncodedMaintaining`；
- `StorageNamespaceFingerprint`；
- `StoredBlob`、`StoredContentReference`、`GarbageCollectionResult`。

package-only 内容包括 staging token、transactional protocol、namespace generation persistence、绝对 namespace 容量与规范内容 ID 校验器。

该模块禁止依赖 `AkashicDisk`、`FoveaHTTP`、`FoveaCore` 或 `FoveaPersistence`。

### AkashicCore：77

只保留通用 digest、partition、physical identity、blob stage/publication、maintenance 与 generation 契约。不得出现 URL、HTTP、account、authorization、Fovea namespace 或 original-image-byte 语义。

### AkashicDisk：31

只公开 `FileBlobStore`、limits 与 store generation 机制。legacy `OriginalEncodedStore` 已删除；writer lease、fault injection 和文件元数据工具保持 package/internal。

### AkashicMemory：15

公开 SIEVE cache、删除摘要、成本上限收缩与精确 purge 报告；实现与独立 Akashic API baseline 完全一致。Fovea 自有同步热路径继续使用 `FoveaCompactSieveCache`，不通过 Akashic 私有类型耦合。

### FoveaPersistence：9

公共预算保持 9。默认 typed adapter 为 package-only，且不存在第二套 legacy production store；用户只看到组合能力和持久化打开结果。

## 4. 拒绝的公共增长

本次明确拒绝：

- 将 `FoveaStorage` 做成独立公共产品；它是 `Fovea` / `FoveaAdvanced` 的内部模块组成部分；
- 公开 legacy `OriginalEncodedStore` 或 `OriginalEncodedStoreLimits`；
- 为 `PhysicalBlobID` 增加跨模块 `CustomStringConvertible` conformance；文件名便利已降为 package-only 属性；
- 将 revoke、HTTP representation 或 commit coordinator 下沉到 Akashic；
- 为未来外部缓存实现预留额外符号预算。

## 5. 证据与边界

本轮证据包括：

- Fovea 当前宿主测试与 exact-revision clean-copy 演练均为 475/475；
- ImageCraft 与 typed Akashic 当前通过公共 exact pin 与独立 CI 约束；
- 临时包删除五个内嵌组件 target 后，精确 Git revision 解析、完整测试和 writer probe 构建通过；
- architecture boundary 与 structural quality 通过；
- AKASHIC-CT-022 至 CT-026 保持通过；
- typed store 首次发布、重复发布、重开读取、删除与再次重开 miss 的稳定宿主轨迹通过；
- AkashicCore/AkashicDisk 反向域泄漏门已启用。

本复核不证明 remote/tag/protected CI、真机资源资格、power-loss safety 或竞品 Pareto 优势。任何新增 public symbol 仍需删除等量表面，或提供第二个真实实现、consumer fixture、兼容性论证、DocC 与回滚证据。
