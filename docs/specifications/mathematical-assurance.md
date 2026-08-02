# 数学化工程保证

> **状态：Active。** 数学只在假设、反例、实现映射和可执行证据同时存在时进入工程决策。定理名称、公式数量和“前沿”标签都不能替代适用性证明。

## 1. 证据等级

Fovea 将数学证据分为六级，低一级不得冒充高一级：

1. **定理在明确假设下成立**：必须列出对象、目标函数、随机性、抢占、独立性和稳态假设，并说明 Fovea 偏离了哪些前提。
2. **有限模型穷举**：对声明的状态域和动作检查所有可达状态；结论只覆盖该抽象模型。
3. **有限输入域全枚举**：对显式因子笛卡尔积执行真实生产函数；不外推到无限语法空间。
4. **精确离线最优值**：对有限 trace 求 oracle 并计算 regret；oracle 知道未来，不能部署。
5. **模型式差分测试**：生产实现与独立数据结构/参考状态机执行大量确定性动作；发现偏差时固化最小反例。
6. **经验测量**：基准、模拟器、真机和真实 trace；必须报告环境、误差、分布漂移和不能外推的范围。

任何文档使用“保证”“最优”“完整覆盖”“概率不超过”等措辞时，必须同时给出输入域、状态域、假设、反例条件、证据级别和执行入口。

## 2. 理论研究注册表与拒绝权

`docs/research/mathematical-theory-registry.json` 是数学研究的机器可审查入口。每项理论必须记录：

- 原始或当前一手来源；
- 严格假设；
- 对应的 Fovea 机制；
- 采用、研究、候选或拒绝决定；
- 代码和证据路径；
- 能推翻当前决定的反例；
- 结论边界。

当前注册表覆盖并发正确性、形式方法、缓存、调度、公平、统计、几何、网络与重试。`check-mathematical-research.py` 会拒绝没有反例条件、没有近年研究依据、实现路径不存在或把候选理论伪装成已实现保证的条目。

**MATH-PT-015**：数学理论注册表覆盖四种决策状态，且所有条目具备来源、假设、反例、实现映射和边界。

“最新”不是自动采用理由。例如 Robust Gittins 的近期研究说明标准 Gittins 对轻微服务时间分布误差可能失去鲁棒性；在 Fovea 尚不能稳定估计多阶段服务分布、且任务部分不可抢占时，它被明确拒绝作为生产替代。学习增强缓存同样只保留研究入口：必须先证明错误预测时仍能回退到有界基线。

## 3. 架构图不变量

生产模块建模为有向图 `G = (V, E)`，模块是节点，声明依赖是边。门禁验证：

- 强连通分量均为单节点；
- Swift `import` 是 Package 声明依赖的子集；
- 生产模块直接扇出不超过 5，测试支持模块不超过 8；
- 计算拓扑层级、传递依赖、介数中心性、依赖集中度 HHI；
- 使用 `I = Ce / (Ca + Ce)` 记录不稳定度，并把稳定模块依赖更不稳定模块列为审查义务。

**MATH-PT-001**：`analyze-mathematical-architecture.py` 生成绑定源码树的图工件，并保持无环、无隐藏边和扇出上界。

图指标不是“架构质量总分”。中心性只能指出变更风险和审查优先级，不能证明抽象边界语义正确。

## 4. 缓存事务有限模型

缓存事务模型包含 namespace generation、representation record、blob、rendered-memory、覆盖事务快照和候选记录，穷举 200/no-store 发布、覆盖提交/取消、revoke、rendered 发布/清理和 GC。

模型验证：

- 当前代际同一变体最多一个可见 record；
- record 必须引用存在 blob；
- rendered-memory 不公开旧 generation；
- `no-store` 不产生跨请求可复用状态；
- revoke 严格推进 generation 并清除 rendered 状态；
- 活动代际覆盖取消恢复旧 record；
- revoke 后取消不得复活旧 generation。

五种错误模型——record 无 blob、`no-store` 持久化、revoke 不推进 generation、revoke 后恢复旧 record、保留旧 rendered——都必须产生最短反例。

**MATH-PT-002**：有限缓存事务模型通过，且全部内置错误模型被反例杀死。

模型不能证明 Swift 实现与抽象模型双向等价，因此仍需集成、故障注入、变异和文件系统测试。

## 5. HTTP 缓存有限决策域与 MC/DC

缓存准入域为：

```text
namespace: public / private
Cache-Control: 8 类
Vary: absent / field / wildcard / invalid
Vary selection: available / unavailable
```

总空间 `2 × 8 × 4 × 2 = 128`。XCTest 对全部组合调用真实 `HTTPCachePolicy`，与独立 oracle 比较；Python 门为核心布尔条件寻找 MC/DC 独立影响见证。

**MATH-PT-003**：128/128 个有限组合全部执行，五个核心布尔条件均有 MC/DC 见证。

这不代表任意 HTTP 字符串已穷举；语法空间仍由 RFC/WPT、边界和模糊输入覆盖。

## 6. 缓存策略、离线 oracle 与 SIEVE

离线分析同时报告对象命中、字节命中、避免的加载代价、相对精确离线最优值的 regret 和元数据更新次数。有限 trace 通过所有容量可行子集的动态规划得到精确 oracle。

**MATH-PT-004**：所有在线策略结果不得超过离线 oracle，并为每个 trace 输出 regret。

分析没有发现一个策略在所有 trace 上严格支配其他策略，但发现生产 LRU 在混合 miss cost、循环画廊和 Workbench 回屏序列上存在显著 regret；同时逐命中移动链表会放大 actor 热路径写操作。结合 NSDI 2024 SIEVE 在大规模 Web cache trace 上的结果，RenderedMemory 改为单一 SIEVE 状态机：

- 插入维持 FIFO 双向链表；
- 命中只设置一位 `visited`，不移动链表；
- 淘汰指针遇到已访问对象时清位并跳过；
- 遇到未访问对象时淘汰；
- 超大对象仍直接拒绝，成本上限保持硬约束。

旧 LRU 生产分支已删除。研究脚本仍保留 LRU、GDSF 等比较器，因为删除生产兼容不等于删除基准对照。

**MATH-PT-007**：命中项至少获得一轮 second chance；持续访问热点与顺序扫描交错时，热点保持驻留且扫描项被回收。

**MATH-PT-008**：生产 SIEVE 与独立数组/循环指针模型执行 32 个固定种子、每个 800 步的插入、命中、删除、清空和全键审计，逐步比较返回值、成本和条目数。

SIEVE 不利用对象尺寸与 miss cost 的价值密度。学习增强准入、GDSF 或 TinyLFU 若要进入生产，必须在真实脱敏 trace 上证明净收益，并给出错误预测和分布切换下的鲁棒回退。

## 7. 带权许可调度：局部 SPT 与容量保留

同产品优先级内，未触发防饥饿时按 work estimate 从小到大准入，估计相同保持 FIFO。它只借用最短处理时间优先在等权单机、准确处理时间、不可抢占条件下的局部结论，不宣称完整管线最优。

旧状态机只在大请求“当前能装入”时提升它。若总容量为 `C`，长期任务占 `C - 1`，大请求需要 `C`，一单位小请求持续到来，大请求即使达到绕过阈值也可永久等待。修复后的 drain 状态：

1. 达到阈值后为最老大请求保留未来足量容量；
2. 不再把碎片容量发给非保留请求；
3. 新请求不能通过立即获取快路径穿透；
4. 在途许可释放后整体授予保留者；
5. 保留者取消时解除保留并重新调度。

**SCHED-PT-018**：同优先级小工作优先，估计相同 FIFO。

**SCHED-PT-019**：单位权重 waiter 达到阈值后进入 FIFO 饥饿集合。

**SCHED-PT-020**：带权 waiter 触发容量保留；容量 `2...8` 的有限反例族全部通过，无保留 mutant 在 `7/7` 个实例上失败。

结论依赖已授予任务最终释放许可、单请求不超过总容量和队列未被外部永久冻结；八次是进入 drain 的绕过阈值，不是墙钟完成时间上界。

## 8. Single-flight 线性化、版本戳与 ABA

`SharedTaskRegistry` 的顺序规范包含 subscribe、cancel-immediate、cancel-with-tombstone、detach、complete、orphan lease expiry 与 cancellation lease expiry。`taskID`、`orphanLeaseID` 与 `cancellationLeaseID` 是逻辑版本戳：旧完成或旧租约事件不得作用于同 key 的替换任务。

有限模型完整枚举单键、两个订阅者、三个 task ID、六个 lease ID，以及四类状态：

```text
absent
active
orphan-handoff
cancellation-tombstone
```

检查：

- 不存在无 entry 但仍保留订阅者或任一租约；
- active subscriber 不能同时保留 quiescence lease；
- 已取消任务只有在零订阅 cancellation tombstone 中才能保留；
- tombstone 期间迟到 subscribe 不能启动替换 operation；
- completion 不能在 cancellation lease 到期前删除墓碑；
- 旧 task/lease 事件不能改变当前任务；
- orphan 和 cancellation 两类租约都必须一步收敛到 absent。

当前 canonical 模型探索 `705` 个状态、`8,346` 条转移，并杀死 `6/6` 个最小 mutant：

```text
completion 忽略 taskID
orphan expiry 忽略 leaseID
join 不清除 orphan lease
subscribe 绕过 cancellation tombstone 重启
completion 提前删除 cancellation tombstone
cancellation expiry 忽略 leaseID
```

仅删除 orphan expiry 的“订阅者为空”检查，在 join 原子清租约的不变量下仍没有独立反例，因此继续记录为防御性冗余，而不是伪造为最小必要条件。

**MATH-PT-011 / SCHED-PT-021**：有限模型、确定性 Swift 回归与 W7 取消风暴共同约束版本戳、不可复活和零取消后字节；结论不外推到无限键空间或任意墙钟调度。

## 9. 响应式目标的相对误差量化

旧纯线性 16px 分桶只提供绝对误差界：大尺寸窗口连续拖动会产生大量几乎等价的 DecodeKey，且没有恒定相对膨胀界。当前 schema 2 只维护混合量化：

- 小于阈值时使用固定步长，保留小缩略图精度；
- 大于阈值时按至少 6.4% 的相对增量构造几何桶；
- 始终向上量化，禁止欠采样；
- 原始尺寸先检查最大维度，桶结果再检查像素总数；
- 旧 schema 直接拒绝，不保留兼容分支。

对原始尺寸 `257...4096` 的全枚举验证：

```text
bucket / raw ≤ 1.07
bucketArea / rawArea ≤ 1.145
geometricBucketCount < linearBucketCount / 3
```

**MATH-PT-009**：持久策略只接受当前 schema，旧或损坏配置失败关闭。

**MATH-PT-010**：全枚举保证不向下量化、相对尺寸/面积膨胀受限，并显著减少解码身份。

这些是像素资源边界，不是完整感知率失真模型。HDR、内容频谱、缩放核和屏幕观看距离仍可能改变视觉最优点。

## 10. 延迟经验分布、DKW 与在线校准研究

Workbench 保留最近最多 128 个端到端延迟样本。对预先固定的 i.i.d. 样本，DKW–Massart 给出：

```text
P(sup_x |F_n(x) - F(x)| > δ) ≤ 2 exp(-2nδ²)
δ(n, α) = sqrt(log(2/α) / (2n))
adjustedQuantile = min(1, 1 - missProbability + δ)
prefetchCount = ceil(consumptionRate × empiricalQuantile(adjustedQuantile)) + 2
```

规划器还保留样本不足回退、10 秒延迟钳制和硬窗口。

**MATH-PT-006**：验证样本统计、风险/置信参数单调性、128 样本窗口、钳制和 reset。

真实请求相关且非平稳，因此 DKW 不能解释为生产漏载 SLA。2024–2025 的在线共形推断与 online optimization 更贴近分布漂移，但它要求每轮能观测漏预取/过预取损失。Fovea 当前尚未建立完整反馈闭环，所以该理论保持 research 状态，不以“更新”名义直接替换。

## 11. 重试：full jitter、协议下界和硬预算

当前 `TransportRetryPolicy` 只接受 schema 2，旧可配置 `jitterPermille` 已删除。对第 `k` 次失败：

```text
cap_k = min(maxDelay, baseDelay × 2^(k-1))
jittered = U(0, cap_k)
delay = max(min(Retry-After, maxDelay), jittered)
```

因此：

- full jitter 使用完整 `[0, cap_k]` 支持；
- `Retry-After` 是不可下穿的协议下界；
- 最大尝试次数、总延迟和额外响应字节仍是硬边界；
- TLS、认证、无效 URL 等终止错误不重试。

10,000 个同步客户端、2 秒 cap、10ms 定时器量化的精确占用与固定种子模拟结果：

```text
同步重试：精确成对碰撞概率 1.0，峰值 10,000
旧 ±20%：精确成对碰撞概率 0.0125，峰值 159
full jitter：精确成对碰撞概率 0.005，峰值 76
```

**MATH-PT-012**：生产函数覆盖区间端点、指数增长、cap 和 `Retry-After` 下界。

**MATH-PT-013**：`analyze-retry-jitter.py` 用精确桶概率和固定种子模拟验证 full jitter 的碰撞与峰值下降。

这只证明单轮量化定时器去同步。它不证明任意到达过程和服务器队列下全局稳定；近期“所有退避协议不稳定”的理论也基于不同竞争信道模型，不能机械套用到有限 HTTP 重试。硬预算仍不可删除。

## 12. 多资源公平基线

未来 namespace 配额不能只看内存；fetch 字节、decode working set、磁盘、并发许可和维护 I/O 构成资源向量。`analyze-multi-resource-fairness.py` 使用精确有理数实现 DRF progressive filling：

```text
dominantShare_i = max_r(allocation_i × demand_i,r / capacity_r)
```

三个非对称场景检查：

- 总使用量不超过各资源容量；
- 至少一个资源饱和；
- 每个主体获得不少于均分资源时的主导份额；
- 在有限整数误报域中，没有主体通过虚报需求提高按真实需求计算的效用。

**MATH-PT-014**：精确 DRF 基线通过容量、共享激励和有限策略性探针。

该结果不处理任务不可分割、动态到达、优先级、取消和跨阶段抢占，因此目前只作为资源治理设计 oracle。DRFQ 或更新的多资源机制进入生产前，必须先定义跨阶段可加的资源计量和虚拟时间。

## 13. 风格与解释义务

数学化不能使代码变成只有作者能理解的公式。Swift 使用 4 空格；生产大文件必须说明职责或边界；并发、缓存、安全和资源路径保留设计理由；禁止纯英文注释回归和逐行复述。

**STYLE-PT-001**：严格 Swift format 覆盖全部源码。

**STYLE-PT-002**：注释门验证中文解释、大文件职责、关键理由和异常高注释比例。

## 14. 后续证明义务

仍需推进：

- 将缓存事务和 namespace revoke 迁移到独立时序规范，并建立实现事件双向追踪；
- 采集脱敏真机 trace，比较 SIEVE 与学习增强但可鲁棒回退的准入策略；
- 为在线预取建立漏载、过取、取消和流量成本反馈，才能评估在线共形优化；
- 将 DRF 连续资源 oracle 扩展到不可分割任务、优先级和阶段时变模型；
- 研究随机网络演算前先测得真机到达/服务包络，禁止用松弛形式界冒充 SLA；
- 分别报告覆盖率、变异分数、MC/DC、状态数、regret、碰撞概率和公平性质，禁止压成单一数学总分。

## 15. 主要来源

完整来源和采用决定见 `docs/research/mathematical-theory-registry.json`。核心入口包括：

- Herlihy & Wing，Linearizability：<https://doi.org/10.1145/78969.78972>
- Zhang et al.，SIEVE，NSDI 2024：<https://www.usenix.org/conference/nsdi24/presentation/zhang-yazhuo>
- Rao et al.，Anvil，OSDI 2024：<https://www.usenix.org/conference/osdi24/presentation/rao>
- Ghodsi et al.，DRF：<https://www.usenix.org/conference/nsdi11/dominant-resource-fairness-fair-allocation-multiple-resource-types>
- Massart，DKW tight constant：<https://doi.org/10.1214/aop/1176990746>
- Susmann et al.，Online Conformal Prediction via Online Optimization，ICML 2025：<https://proceedings.mlr.press/v267/susmann25a.html>
- Relative-error scalar quantization：<https://doi.org/10.1109/TIT.2011.2162264>
- AWS current retry behavior：<https://docs.aws.amazon.com/sdkref/latest/guide/feature-retry-behavior.html>
## 16. 比较语义、S3-FIFO 与成本/尺寸感知准入

性能比较先定义语义剖面 `Sigma(i,w)`；输出质量、持久化、安全隔离、缓存策略、目标几何、颜色、取消、请求身份、资源边界、生命周期和隐私任一硬维度不等价时，结果只能是 `not-comparable`。统计并列要求预注册 `delta` 的 TOST 等价检验，不能把“不显著”解释为相同。

**MATH-PT-016**：比较治理器验证 22 个系统或基线、16 项能力、11 个语义维度、D0-D5 持久化等级和全部主指标的预注册等价阈值。

缓存离线台架新增两类研究候选：

- `s3-fifo-byte-adapted`：保留 small/main/ghost quick-demotion 结构，但按图片字节容量适配；
- `cost-size-aware-wtinylfu`：有界 Count-Min sketch、短窗口和 `frequency × missCost / residentBytes` 准入。

当前反例显示两者均不支配 SIEVE：S3-FIFO 在混合成本、尺寸偏斜和部分 Zipf trace 上更强，但在热点加扫描与 phase shift 上更弱；成本/尺寸感知候选在混合成本 trace 接近精确 oracle，却在循环和 phase shift 上出现高 regret。因此它们只进入研究注册表，不进入生产。

**MATH-PT-017**：所有在线候选继续受精确离线 oracle 上界约束，并在报告中写明模型边界；任何候选超过 oracle 或隐藏灾难性反例都使门禁失败。


## 17. 分层声明、取向化 loss 与 Pareto 边界

混合方向的指标先变换为统一 loss，随后定义：

```text
advantage(F,j,m) = loss(j,m) - loss(F,m)
```

正值才表示 Fovea 更优。点估计不直接生成非劣、等价或优越结论；判定使用预注册 margin、成组置信界、TOST 和 family 内 Holm 校正。

原“所有能力 × workload × 对手 × 指标全部不得 inconclusive”的全局谓词已删除。它会在检验数量增长时产生功效坍塌，也与真实 Pareto tradeoff 冲突。当前证书分为 L1 hard、L2 primary portfolio、L3 secondary frontier 和 L4 research。一个 L3 次要指标的证据不足只影响自己的作用域，不能否决无关 L2 声明；任何 L1 失败仍不可被性能抵消。

**MATH-PT-018**：声明策略、六个当前声明族和两个实验计划形成闭合；全局 `world best` 被禁止，只有绑定完整摘要的 `best-within-scope` 等有限输出。

## 18. 分布级证据：随机占优违约量与 Wasserstein

对 lower-is-better loss，经验一阶随机占优的违约量为：

```text
v = sup_x (F_comparator(x) - F_fovea(x))
```

`v = 0` 只表示本样本 ECDF 无交叉，不能自动推广到总体。`analyze-latency-distributions.py` 按 run/session block 重采样，报告 `v`、一维 Wasserstein-1 及 p50/p95/p99 loss 差的区间。普通等分布 KS 检验不是方向性随机占优检验，因此被明确排除。

W1 只有在单位、归一化和工程 margin 预注册后才能解释为整体分布等价；它不能替代“哪一个用户可感知尾部改善”的主 endpoint。

**MATH-PT-019**：支配、相同和交叉三个合成族均通过；交叉分布不得被提升为占优。

## 19. Delayed hits 与 latency-optimal oracle

传统缓存模型假设 miss 在下一请求前完成；single-flight 图片管线并不满足该假设。若对象在途期间再次被请求，这些 delayed hits 会累计剩余等待，因此命中率最优不保证延迟最优。

有限 DP 使用状态：

```text
(cache set, inflight key -> completion slot)
```

每个完成事件后，oracle 可旁路或缓存并淘汰任意对象；目标是最小总等待。自动搜索找到容量 1、delay 3、trace `abaab`：

```text
exact latency optimum = 7
Belady-like future-distance policy = 10
```

**MATH-PT-020**：已知小例和自动反例通过，任何基线不得低于精确 DP。该模型只覆盖统一尺寸、固定离散时延，不冒充通用 belatedly。

## 20. EVT、热状态与稳态的拒绝边界

Pickands–Balkema–de Haan 支持高阈值超额量的 GPD 渐近近似，但工程推断仍需选择阈值。阈值过低产生模型偏差，过高造成尾部样本稀疏和高方差；阈值选择不确定性不能被忽略。因此“拟合 EVT 即得到更窄 p99.9 区间并消除噪声”的说法被登记为负结果。

正式真机 block 必须从 `thermalState == nominal` 开始；运行中离开 nominal 则整块失效，冷却后从该随机块的首个 comparator 重跑。不得在同一半块上休眠后续跑。稳态诊断采用固定最大 warmup 和预注册 slope 容差；滚动 p90 只作警告/重跑依据，禁止看到竞品结果后无限丢弃样本。

**MATH-PT-021**：EVT 只保留为 L4 敏感性研究；比较计划硬编码 nominal thermal 和整块重跑边界。

## 22. 已验证编码 handoff：安全模型与最优性隔离

快速身份替换中的安全预热会产生一个短期问题：网络与位流验证已经完成，但最终可见消费者尚未接管，且持久化不应由已经消失的中间身份触发。Fovea 将这段状态建模为有界 encoded handoff，而不是额外 decoded-image cache。

容量不使用 fixture 派生常数，而复用 `PipelineConfiguration.transportMemoryThreshold`。因此 handoff 的额外编码驻留满足：

```text
0 ≤ residentEncodedHandoffBytes ≤ transportMemoryThreshold ≤ maximumTransportBytes
```

有限模型使用 `(namespace, generation, executionDigest)` 作为精确键，穷举插入、lookup、tick、revoke 和 purge，并检查：

- 超预算对象不驻留；
- 总驻留成本不超过预算；
- private、credentialed、non-automatic 与 no-store 不准入；
- 过期项不返回；
- execution、generation 与 namespace 必须全部相等；
- revoke 和 purge 后旧状态不可命中。

模型探索 `7,357` 个带深度状态和 `283,250` 条转移，并杀死 `5/5` 个 mutant：忽略 execution、忽略 generation、准入 no-store、跳过容量淘汰、revoke 不清理。

**MATH-PT-022**：`model-check-validated-encoded-handoff.py` 与 Swift 渐进加载测试共同约束 handoff 的资源和身份安全。

该结论不证明当前 SIEVE 驱逐对任意大小、任意取回代价的在线文件缓存最优。Landlord 在其模型中具有确定性在线竞争界，但 Fovea 必须先证明 HTTP 过期、动态网络/解码代价、撤销和定点实现满足其假设。该候选因此保持 `proposed`，不能借用理论名称宣称生产实现最优。
