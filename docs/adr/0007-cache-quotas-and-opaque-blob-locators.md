# ADR-0007：缓存配额与不透明物理 Blob 标识

- **状态：Proposed**
- **日期：2026-07-18**

## 背景

Fovea 使用 ContentID 做内容寻址，但跨 namespace 默认不共享。若直接把 ContentID 作为物理文件名，会在目录层暴露稳定内容指纹；若没有总量、namespace 和缓存类别配额，一个账户或 Analysis/Derived 数据可能挤占全部磁盘。精确 atime 每次命中写盘还会制造额外写放大。

## 决策

1. ContentID 保持逻辑内容身份，不直接作为日志值或物理文件名。
2. 每个 namespace/store generation 使用随机、不透明 `PhysicalBlobID`；metadata 维护 ContentID 到 locator 的索引。
3. 设置 Store hard limit、soft target、namespace quota 和类别预算。
4. DerivedEncoded、Analysis、partial/staging 使用独立预算；普通情况下优先于唯一 OriginalEncoded 回收。
5. active reader 使用短期 lease；先删除逻辑引用，再在 lease 释放后删除物理文件。
6. atime/frequency 采用内存聚合、分桶、采样或批量 flush，不在每次命中同步写盘。
7. GC、orphan reconciliation 和物理清理受 DiskIOBudget 控制，不能位于 UI critical path。

## 后果

- metadata 多一层 locator 映射，但目录不暴露稳定内容摘要；
- 跨 namespace 隔离更完整；
- 缓存行为有明确上限和公平性；
- 近似 recency 可能牺牲少量命中精度，换取显著更低的写放大；
- physical locator 变化不影响逻辑 ContentID 和派生 key。

## 验证

见 `../specifications/cache-budget-gc.md`。
