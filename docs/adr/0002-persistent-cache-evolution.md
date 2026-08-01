# ADR-0002：持久缓存格式、键编码与升级策略

- **状态：Proposed**
- **日期：2026-07-18**

## 背景

Fovea 的持久缓存包含 `RepresentationRecord`、Original/Derived blob、partial transfer、Analysis 结果和规范化键。Swift 库升级、字段增加、键规范变化或安全策略变化后，旧数据不能依赖“碰巧还能解码”。同时，应用启动不能因为缓存升级同步扫描整个目录。

## 决策

### 1. 禁止使用进程随机化哈希作为持久身份

持久键、文件名和 fingerprint 禁止使用 Swift `Hasher`、`hashValue` 或依赖字典遍历顺序的编码。使用版本化的规范编码，再以 SHA-256 生成摘要。

规范编码至少固定：字段顺序、整数端序、可选字段表示、字符串 UTF-8/Unicode 规范化、URL 规范化规则和 schema version。必须维护跨进程、跨架构 golden vectors。

### 2. 使用分层版本，而不是一个模糊的 schemaVersion

```text
StoreFormatVersion
KeySchemaVersion
RecordSchemaVersion
BlobFormatVersion
AnalysisSchemaVersion
```

codec、processor、model 的变化继续通过各自 fingerprint 使派生结果自然失效，不等同于存储布局迁移。

### 3. 混合升级策略

- **兼容的 record 增量变化**：读取旧版本，使用默认值补齐；命中后机会式重写为当前版本。
- **单条不兼容 record**：按 miss 处理，逻辑删除 record；关联 blob 进入延迟 GC，不在读路径同步清理整个 store。
- **KeySchema 或全局布局不兼容**：创建新的 `StoreGeneration`，原子切换当前 generation；旧 generation 后台按预算清理。
- **安全关键变化**：立即撤销旧 generation/namespace 的可达性，再异步物理删除。安全失效优先于命中率。
- **未知未来版本**：当前实现不得写回或修改；按不兼容 store 处理。

默认不保证缓存格式向下兼容。应用回滚不得让旧版本读取并改写新版本 generation。

### 4. 启动路径不得全量迁移

正常升级不在主线程或首次请求前同步扫描全部缓存。迁移必须可中断、幂等、受 DiskIOBudget 控制，并允许应用在新 generation 立即工作。

### 5. Blob 生命周期

一个 ContentID blob 可能被同一 namespace 内多个 record 引用。record 提交/删除与引用 ledger 在同一元数据事务中完成；物理 blob 只有在无 live reference 且超过 grace period 后删除。崩溃后通过 ledger 校验或 mark-and-sweep 回收孤儿，不能仅靠易失的内存 refcount。

### 6. 进程模型

v1 默认只承诺单进程协调。App Group 下的 App/Widget/Extension 不得在没有显式 multi-process coordinator 时同时写同一 store generation。SQLite WAL 只能协调数据库页，不能自动保证 blob rename、generation switch、GC 和 revoke 的跨进程原子性。

默认选择每进程独立 store；未来多进程能力必须通过文件锁/generation lease 和 crash matrix 后单独毕业。

### 7. 损坏与容量失败

缓存是可重建数据。record/blob 校验失败时隔离并按 miss 处理；metadata generation 损坏时创建新 generation。ENOSPC 或写权限失败不得把已成功解码的图片加载转成失败，只能记录 cache-write degradation。缓存目录默认排除备份，并应用平台文件保护策略。

## 后果

升级后会产生阶段性 miss 和短期双 generation 磁盘占用，但不会发生启动期全盘迁移、未定义解码或错误复用。复杂度集中在 Akashic 的存储层，不污染 Fovea 的请求 API。

## 验证门禁

- 持久键 golden vectors 在不同进程和架构完全一致；
- 旧 record 可兼容读或稳定 miss，不 crash；
- generation 切换中任意 crash point 均能恢复到一个完整 generation；
- 安全撤销后旧 namespace 立即不可达；
- record 多引用删除不会提前删 blob；
- 未知未来 schema 不被当前版本改写；
- 未启用 multi-process coordinator 时并发 writer fail closed，不静默共享；
- ENOSPC/损坏时无半提交，已成功解码结果仍可交付。
