# Fovea 解码资源契约审计：从单标量工作集到可组合覆盖

> 状态：Specified research, production admission gate open
> 日期：2026-07-29
> 路线映射：P0 / `OPEN-DECODE-RESOURCE-CONTRACT-AUDIT`
> 研究输入：ImagePipelineResourceEnvelopeLab、ImageCodecCapabilityAlgebra、DecodeSessionContractLab

## 1. 审计结论

当前 `ImageDecodeResourceEstimate` 只有一个 `workingSetBytes` 标量，Fovea 将 host 通用估算和 backend 估算按以下规则合并：

```text
max(genericBytes, backendBytes)
```

这个规则只有在两个输入都表示**同一个完整物理存活集合的上界**时才可证明安全。当前合同没有声明覆盖集合、物理别名、所有权、生命周期、持久输出、临时内存、外部分配或回收尾部，因此不能证明这一前提成立。

据此，本审计作出三个有界判断：

1. 当前规则可以继续作为现有 ImageIO 静态图路径的本地保守启发式，但不能被表述为已经证明的通用 codec 插件安全边界。
2. 在资源覆盖问题关闭前，不得让第二个 codec 获得默认生产准入，也不得仅凭一个较大的 `workingSetBytes` 声明完成资源隔离。
3. 不应立即把完整资源包络代数搬进热路径；应先用真实后端测量和生命周期审计确定最小生产合同。

## 2. 当前实现事实

### 2.1 Host 通用估算

`ImageDecodeWorkingSetEstimator` 当前估算：

- 缩略 surface；
- 一个可能的颜色转换 surface；
- fill 裁剪或最终输出 surface。

其文档同时明确排除：

- encoded data；
- rendered-memory cache；
- 系统框架内部固定开销。

这说明它不是完整进程工作集，也不必然覆盖 codec 私有临时分配。

### 2.2 Backend 估算

`ImageCodec.resourceEstimate` 返回相同的单标量类型，但合同只称其为“保守峰值工作集估计”，没有规定 backend 是否必须包括：

- host 输出 surface；
- codec parser state；
- 系数、分量平面或 tile；
- 色彩转换 scratch；
- prepared state；
- framework/runtime 私有分配；
- 取消后的延迟回收；
- GPU、IOSurface 或共享内存。

因此，不同 backend 可以在类型检查通过的情况下报告不同覆盖域。

### 2.3 合并点

`DecodeStage.conservativeWorkingSetBytes` 同时计算 generic 和 backend estimate，然后取最大值并向 permit pool 申请预算。由于两个 estimate 的覆盖域没有机器可读定义，`max` 可能：

- **低报**：generic 覆盖 host surface，backend 只覆盖 codec-private temporary，二者同时存活；
- **重复语义但偶然安全**：二者都覆盖全部 live set；
- **高报**：二者都含相同输出 surface，而某一方还额外保守；
- **不可解释**：backend 返回经验 RSS 增量，generic 返回静态分配模型，证据等级不一致。

## 3. 必须区分的资源事实

生产合同至少需要区分下列维度，而不是只增加更多无语义数字：

| 维度 | 必须回答的问题 |
|---|---|
| resource class | encoded bytes、decoded surface、codec temporary、host temporary、prepared state、external/framework、GPU/IOSurface 分别是什么？ |
| physical identity | 两个逻辑声明是否指向同一物理 allocation，还是会同时占用？ |
| ownership | host、codec、framework 或共享所有权由谁控制？ |
| lifetime | probe、prepare、decode、transform、publish、cache handoff、cancel/reclaim 的哪些阶段存活？ |
| persistence | 哪些分配在 decode 返回后继续由结果、cache 或 UI 持有？ |
| reclaim | 逻辑不可达后是否立即物理释放，是否存在 allocator/framework 尾部？ |
| evidence class | declared bound、derived bound、measured quantile、observed peak 或 unknown？ |
| composition | sum、max、mutually-exclusive、alias-deduplicate 或 conservative-unknown？ |

## 4. 最小生产合同候选

当前不冻结最终 Swift API。候选模型先作为离线 manifest 和实验输出：

```text
DecodeResourceClaim
  id
  resourceClass
  bytesUpperBound
  physicalGroup
  owner
  startsAt
  endsAfter
  persistence
  reclaimClass
  evidenceClass
```

Fovea 的准入器根据有限规则组合：

- 不同 physical group 且生命周期重叠：求和；
- 相同 physical group：只计一次，但需要 host 可验证的 alias 证明；
- 明确互斥的执行分支：取最大；
- 覆盖域未知或证据不足：fail closed、使用预注册兜底上界，或拒绝 production-qualified 状态；
- empirical quantile 不得提升为 hard cap。

如果真实 ImageIO/AxiomRaster 证据表明这一模型过重，可收缩字段；不得在没有反例研究前直接退回无覆盖语义的单标量。

## 5. 立即生效的临时政策

在该开放义务关闭前：

1. ImageIO 保持唯一默认 reference backend。
2. 新 backend 可以进入编译、conformance、shadow decode 和实验 lane，但不能仅凭当前 `workingSetBytes` 获得 production-qualified/default 状态。
3. 任何“资源上界已证明”声明必须说明覆盖域和证据等级；当前标量只称为 admission estimate。
4. cache、encoded input 和 rendered output 的既有独立预算不得因 backend 标量而被静默吸收或重复解释。
5. `Int.max`、溢出或 unknown coverage 必须保持 fail closed。

该政策不声称当前 ImageIO 路径已经发生 OOM，也不要求立即修改生产 API。它只是阻止把尚未证明的组合规则升级为插件安全保证。

## 6. 实验与证伪计划

### E1：静态生命周期账本

对 ImageIO 和 AxiomRaster JPEG 分别列出：

- host 分配；
- codec/framework 分配；
- 输出 owner；
- prepare/decode/transform 阶段；
- 可能重叠的最大集合。

成功标准：每个主要 allocation 都有 owner、lifetime 和覆盖来源；未知项显式保留。

### E2：真实进程测量

在固定设备和输入族上测量：

- process footprint/RSS；
- malloc zone 或等价 allocation trace；
- peak decoded surfaces；
- cancel 前后逻辑释放与物理回收；
- repeated decode 的 allocator warm-state 差异。

测量值只用于校准和反例发现，不直接作为 hard cap。

### E3：组合规则反例

构造至少三种 backend fixture：

1. backend estimate 只覆盖 codec-private temporary；
2. backend estimate 覆盖完整 live set；
3. backend 与 generic 部分重叠。

验证 `max`、sum 和 alias-aware composition 在这些 fixture 上的低报与高报行为。

### E4：取消与 prepared-state 生命周期

验证：

- prepare 后取消；
- decode 中取消；
- decode 完成但 publish 被 revoke；
- preparation 丢弃；
- cache handoff 后 output 持有。

重点不是只看函数返回，而是看 permit 释放与物理资源尾部是否一致。

### E5：生产合同收敛

只有在 E1–E4 产生真实反例和分布后，才决定：

- 保留单标量但明确定义 complete-live-set；
- 引入 host/backend 两类互不重叠预算；
- 引入有限 component claims；
- 对外部 framework 采用平台特定兜底系数或隔离模式。

## 7. 与其他路线阶段的关系

- **P1/P2 ImageCraft**：外部包迁移可以准备和验证，但第二 backend 准入受本审计门约束。
- **P3/P4 Akashic**：资源合同应避免把 cache 持久值误计为 decode temporary；Akashic 自己仍需独立 memory/disk budget。
- **P6 Conformance**：codec conformance kit 必须包含 resource coverage declaration、overflow、unknown 和 lifecycle obligation。
- **P7 Pareto**：peak memory 比较必须区分持久输出、临时峰值和逻辑释放后的 reclaim tail。
- **P8 Advanced media**：progressive、animation、HDR 和 auxiliary planes 需要新的阶段与生命周期，不能复用静态图单标量假设。

## 8. 关闭条件

`OPEN-DECODE-RESOURCE-CONTRACT-AUDIT` 只有同时满足以下条件才可关闭：

- 至少 ImageIO 与一个结构不同的 held-out backend 完成生命周期账本；
- 存在 retained 组合反例测试，能够杀死错误的 `max`/sum/alias 规则；
- 最小合同和 fallback policy 进入 ADR；
- conformance tests 覆盖低报、重叠、溢出、取消和 prepared-state；
- Fovea admission 使用的规则与文档、manifest 和诊断一致；
- 在真实设备上完成校准，但不把经验分位数冒充硬上界。
