# 资源预算、准入与压力响应规范

> **状态：Proposed，Core v1 Candidate 规格。**

## 1. 目标

Network、DiskIO、Decode 和 Process 不是四个独立的并发整数，而是一组受平台压力、任务优先级和估算成本约束的有界许可。实现不得通过创建大量等待中的 Swift Task 绕过预算。


## 2. Phase 0a 已实现子集

Phase 0a 只承诺两个静态、可取消的 hard cap：

```text
maximumConcurrentFetches = 6（默认，可配置）
maximumConcurrentDecodes = 2（默认，可配置）
maximumQueuedFetches / maximumQueuedDecodes = 512（默认，可配置）
```

- permit 只包围唯一网络 fetch 或一次 probe/decode；
- FetchExecutionKey single-flight 在 permit 内执行，重复订阅不重复占用网络 permit；
- 等待 permit 的请求可立即取消，取消后不得实际启动网络/解码，也不得泄漏 permit；
- fetch/decode 等待队列默认各 512，超限返回结构化 `resourceLimit`，不启动对应阶段；
- 队列不为等待者创建轮询任务；
- 同步 probe/decode 在受 permit 约束的专用 Dispatch executor 上运行，不阻塞 Swift cooperative executor；
- 0a 不承诺 subscriber priority、namespace fairness、pressure 自适应或 decoded-byte reservation。

后续章节描述 Core v1/0b 完整模型；不得把它们误读为当前已实现能力。

## 3. 完整 Permit 模型

每个昂贵阶段在开始前获取 permit：

```text
NetworkPermit
DiskPermit
DecodePermit(estimatedPixels, estimatedBytes)
ProcessPermit(estimatedWorkingSet)
```

- permit 只覆盖明确阶段，不跨未知用户回调；
- 等待 permit 的任务保留 Subscriber 取消能力；
- permit 释放必须幂等；
- 无法可靠估算时使用保守上界；
- 实测成本反馈给后续调度，但不在一次请求中无界追加资源。

## 4. 排队与公平

队列排序使用：

```text
effective subscriber priority
+ visibility class
+ age / starvation protection
+ estimated cost class
```

规则：

- 可见交互任务优先于 prefetch；
- 同级任务通过 age 避免永久饥饿；
- 大任务不能永久阻塞大量小任务，也不能因成本大而永远无法运行；
- namespace 和 pipeline 具有公平权重，单一调用者不能占满所有 permit；
- prefetch 使用独立较低上限，不借满交互保留容量。

## 5. 内存准入

开始 decode/process 前至少检查：

```text
estimated decoded bytes
intermediate buffer estimate
current reserved bytes
RenderedMemory usage
platform pressure state
single-entry hard cap
```

- 预算按像素格式、帧窗口和中间缓冲估计，不只看 encoded bytes；
- 估算明显超出 hard cap 时在分配前拒绝或选择更小 target；
- 实际分配超过估算时更新 reservation，并在无法扩容时有序失败，不能继续透支；
- memory cache cost 与临时 working set 分开核算。

## 6. 压力状态

```text
normal
constrained
critical
```

建议行为：

| 状态 | 行为 |
|---|---|
| normal | 使用平台 profile 默认预算 |
| constrained | 停止新 prefetch/Derived/Analysis，降低 decode/process 并发，收缩 memory cache |
| critical | 取消未开始的低优先级任务，清理可重建内存，禁止增强和动画预解码，只保留交互最小闭环 |

压力恢复采用 hysteresis，避免频繁扩缩振荡。

## 7. 网络限制

`interactive`、`balanced`、`prefetch` 映射到明确网络约束：

- prefetch 默认不使用 constrained 或 expensive network；
- interactive 可由调用者允许 constrained/expensive；
- `waitsForConnectivity`、Low Data Mode 和 expensive access 是调度输入，不是无限等待许可；
- subscriber policy 不兼容时不得错误合并同一 FetchExecutionKey；
- 网络环境变化后，等待任务重新评估，不静默扩大权限。

## 8. 后台与生命周期

- v1 不默认使用 background URLSession 延续普通图片请求；
- App 进入后台后，可见订阅按 UI 生命周期取消，prefetch/Derived/Analysis 默认暂停或取消；
- 已批准 encoded-only 近完成任务仍受后台执行时间和 namespace generation 限制；
- App Extension 使用独立更保守 profile，不依赖 UIApplication 生命周期。

## 9. 可观测性

至少记录：

```text
permit wait duration
requested/applied priority
estimated/actual pixels and bytes
pressure state transition
admission rejection reason
prefetch cancelled by policy
network constrained/expensive decision
```

不得记录原始资源身份。

## 10. Property tests

- **RES-PT-001**: 并发任务数和 reserved bytes 永不超过 hard limit；
- **RES-PT-002**: 取消等待 permit 的任务不会泄漏 permit；
- **RES-PT-003**: visible 请求可越过 prefetch 但同级任务不永久饥饿；
- **RES-PT-004**: critical pressure 停止 prefetch/Derived/Analysis；
- **RES-PT-005**: 压力恢复不会瞬间释放无界并发；
- **RES-PT-006**: 大图在分配前被 hard cap 拒绝或降级；
- **RES-PT-007**: constrained network 下 prefetch 不发起请求；
- **RES-PT-008**: 交互任务的显式网络权限不被低权限 subscriber 扩大或缩小；
- **RES-PT-009**: background transition 不留下无主 decode/process；
- **RES-PT-010**: permit/priority 事件可由 deterministic scheduler 重放；
- **RES-PT-011**: 官方系统组合层在 warning/critical memory pressure 下清空 RenderedMemory；清理幂等，不删除 OriginalEncoded、不触发重复网络请求，也不改变在途任务身份。
