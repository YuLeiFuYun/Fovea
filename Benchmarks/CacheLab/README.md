# Fovea Cache Lab

Cache Lab 将图片管线中的缓存能力从端到端 UI 实验中分离，分别验证内存淘汰、并发、磁盘持久化、损坏恢复与语义等价性。

## 当前对象

内存：Fovea SIEVE、LRUCache 1.2.1、PINMemoryCache 3.0.4。

| 磁盘 contestant | 等级 | 角色 | 说明 |
|---|---:|---|---|
| Fovea | D5 | primary | 内容校验、原子发布、文件/目录同步与持久 metadata |
| PINDiskCacheNative | D1 | descriptive | 保留原生吞吐，不与 D5 强排 |
| PINDiskCacheDurableValidated | D5 wrapper | primary | harness 增加文件/目录同步、序列化摘要、API 回读摘要与 durable proof |

强化保证属于 Fovea Benchmark Harness，不归因于 PINCache 原生实现。

## 当前声明契约

`cache-plan.json`（V4）与 `../statistical-claim-families.json` 在下一次正式结果前共同锁定：

- 20 个独立 runner process block；每个 block 内 3 次轮转 inner trial 取中位数，bootstrap 单位仍是进程块；
- 10,000 次 paired bootstrap；
- TOST 等价、单侧非劣、实际优越 margin；
- claim-family gatekeeping 后的 Holm 校正；
- L1 硬正确性、L2 主 endpoint、L3 描述指标、L4 oracle 研究分离；
- schema 4 raw report 必须分别绑定 Fovea 与实际解析到的 Akashic source identity、plan digest 与 claim-family digest；edited dependency 只能生成研究证据；
- 正式模式先完成 release runner 构建，再要求至少 10 个连续 1 秒样本无外部编译活动；构建时间不进入测量；
- 正确性探针与 20 个统计单位分别运行在独立受监测进程中；某次进程受外部 build driver/活跃 compiler 污染时，只丢弃该次 attempt，等待恢复空闲后重试当前 block，已接受的 clean block 不重跑；
- raw report 仅在 20 个 clean block 全部完成、主机证据聚合后原子替换；预检失败、中断、污染 attempt 或超时不得覆盖上一次完整工件。

`p > 0.05` 不是并列；单次 calibration 的 `inferior`/`superior` 也不是正式结论。

## 当前证据状态

Cache Lab 要求逐 endpoint 支配：除达到机器可证明最优下限的指标外，每个适用 L2 主指标都要求相对每个合格对手的 95% 区间下界超过预注册的 20% 实质领先幅度。

历史计划均保留且不得改写：

- V2 的最终 tree-bound campaign 在 13 个适用比较中通过 12 个；热扫描吞吐下界约 1.149×。随后发现 V2 将 payload/key 构造混入总吞吐、但未混入 p99，计时边界不一致；
- V3 预生成 corpus，但计划声明 `rounds=20`、实现实际只执行 1 轮。其最终全量运行还有 3 个 dominance failure：热吞吐、热 p99 和磁盘 p99，因此 V3 也只保留为历史研究证据。

V4 修正两类方法问题：

- `MEM-HOT-SCAN-V4` 在每个 inner trial 中执行 20 个 fresh-cache round；所有 key/value 在计时前生成，每轮只计 4096 次扫描插入和 32 次热读取；
- `DISK-MIXED-V4` 的吞吐仍来自一次完整读取 pass；p99 则来自其后 8 个确定性轮转的完整语料读取，共 1536 个同步延迟样本/contestant/block，每轮结束后 quiesce，额外采样不进入吞吐时长。

V4 候选固定为 8 分片，并在任何 V4 正式数据前完成选择：

- 32 分片因静态局部预算每轮只保留 21/32 热对象而拒绝；
- 16 分片在真正的 20-round workload 中只保留 619/640 热对象而拒绝；
- 8 分片在 5 个独立进程、共 100 rounds / 3200 次热项探测中全部保留，完整 7 项 CacheLab 测试与 formal process-model 回归通过；
- 一次 5-run memory calibration 发生大量外部编译污染，只能用于诊断，不能作为性能结论。

V4 `--scope all` 本地正式 campaign 已接受 20 个独立 clean process block，并在 13 个适用“主指标 × 合格对手”比较中全部跨过预注册的 20% 支配下界；正确性、inferior、inconclusive 与 dominance failure 均为 0。该结论只属于锁定 workload、比较器与本机环境，不是无边界“最好”声明。

Akashic 当前候选还通过了 55 项测试、无 Git clean-copy 重放、8 syscall + 1 权限迁移 + 11 精确 crash switch + 78 随机 kill + 3 满卷 + 3 quota、12 进程 generation contention、3 个资源包络和 Apple 六平台 Release 矩阵。内容身份为 81 文件、`91608c55745b333bf28b923bf0bf64744541b5e81344f061a251adea483bdb92`；Fovea 独立源副本显式编辑到该 Git-free 候选后通过 478/478。`scripts/verify-component-candidate-clean-copy.py` 固化了该验证路径。

本地性能与候选机械门通过仍不等于发布证书：Akashic 尚未形成公开 revision，Fovea 尚未更新精确 pin，两个工作树仍 dirty，也尚未在 protected trusted CI 从 clean checkout 复验。因此 `bestClaimEligible` 必须保持 false。

## 研究扩展

- `analyze-cache-policies.py` 保留 S3-FIFO 与 cost/size-aware TinyLFU 的正反例；两者未获生产替换资格；
- `analyze-delayed-hit-cache.py` 在统一尺寸、固定延迟有限模型中求累计等待精确最优，并找到 hit-rate Belady-like 非延迟最优反例；
- 负结果进入 `docs/research/negative-results.json`，不得从最终叙事中删除。

## 执行

```sh
python3 scripts/check-cache-lab-plan.py
python3 scripts/test-cache-lab-host-monitor.py
python3 scripts/test-cache-lab-formal-process-model.py
python3 scripts/test-cache-lab-source-identity.py
python3 scripts/verify-component-candidate-clean-copy.py --akashic-source /path/to/git-free/Akashic
DEVELOPER_DIR=$(scripts/select-xcode.sh) xcrun swift test --package-path Benchmarks/CacheLab
# 快速内存候选校准；不生成完整证书
python3 scripts/run-cache-lab.py --mode calibration --scope memory
# 完整校准与正式证据
python3 scripts/run-cache-lab.py --mode calibration --scope all
python3 scripts/run-cache-lab.py --mode formal --scope all
```

V1/V2/V3 计划分别保留在 `plans/cache-plan-v1.json`、`plans/cache-plan-v2.json` 与 `plans/cache-plan-v3.json`；新结果不得回写旧计划语义。
