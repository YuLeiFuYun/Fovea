# 资源预算、准入与压力响应规范

> **状态：Proposed，Core v1 Candidate 规格。**

## 1. 目标

Network、DiskIO、Decode 和 Process 不是四个独立的并发整数，而是一组受平台压力、任务优先级和估算成本约束的有界许可。实现不得通过创建大量等待中的 Swift Task 绕过预算。


## 2. 当前已实现子集

当前实现具有三类静态、可取消的 hard cap：

```text
maximumConcurrentFetches = 6（默认，可配置）
maximumConcurrentDecodes = 2（默认，可配置）
maximumDecodeWorkingSetBytes = 192 MiB（默认，可配置）
maximumQueuedFetches / maximumQueuedDecodes = 512（默认，可配置）
```

- FetchExecutionKey/DecodeKey single-flight 在 permit 内执行，重复订阅不重复占用阶段 permit；
- 等待 permit 的请求可立即取消，取消后不得启动对应阶段或泄漏 permit；
- fetch/decode 数量队列具有动态 subscriber 优先级与有界防饥饿；
- probe 完成后、像素分配前，按缩略表面、颜色转换表面和最终/crop 表面保守估算 working set；
- 带权许可只向当前可容纳的 waiter 发放，单任务超过 hard cap 时结构化拒绝；
- memory cache cost、encoded body、decode working set 分开核算；
- 官方系统组合层在 warning/critical memory pressure 下清空 RenderedMemory；
- 请求级 cellular/constrained/expensive 权限进入 exact execution identity，不进入持久缓存身份；
- 官方 URLSession policy 明确 `waitsForConnectivity`、请求/资源超时和每主机连接上限；
- 同步 probe/decode 在专用 Dispatch executor 上运行，不阻塞 Swift cooperative executor；
- 自定义 transport 返回后由 `FetchStage` 重新验证实际 body hard cap，自定义 transformer 返回后重新验证 dimension、pixel count 与 working-set cap；
- 程序化配置与 Codable 配置共享宽松但有限的控制面上界，损坏配置不能把 `Int.max` 传入队列、URLSession、重试或解码分配。

当前控制面绝对上界不是推荐设备预算，而是损坏/敌意配置的最后防线：

```text
transport body                    1 GiB
memory cache                      4 GiB
fetch concurrency                 256
decode concurrency                64
decode working set                8 GiB
fetch/decode queue                1,000,000 each
URLSession request timeout        1 hour
URLSession resource timeout       24 hours
connections per host              64
retry attempts                    8
retry total delay                 15 minutes
stale fallback                    365 days
decode/geometry maximum dimension 65,536
pixel count                       1,000,000,000
```

仍未实现：按 CPU 时间的硬配额、thermal/pressure 驱动的动态并发、namespace 加权公平、独立 prefetch 配额、后台 URLSession 延续、跨进程全局资源预算与实际分配动态扩容。后续章节描述完整目标模型，不得误读为当前已交付能力。

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
- `AsyncPermitPool.Permit` 是不可复制的消耗型所有权令牌；`withPermit`/`release` 消耗令牌，编译器阻止复制后并发使用或二次释放，pool 内部仍对迟到/重复标识执行防御性忽略；
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
- **RES-PT-011**: 官方系统组合层在 warning/critical memory pressure 下清空 RenderedMemory；清理幂等，不删除 OriginalEncoded、不触发重复网络请求，也不改变在途任务身份；
- **RES-PT-012**: 官方 URLSession policy 的连接等待、超时和每主机连接上限进入 transport context；自定义 configuration 不被默认策略静默覆盖；
- **RES-PT-013**: 带权 decode working-set reservation 永不超过 hard cap，fill overscan 进入估算，超大任务在像素分配前失败；
- **RES-PT-014**: probe 完成后立即释放 decode-count permit；等待 working-set 的大任务不得阻塞仍可容纳的小任务；
- **RES-PT-015**: 默认代理策略明确遵循系统设置；严格模式要求 URLSession task metrics 可用且所有 transaction 均未使用代理，否则失败关闭。该检查不冒充连接前直连隔离；
- **RES-PT-016**: logical source、namespace、authorization context 与 geometry fingerprint 在进入 identity、actor dictionary 或持久键之前具有非空与 UTF-8 字节上限，并拒绝 Unicode 控制字符；
- **RES-PT-017**: 精确 origin allowlist 有最大 256 项，规范化 scheme/host/default port，拒绝远程明文 HTTP，并同时约束初始请求与 redirect；策略摘要进入 transport execution identity。

- **RES-PT-018**: namespace registry 具有显式 hard capacity；超限的新 namespace 在缓存/网络前失败关闭，已跟踪的撤销 generation 保持稳定且不得被逐出。

- **RES-PT-019**: 系统 memory-pressure monitor 由长生命周期 pipeline 持有，而不是由瞬态组合 wrapper 持有；清理证据原子区分移除条目数与释放的缓存成本字节数。

## 可插拔边界的二次准入

hard cap 由消费方负责复核，不能只传给插件：custom transport 返回后检查实际 body；custom record store 每个 base key 最多 256 个候选；custom decoder probe 在 working-set reservation 前按 DecodeLimits 复核；transform 输出在交付和 RenderedMemory admission 前按像素与 working-set 复核；GC live references 最多 100,000 个。
