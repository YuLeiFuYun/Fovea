# 缓存预算、配额与回收规范

> **状态：Active 子集 + Proposed 扩展。** PhysicalBlobID、总量软目标、单 blob 上限、近似持久 LRU、启动 reconcile 与 mark-and-sweep GC 已实现；namespace/category quota、lease ledger 与动态 DiskIOBudget 仍属 Core v1 Candidate。

## 1. 目标

缓存必须有界、可解释，并且一个 namespace、缓存类别或异常大对象不能挤占整个进程或磁盘。淘汰和 GC 不得删除正在读取的对象，也不得在交互路径进行全盘扫描。

## 2. 预算层级

```text
Store hard limit
└── Store soft target
    ├── namespace quota
    │   ├── OriginalEncoded
    │   ├── DerivedEncoded
    │   ├── Analysis
    │   └── metadata/partial
    └── global reserve / maintenance headroom
```

内存与磁盘预算分别管理。预算值是配置与平台 profile 的组合，不进入图片结果 key。

规则：

- hard limit 不能被普通写入突破；
- soft target 用于提前回收，避免每次触顶才同步清理；
- 每个 namespace 有独立配额或受控共享池；
- public namespace 不能无限挤压认证 namespace，认证 namespace 之间也不能互相借用到不可清理；
- Analysis 和 DerivedEncoded 使用独立预算，默认优先于 OriginalEncoded 被回收；
- partial/staging 有单独小预算和短 TTL。

## 3. 物理对象身份

`ContentID` 是逻辑内容摘要，不直接作为日志值或跨 namespace 共享的物理文件名。

存储层使用：

```text
PhysicalBlobID = store-local random/opaque identifier
```

metadata 在同一 namespace 内维护 `ContentID -> PhysicalBlobID` 索引。这样：

- 保留内容寻址查重；
- 物理目录不直接暴露已知内容摘要；
- 不同 namespace 即使字节相同也得到不同 physical locator；
- StoreGeneration 切换不会依赖旧文件名协议。

物理文件名仍不是完整性证明；读取必须验证长度、格式版本和内容摘要。

## 4. Phase 0a 最小磁盘治理

0a 从第一天使用随机、不透明 `PhysicalBlobID`，不得先用 ContentID/SHA-256 文件名再计划迁移。0a 只实现：

- `softTotalBytes` 总量软目标与独立 `maximumBlobBytes` 单对象上限；
- 写入与启动 reopen 时检查并收敛预算；
- 以 manifest 初始时间、进程内访问时间和 blob mtime 形成近似持久 LRU；
- 清理失败、ENOSPC 或统计不精确不覆盖成功 final；
- 清理不得同步全盘扫描或阻塞 UI critical path。

namespace/category quota、持久 lease、精确 ledger reconciliation、mark-and-sweep crash matrix 和多进程协调后移。安全外形从 0a 正确，复杂优化不前置。

## 5. 活跃租约与删除

每个读取或正在交付的 blob 持有短期 read lease/pin：

- 淘汰先删除逻辑 record，可见性立即消失；
- 有 active lease 的物理 blob 延迟删除；
- lease 具有进程内生命周期，不作为跨崩溃持久引用；
- crash 后通过 ref ledger 与 mark-and-sweep 恢复；
- pin 不得由普通调用者无限期持有。

## 6. 回收顺序

默认回收顺序是策略起点，不是永久算法承诺：

```text
expired partial/staging
orphan/corrupt objects

- bootstrap 与运行期 GC 都扫描未被当前 manifest 引用的物理 blob 和暂存文件；即使 manifest 没有 victim，也会重试收敛此前物理删除失败留下的孤儿；
- representation 语义与存储协议位于 `FoveaHTTP`，具体 JSON manifest actor 位于 `FoveaPersistence` 且保持 package implementation；
expired Analysis
DerivedEncoded
低价值 OriginalEncoded
其余可回收 metadata/blob
```

规则：

- `no-store` 从不进入回收系统；
- revoked namespace 逻辑上优先整体不可达，物理删除受 I/O 预算执行；
- OriginalEncoded 是否比 Derived 更值得保留由 trace 验证，但默认不因派生物挤掉唯一可重建来源；
- eviction 不能删除当前任务唯一尚未交付的输入；
- 安全清理优先级高于普通性能 GC。

## 7. 访问时间与写放大

每次 cache hit 不重写全量 manifest。当前实现每个 blob 最多每 5 分钟 best-effort 更新一次 mtime，并在进程内保留更精确的访问时间；mtime 更新失败只降低淘汰精度，不使命中失败。

允许：

- 内存聚合；
- 分桶时间；
- 批量 flush；
- 采样更新；
- approximate recency/frequency。

必须测量 metadata write bytes 和 flash write amplification。为了精确 LRU 导致持续写盘属于失败设计。

## 8. 磁盘压力

- 启动和写入前读取可用容量信号；
- 接近 hard limit 或系统低空间时停止非必要 Derived/Analysis 写入；
- critical disk pressure 下只保留当前请求必要 staging，优先 GC；
- ENOSPC 不使已生成 final 失败；
- GC 不得与前台 decode/commit 无界竞争 DiskIOBudget。

## 9. 多 namespace 公平性

- 预算策略不能依赖原始用户 ID 排序；
- 默认按显式 quota 与使用量比例回收；
- 活跃 namespace 可以获得短期 burst，但必须有上限与归还机制；
- 登出 namespace 的所有逻辑引用立即撤销，不等待公平调度；
- quota、usage 和 eviction reason 只输出脱敏类别。

## 10. Property tests

- **GC-PT-001**: 单一大对象不能突破 hard limit；
- **GC-PT-002**: 一个 namespace 达到 quota 不会驱逐另一个 namespace 的受保护预算；
- **GC-PT-003**: active lease 阻止物理删除但不阻止逻辑 miss；
- **GC-PT-004**: crash 后 ref ledger/mark-and-sweep 不提前删除仍被引用 blob；
- **GC-PT-005**: PhysicalBlobID 随机且不透明；同一 ContentID 在不同 namespace 不复用物理 locator，文件名/日志不暴露 ContentID；
- **GC-PT-006**: Derived/Analysis 不挤掉唯一 OriginalEncoded 超过策略上限；
- **GC-PT-007**: atime 批处理不会让 hit 路径同步写盘；
- **GC-PT-008**: ENOSPC 时 final 仍交付且无半提交；
- **GC-PT-009**: revoked namespace 立即不可达；
- **GC-PT-010**: GC 在 DiskIOBudget 内运行，不阻塞交互任务；
- **GC-PT-011**: 0a soft cap 触发保守清理，清理失败不阻塞 final，且始终使用 opaque PhysicalBlobID。

## 物理回收证据与插件输入边界

GC 汇总报告实际删除的 regular blob 文件和字节，包括 manifest victim、临时文件与 manifest 外 orphan；已经不存在的文件不计作再次回收。计数使用饱和加法。

自定义 representation maintenance store 返回的 live references 最多 100,000 个；每个 `StoredContentReference` 必须包含规范 `sha256:<digest>:<byteCount>` ContentID。超过上限或非法引用不能阻止物理回收无限扩张。
