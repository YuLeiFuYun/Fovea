# ADR-0014：技术中立的 Akashic Blob、分区、代际与事务契约

- **状态：Accepted**
- **日期：2026-07-29**
- **路线映射：**P3 / `OPEN-AKASHIC-INDEPENDENT-PACKAGE`
- **关系：**细化 ADR-0002、ADR-0007、ADR-0010 和 ADR-0012 的持久缓存边界；不修改 Fovea 的 HTTP、授权、namespace revoke 或跨存储提交状态机。

## 背景

Fovea 当前 package 内已经有三个 Akashic target：

```text
AkashicCore
AkashicMemory
AkashicDisk
```

其中 `MemoryCache<Key, Value>` 基本是技术中立的，但持久层公共 API 仍包含明显的 Fovea 图片语义：

- `OriginalEncodedStoring`；
- `OriginalEncodedMaintaining`；
- `OriginalEncodedStore`；
- `OriginalEncodedStoreLimits`；
- `contentID: String`；
- `namespace: String`；
- `StorageNamespaceFingerprint` 内固定 `fovea-storage-namespace-v1` 域分离。

直接把这些 target 复制到独立仓库，会把“Fovea 原始编码图片缓存”错误冻结为通用缓存模型，并造成两个方向的耦合：

1. Akashic 被迫理解 Fovea 的 ContentID、账户 namespace 和原始图片语义；
2. Fovea 容易把底层 blob publication 误当成 HTTP record、授权或 revoke 事务已经完成。

因此，独立提取前必须先定义技术中立的存储合同。该合同只描述 blob、逻辑分区、物理定位、代际、事务可见性和有界维护；图片、URL、HTTP 和账户含义由 Fovea adapter 解释。

## 决策

### 1. 区分五类身份

Akashic 首版必须区分：

```text
BlobDigest
CachePartitionID
PhysicalBlobID
StoreGenerationID
BlobStageID
```

#### `BlobDigest`

表示调用方声明并由 store 独立验证的字节身份：

```text
algorithm + digest bytes + byte count
```

首版只需要有限算法集合，默认只接受 SHA-256。不得继续使用自由格式 `String` 让 store 猜测算法和长度。字节数属于 digest 合同，可在分配和读取前用于有界校验。

`BlobDigest` 只证明指定字节域的完整性，不表示：

- URL 或 HTTP representation 身份；
- codec 派生身份；
- 发行者真实性；
- 当前授权；
- 持久化许可。

#### `CachePartitionID`

表示 store 内的不透明逻辑隔离域。Akashic 不知道它是否对应用户、租户、profile、namespace generation、实验或其他业务域。

AkashicCore 不提供 `init(namespace: String)`，也不固定 `fovea-*` 域分离。Fovea adapter 负责将：

```text
SecurityNamespaceID + NamespaceGeneration + storage purpose
```

投影为稳定、非明文、域分离的 `CachePartitionID`。

#### `PhysicalBlobID`

仍是 store-local、不透明物理定位符。它可以继续使用随机 UUID，但：

- 不进入 Fovea 的内容或派生身份；
- 不向调用方暴露文件路径；
- 不承诺跨 StoreGeneration、跨设备或跨实现稳定；
- 不能作为授权凭证。

#### `StoreGenerationID`

表示磁盘格式、schema 或实现兼容域。它与 Fovea 的 `NamespaceGeneration` 不同：

- `NamespaceGeneration` 是授权/可达性 epoch，由 Fovea 管理；
- `StoreGenerationID` 是存储格式与原子切换单位，由 Akashic 管理；
- Fovea 可以把 namespace generation 纳入 partition projection，但不能把两者混成同一整数。

#### `BlobStageID`

表示尚未公开的 staged blob。它只能由创建它的 store 实例发布或丢弃，不是 blob identity，也不能被读取、枚举或持久化到业务 record 中。

### 2. 公共值类型采用中立命名

目标公共值类型：

```text
BlobDigest
CachePartitionID
PhysicalBlobID
StoreGenerationID
BlobStage
BlobPublication
LiveBlobReference
BlobStoreLimits
BlobStoreUsage
BlobMaintenanceResult
AkashicError
```

其中：

- `BlobPublication` 只报告 physical ID、byte count 和是否创建；
- `LiveBlobReference` 为 `partition + digest`，只用于有界维护输入；
- `BlobMaintenanceResult` 使用通用 blob/count/bytes 术语；
- limits 和 usage 中所有 count、byte、enumeration 输入都有硬上限；
- 未来扩展字段不得改变现有 digest 或 partition canonical encoding。

### 3. 公共协议按机制拆分

目标协议最小集合：

```text
BlobStoring
TransactionalBlobStoring
BlobStoreMaintaining
StoreGenerationManaging
```

#### `BlobStoring`

概念操作：

```text
read(digest, partition)
commit(data, digest, partition)
physicalID(digest, partition)
remove(digest, partition)
removeAll(partition)
```

store 必须重新计算 digest，不能信任调用方提供的匹配结果。

#### `TransactionalBlobStoring`

概念操作：

```text
stage(data, digest, partition) -> BlobStage
publish(stage) -> BlobPublication
discard(stage)
```

语义要求：

- stage 成功不产生逻辑可见性；
- publish 成功后才可由 `read`/`physicalID` 观察；
- publish/discard 对 stage 的消费是 exactly-once 或幂等终态；
- 未发布 stage 在 reopen/recovery 后只能被安全丢弃或按明确 journal 恢复；
- 第三方 callback 不在内部 lock、actor invariant 或文件提交临界区执行。

#### `BlobStoreMaintaining`

维护能力包括：

```text
bounded usage
bounded garbage collection
corruption quarantine
orphan reconciliation
```

维护输入必须声明最大 reference 数量和总编码字节；不得要求调用方传入无界全集。没有实现某项维护能力时返回稳定 capability error，不得静默退化成全目录扫描。

#### `StoreGenerationManaging`

负责：

- 打开或创建 generation；
- 原子切换 active generation；
- 验证 manifest/schema；
- 恢复 CURRENT 指针和 fallback；
- 有界清理不再可达的旧 generation。

它不判断账户 logout、namespace revoke 或 HTTP cache 失效。

### 4. Fovea 保留领域适配层

以下名称和语义可以继续存在于 FoveaPersistence，但不进入 Akashic 公共 API：

```text
OriginalEncodedStoring
RepresentationRecordStoring
NamespaceGenerationPersisting
ContentID
SecurityNamespaceID
NamespaceGeneration
```

Fovea adapter 负责：

```text
ContentID -> BlobDigest
SecurityNamespaceID + NamespaceGeneration -> CachePartitionID
Fovea live original references -> Set<BlobReference>
```

adapter 还负责决定：

- `no-store` 是否允许持久化；
- HTTP record 是否与 blob 一起成为可命中状态；
- revoke 后哪个 partition 永久失效；
- blob publish 成功而 record publish 失败时如何登记 orphan；
- cache write failure 是否只降级为可交付但不持久化。

Akashic 不读取 URL、header、ETag、Vary、Age、认证 token 或 RenderKey。

### 5. Blob 事务不等于 Fovea 跨存储事务

Akashic 的 `publish(stage)` 只证明：

- blob 字节已经验证；
- 物理文件和该 store 的逻辑索引按其合同原子可见；
- 返回前满足声明的 fsync/rename/manifest 顺序。

它不证明：

- RepresentationRecord 已发布；
- namespace authority 仍有效；
- 304 merge 或 freshness 决策正确；
- UI 或 rendered cache 可以观察该内容。

Fovea 的 commit coordinator 继续在 publish 前后重验 authority，并协调 original blob 与 representation record。该状态机不得变成普通 Akashic plugin hook。

### 6. 分区、去重与机密性

首版默认规则：

- logical references 按 `CachePartitionID` 隔离；
- 物理去重只允许发生在同一个 `CachePartitionID` 内；
- 跨 partition 物理去重在首版明确禁止，未来只有在机密性、配额归属、删除和侧信道策略全部机器可读并通过独立证据后才能由新 ADR 开放；
- 未声明机密性时，digest/size/access pattern 仍可能形成侧信道；
- 机密部署若要求 namespace-only dedup、加密、padding 或固定 bucket，必须作为独立能力 profile 和证据，不得由“哈希了 namespace”推断得到；
- diagnostics 不输出原始 partition、digest、文件名或可关联路径，只输出有界、域分离摘要。

首版独立 Akashic 不声称解决多租户强侧信道隔离。

### 7. 同步、异步与执行器边界

- `MemoryCache` 保持同步且线程安全，不强制 actor hop；
- disk/blob 操作为 async；
- 阻塞 POSIX/Foundation I/O 进入专用 executor；
- Swift task cancellation 不能被描述为已中断正在执行的同步 syscall；
- 在 operation boundary 前后检查取消，已开始的文件操作必须收敛到可恢复终态；
- `@unchecked Sendable` 进入精确 allowlist，并由并发 history、TSan 或等价证据覆盖。

### 8. 错误和 capability 语义

`AkashicError` 至少稳定区分：

```text
notFound
integrityMismatch
invalidManifest
unsupportedSchema
unsupportedCapability
limitExceeded
storageUnavailable
transactionConflict
```

不得把 corruption、future schema、ENOSPC、permission、cancel 和 unsupported maintenance 都折叠为同一个成功 miss。Fovea 可以把部分错误降级为 cache miss，但原始结构化错误必须进入诊断和证据。

### 9. 首版明确不支持或不承诺

独立 Akashic 首版不自动承诺：

- 多 writer 进程一致性；
- 网络或分布式 object store；
- 跨 partition 强机密去重；
- hardware-backed anti-rollback；
- secure erase；
- HTTP cache 语义；
- 图片派生、codec 或颜色身份；
- 无界目录和引用集合；
- 任意第三方脚本式 eviction/commit hook。

首版固定为每个 StoreGeneration 一个活动 writer；同一进程和 store 实例内允许并发 reader，由 actor/锁语义保证。首版不承诺多进程 reader snapshot、reader lease 或无锁跨进程可见性。第二 writer 必须稳定失败，writer 异常退出后的恢复由 generation/manifest 验证和命名测试覆盖。

## 当前 API 到目标 API 的迁移表

| 当前名称 | 目标归属/名称 | 决策 |
|---|---|---|
| `OriginalEncodedStoring` | Fovea adapter；Akashic `BlobStoring` | 领域名称不进入独立库 |
| `OriginalEncodedTransactionalStoring` | Fovea adapter；Akashic `TransactionalBlobStoring` | stage token 中立化 |
| `OriginalEncodedMaintaining` | Fovea adapter；Akashic `BlobStoreMaintaining` | GC 输入改为 `BlobReference` |
| `OriginalEncodedStore` | `AkashicDisk.FileBlobStore` | 不以图片用途命名 |
| `OriginalEncodedStoreLimits` | `FileBlobStoreLimits` | count/bytes/manifest/scan 上限显式化 |
| `StorageNamespaceFingerprint` | `CachePartitionID` | 删除 Fovea 固定域分离构造器 |
| `StoredContentReference` | `LiveBlobReference` | `contentID: String` 改为 typed digest |
| `GarbageCollectionResult` | `BlobMaintenanceResult` | 通用 blob/bytes 术语 |
| `PhysicalBlobID` | 保留 | 明确 store-local、非授权、非内容身份 |
| `StoredBlob` | `BlobPublication` | 明确它是发布结果，不是内容身份 |
| `NamespaceGenerationPersisting` | FoveaPersistence | 继续由 Fovea 掌握 authority epoch |
| `StoreGenerationDirectory` | AkashicDisk | 使用 `StoreGenerationID` 明确格式代际 |

## 迁移顺序

### A. 契约冻结

1. 创建本 ADR 已冻结的 typed values 和 neutral protocols；
2. 添加 public API baseline、consumer fixture 和 canonical encoding vectors；
3. Fovea 内创建 adapter，旧调用点仍工作；
4. 新旧 API 在同一 trace 上做 differential。

### B. 独立仓库

1. 从稳定 source identity 提取 AkashicCore/Memory/Disk；
2. 建立 clean repository、remote、version 和 CI；
3. 运行 model、filesystem fault、crash switch-point、resource 和 consumer gates；
4. 明确磁盘格式是兼容复用还是新 StoreGeneration。

### C. Fovea 外部依赖迁移

1. 隔离 worktree 使用 local path dependency；
2. Fovea adapters 映射 typed identity；
3. 运行 W3、W8、W13、namespace revoke、cross-store commit 和 corruption tests；
4. 删除 Fovea 内嵌 Akashic production source；
5. 切换精确 tag/commit 并演练 rollback。

## 验证义务

至少新增并长期保留：

- digest algorithm/length/byte-count canonicalization；
- partition 隔离与错误 domain separation；
- duplicate commit 与 physical dedup 规则；
- stage/publish/discard exactly-once；
- publish 前不可见；
- crash at write/fsync/rename/manifest/CURRENT switch points；
- symlink、hardlink、owner、permission、external truncate/delete；
- future schema fail closed；
- bounded GC input、目录扫描、FD、RSS 和 write amplification；
- record publish failure 只产生可回收 orphan；
- revoke 与 in-flight publish 竞争时旧 generation 永不重新可达；
- custom store 不能通过伪造 digest 或 physical ID 绕过 Fovea verification。

## 后果

正面后果：

- Akashic 可以独立服务非图片消费者；
- Fovea 的 HTTP、授权和 revoke 边界更清楚；
- typed identity 减少自由字符串和类别错误；
- storage generation 与 namespace generation 不再混淆；
- 将来替换磁盘实现时有清晰 conformance 面。

代价与风险：

- 公共类型和 adapter 数量增加；
- 需要决定旧磁盘格式是否兼容；
- typed digest/partition canonical encoding 一旦发布就需要严格版本治理；
- 多进程、机密去重和 anti-rollback 仍是显式缺口；
- 在当前 dirty Fovea tree 上只能完成设计和审计，不能声称物理提取完成。

## 接受依据与冻结决策

本 ADR 于 2026-07-29 依据字段级迁移清单和当前实现审计转为 Accepted。接受仅冻结 P3 合同，不表示 P4 独立仓库或 P5 Fovea 迁移已经完成。

1. `docs/project-memory/akashic-contract-migration.json` 已记录当前 12 个公共符号、3 个 package-internal move、字段映射、领域泄漏位置和磁盘复用证明义务；
2. Fovea adapter 继续表达 original encoded、GC、namespace generation、revoke 和 representation-record 事务，Akashic 不接管这些语义；
3. `BlobDigest` 首版仅接受 SHA-256，并绑定规范 digest bytes 与精确 byte count；
4. 首版只允许 partition-scoped 物理去重，跨 partition 去重禁止；
5. 首版每个 StoreGeneration 只有一个活动 writer，只承诺同一进程/store 实例内的并发 reader，不承诺多进程 reader lease；
6. 首个独立 Akashic 版本使用新的 StoreGeneration。旧缓存可重建，不以复杂原地迁移换取启动风险；
7. `docs/project-memory/akashic-conformance-plan.json` 已分配 `AKASHIC-CT-001` 至 `AKASHIC-CT-030`，覆盖 P3 合同、P4 组件、P5 宿主组合和 P6 版本矩阵。

上述决定若改变，必须通过新的 ADR 和 discussion-ledger supersession；不能在实现过程中静默放宽。
