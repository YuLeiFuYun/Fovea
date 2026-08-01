# Fovea Cache Lab

Cache Lab 将图片管线中的缓存能力从端到端 UI 实验中分离，分别验证内存淘汰、并发、磁盘持久化、损坏恢复与语义等价性。

## V2 对象

内存：Fovea SIEVE、LRUCache 1.2.1、PINMemoryCache 3.0.4。

| 磁盘 contestant | 等级 | 角色 | 说明 |
|---|---:|---|---|
| Fovea | D5 | primary | 内容校验、原子发布、文件/目录同步与持久 metadata |
| PINDiskCacheNative | D1 | descriptive | 保留原生吞吐，不与 D5 强排 |
| PINDiskCacheDurableValidated | D5 wrapper | primary | harness 增加文件/目录同步、序列化摘要、API 回读摘要与 durable proof |

强化保证属于 Fovea Benchmark Harness，不归因于 PINCache 原生实现。

## 当前声明契约

`cache-plan.json` 与 `../statistical-claim-families.json` 在下一次正式结果前共同锁定：

- 20 个 process-run block；
- 10,000 次 paired bootstrap；
- TOST 等价、单侧非劣、实际优越 margin；
- claim-family gatekeeping 后的 Holm 校正；
- L1 硬正确性、L2 主 endpoint、L3 描述指标、L4 oracle 研究分离；
- schema 3 raw report 必须绑定 source identity、plan digest 与 claim-family digest。

`p > 0.05` 不是并列；单次 calibration 的 `inferior`/`superior` 也不是正式结论。

## 当前 20 次 schema 3 本地证据

当前正式本地运行已经绑定 source identity、实验计划摘要和 claim-family 摘要：

```text
runCount = 20
foveaCorrectnessFailures = 0
primaryComparatorCorrectnessFailures = 0
statisticallyInferiorMetrics = 0
inconclusiveMetrics = 0
statisticalPerformanceGatePassed = true
sourceIdentityBound = true
claimFamilyIdentityBound = true
trustedCleanSource = false
bestClaimEligible = false
```

主要结果：

- hot-scan hit rate、吞吐和 p99 相对 LRUCache 均显著领先；
- concurrent throughput 相对 LRUCache 显著领先；
- concurrent p99 与 LRUCache 通过预注册 5% 界限的 TOST 等价检验；
- D5 写吞吐、读吞吐和 p99 读取延迟相对 D5 PIN wrapper 显著领先；
- 原生 D1 PIN 仍只作描述，不进入 D5 排名。

该结果仍绑定 dirty worktree，因此只能证明当前源码树上的本地统计门，不能生成可信发布证书。下一步只剩 clean final source 与 trusted CI 下的同计划重跑；不得把 dirty-source 结果改写为 release claim。

此前 schema 2 结果保留为历史工件，但已经被当前 schema 3 运行替代。

## 研究扩展

- `analyze-cache-policies.py` 保留 S3-FIFO 与 cost/size-aware TinyLFU 的正反例；两者未获生产替换资格；
- `analyze-delayed-hit-cache.py` 在统一尺寸、固定延迟有限模型中求累计等待精确最优，并找到 hit-rate Belady-like 非延迟最优反例；
- 负结果进入 `docs/research/negative-results.json`，不得从最终叙事中删除。

## 执行

```sh
python3 scripts/check-cache-lab-plan.py
DEVELOPER_DIR=$(scripts/select-xcode.sh) xcrun swift test --package-path Benchmarks/CacheLab
python3 scripts/run-cache-lab.py --mode calibration
python3 scripts/run-cache-lab.py --mode formal
```

V1 计划保留在 `plans/cache-plan-v1.json`，不得用 V2 结果改写其语义。
