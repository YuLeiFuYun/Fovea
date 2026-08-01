# 语义可比性与有限作用域声明契约

> **状态：Active。** 本规格是任何性能排序之前的硬门。机器策略为 `Benchmarks/claim-policy.json`，声明族为 `Benchmarks/statistical-claim-families.json`。

## 1. 语义剖面不是一个总分

对实现 `i` 和 workload `w` 定义语义剖面：

```text
Sigma(i,w) = (
  outputQuality, durability, securityIsolation, cachePolicy,
  targetGeometry, colorManagement, cancellation, requestIdentity,
  resourceBounds, lifecycle, privacy
)
```

各维度可以包含自然等级或偏序，例如 D0–D5 durability、best-effort/underlying-work cancellation、公开/私有 namespace 隔离。性能直接排序只允许在 workload 所需硬维度上等价：

```text
Sigma(i,w) ==_R Sigma(j,w)
```

若一方合同更强，不把额外成本伪装成性能落后，而拆成：

- `same-profile race`：同级语义内排名；
- `stronger-contract cost`：单独报告更强合同的成本；
- `not-comparable`：差异会影响被测指标；
- `capability-gap`：对手无法进入该语义等级。

## 2. L1 硬正确性先于性能

任何一项失败即使数值更快，也不得进入排名：

- 当前 generation 结果身份正确；
- private/no-store/Vary/Authorization/redirect 隔离正确；
- subscriber exactly-once，取消后旧结果不复活；
- 目标像素、EXIF、色彩和 alpha 满足参考契约；
- 缓存、并发、像素、磁盘与临时文件保持硬上界；
- 声明的持久化等级通过对应 crash/restart 检验；
- 无 crash、hang、data race、deadlock 或敏感诊断泄漏。

`inconclusive` 在 L1 表示硬门尚未解决，不得按通过或失败猜测。

## 3. 磁盘持久化等级

| 等级 | 含义 |
|---|---|
| D0 | 普通写入，无原子性保证 |
| D1 | 原子替换 |
| D2 | 文件数据同步 |
| D3 | 父目录同步 |
| D4 | metadata 发布事务 |
| D5 | 内容校验的 durable commit |

D1 的吞吐不能用来否定 D5。原始数值可以报告，但只能在同等级内排名；兼容层增加的语义必须归属于兼容层，不得归功于原始项目。

## 4. 指标取向和统计判定

所有定量指标先转换为统一 loss：

```text
loss 越低越好
advantage(F,j,m) = loss(j,m) - loss(F,m)
```

正 advantage 才表示 Fovea 更优。禁止把“越高越好”和“越低越好”的点估计直接混入同一判定式。

- “差异不显著”不是并列；
- 等价必须通过预注册 `delta` 的 TOST；
- 非劣必须通过单侧置信界；
- 优越必须排除统计零点并超过预注册最小实际意义；
- 先按声明族进行 hierarchical gatekeeping，再在已打开的 endpoint family 内进行 Holm 校正；
- 重采样单位是成组的 run/session block，不把帧或请求伪装成独立重复；
- p95/p99 使用 block/moving-block quantile inference，并预注册最低尾部样本量；
- 样本不足时输出 `inconclusive`，只阻断所属声明族和祖先声明。

## 5. 四层证书

| 层级 | 内容 | 作用 |
|---|---|---|
| L1 Hard | 正确性、安全、身份、资源、持久化 | 全部必须通过 |
| L2 Primary portfolio | 一个有限作用域声明的少量预注册主 endpoint | 非劣/等价/优越 gate |
| L3 Secondary frontier | 次要效率、分布、能耗、CPU、Pareto 诊断 | 报告 tradeoff，不反向制造 L2 声明 |
| L4 Research | oracle、regret、替代算法、模型检查 | 不进入发布排名 |

次要指标可以形成 `co-pareto-frontier-within-scope`。它不等价于所有坐标最优，也不能覆盖 L1 失败。

## 6. 只允许 BestWithinScope

全局、无边界的 “world best” 营销声明被禁止。机器只允许生成绑定以下身份的有限证书：

```text
BestWithinScope(
  capabilitySet, workloadFamily, comparatorSet, deviceOSSet,
  semanticProfileVersion, sourceTreeDigest, binaryDigest,
  datasetDigest, experimentPlanDigest, claimFamilyDigest, harnessDigest
)
```

`best-within-scope` 要求：

1. 该作用域全部 L1 硬门通过；
2. 已打开的 L2 声明族内，每个主 endpoint 经校正后均为优越、等价或非劣；
3. 至少一个主 endpoint 达到预注册的实际意义优越；
4. 该族无 `inferior` 或 `inconclusive`；
5. 稳定系统、多真机、held-out、独立复现和全部摘要身份有效。

若全部主 endpoint 只证明等价/非劣，可输出 `noninferior-within-scope`，不能暗示最佳。

## 7. 分布证据的边界

- 一阶随机占优必须使用方向性的 dominance inference，并处理 block/serial dependence；普通“等分布 KS”或目测 ECDF 不足以证明总体占优。
- Wasserstein-1 是单位保持的整体分布距离。只有预注册尺度、margin 和 block-bootstrap 区间时才可作等价补充；它不说明具体是 p50、p99 还是中间区间改善。
- EVT/GPD 只作为 L4 尾部敏感性研究。阈值选择、依赖、拟合优度和阈值不确定性未进入预注册前，不得用于发布门或宣称“消除噪声”。

## 8. 证据失效条件

Simulator、beta OS、dirty tree、缺失竞品、未锁版本、删指标、修改上游测试、改变声明族成员或在结果后调整 margin 都不能产生发布级证书。没有绑定 `claimFamilyDigest` 的旧工件只保留为描述性证据。
