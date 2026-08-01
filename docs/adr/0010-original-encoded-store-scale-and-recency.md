# ADR-0010：OriginalEncoded 存储规模、预算与近似持久 LRU

- **状态：Accepted**
- **日期：2026-07-19**

## 背景

旧实现用同一个 `softLimitBytes` 同时表示总容量与单 blob 上限，并只在内存 manifest 中更新 `lastAccess`。进程重启后，淘汰顺序退回提交时间；运行时降低配额还可能把合法旧 manifest 误判为格式损坏。单 JSON manifest 的全量原子重写也必须有明确规模边界。

## 决策

1. 将运行预算拆为 `softTotalBytes` 与 `maximumBlobBytes`；后者不得大于前者。
2. manifest 语义有效性不依赖本次运行预算。预算降低时，启动 reconcile 删除超过新单对象上限的条目，并立即按总量目标淘汰，而不是判定整个 manifest 无效。
3. 成功读取在内存记录精确访问时间，并以 5 分钟时间桶 best-effort 更新 blob mtime。淘汰使用 manifest 初始时间、进程内时间和 mtime 的最大值。
4. 读命中不得因为 mtime 更新失败而失败；recency 降级只影响淘汰精度。
5. manifest 最多 100,000 条、编码后最多 64 MiB；超过边界时写入失败关闭。受支持 metadata 中单 blob 长度最多 1 GiB，实际 admission 仍由更小的运行配置决定。
6. 当前继续使用单 JSON manifest；分片、SQLite 或多 writer 只能由 benchmark 和迁移 ADR 触发，不提前引入。

## 后果

- 重启后热对象不再系统性退化为“最近提交对象”；
- 每次 hit 不重写全量 manifest，但会产生一次 best-effort metadata timestamp 更新；
- 降低预算成为可恢复的运行策略变化，而不是格式损坏；
- 规模假设变为可测试硬边界；超大 cache 必须迁移到不同存储模型。

## 验证

- 跨 reopen 读取后再写入，真正最冷对象被淘汰；
- 降低单 blob 上限只收敛超限条目；
- 降低总预算在 open 阶段立即 trim；
- manifest 与 blob 的原子发布、权限、摘要与 crash 恢复测试继续生效。
