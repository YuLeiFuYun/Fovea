# 调度、共享任务与取消语义

> **状态：Proposed，Phase 0a 子集 / Phase 0b 完整可执行规范。**

## 1. 目标

确保同一资源被可见 UI、后台预取和多个视图同时订阅时，任务共享不会产生优先级反转、错误取消、跨安全域合并或无人订阅后的资源浪费。

## 2. 任务键

### 2.1 FetchVariantKey

稳定请求/缓存变体，用于选择 RepresentationRecord。它不包含原始临时凭证。

### 2.2 FetchExecutionKey

只存在于当前进程的任务注册表：

```text
FetchVariantKey
+ exact resolved locator fingerprint
+ credential generation fingerprint
+ request cache/revalidation mode
+ range/validator execution state
+ transport-affecting policy fingerprint
```

网络 single-flight 只能在 FetchExecutionKey 相同且兼容性检查通过时发生。

### 2.3 下游共享键

```text
ContentID  → probe / byte-level reuse
DecodeKey  → target decode
RenderKey  → final transform
```

Phase 0a 仅实现 FetchExecutionKey single-flight。相同 ContentID/DecodeKey 的并发请求可能重复 probe/decode；该限制有意保留到 0b 调度器，不得在 benchmark 或文档中宣称 Decode/Render stage sharing 已完成。

## 3. Subscriber

每个订阅者至少携带：

```text
SubscriberID
priority
visibility class
request token
network constraints
cache intent
preview interest
security namespace
cancellation state
```

UI token 保护展示生命周期；SubscriberID 保护 pipeline 引用计数。两者不能混用。

## 4. 有效优先级

```text
effectivePriority = max(activeSubscriber.priority)
```

规则：

- join、leave、cancel、priority change 后立即重算；
- 新可见请求加入时提升共享任务；
- 可见请求退出、只剩 prefetch 时降级；
- 本地 Network/Decode/Process 队列必须重排或在下一调度点采用新值；
- `TaskPriority` 和 `URLSessionTask.priority` 仅为 best-effort 映射，不作为正确性依据；
- 已经运行且底层无法降级的任务仍记录“requested vs applied priority”差异。

同级任务必须避免永久饥饿；通过 age、cost class 和 pipeline/namespace fairness 作为次级排序，但不改变公开优先级语义。permit、pressure 和公平性细节见 `resource-budgeting.md`。

## 5. 合并兼容性

即使 FetchExecutionKey 相同，以下条件不兼容时也不得合并：

- security namespace 或 AuthorizationContextID 不同；
- 一个请求禁止 constrained/cellular network，而另一个已在该网络执行；
- range/revalidation 模式不同且无法安全统一；
- transport adapter、TLS/client identity 或 cookie partition 不同；
- 响应语义可能因调用者未编码进 variant 的字段不同。

Cache lookup 已在上游完成；`.reload`、`.onlyIfCached` 等行为不得在错误阶段混合。

## 6. 取消

### 6.1 Subscriber 取消

取消只移除该订阅者：

- 该 token 后续事件不得交付；
- 其他订阅者继续；
- 移除后重算有效优先级和 commit eligibility。

### 6.2 最后订阅者离开

默认取消上游。只有满足架构文档中的公开、可缓存、encoded-only、近完成条件，才能进入受控后台完成。

认证/private/no-store、已撤销 namespace、增强/解码/处理任务一律不因近完成继续。

### 6.3 取消幂等

重复 cancel、任务完成后 cancel、多个并发 cancel 均不得：

- double resume continuation；
- 重复删除 staging；
- 负引用计数；
- 覆盖已完成结果；
- 导致其他订阅者丢失结果。

## 7. Commit eligibility

网络共享不意味着所有订阅者有相同持久化意愿。Commit 阶段重新计算：

```text
response permits persistence
AND namespace generation active
AND security policy permits
AND at least one eligible subscriber or approved encoded-only completion
```

`no-store` 和 namespace revocation 拥有全局否决权。某个订阅者选择 memory-only 不得阻止同一安全域中另一个明确允许持久化的订阅者，但不能扩大 source response 的权限。


### 取消静默墓碑

Fetch single-flight 的最后订阅者取消时，底层任务必须立即取消；但 registry 不能立即删除同键 entry。否则同批尚未执行到 `subscribe` 的迟到调用会在旧任务终止期间创建第二个 transport，形成取消路径 ABA。

Fovea 使用与 orphan handoff 不同的 `cancellation tombstone`，并显式区分顶层调用的 admission cohort：

- 每个顶层加载调用在进入管线时记录单调 admission 时间；
- 最后一个已登记订阅者取消时，底层 task 立即取消，独立 tombstone 保存取消终态和 cutoff；
- cutoff 之后才创建的真正新调用不注册为活跃 subscriber，只观察已取消 Task 的终态，不能复活底层工作；
- cutoff 之前已经开始、但因缓存查询或 actor 调度而更晚到达 registry 的调用可以进入唯一 replacement cohort；
- replacement cohort 完成后，其结果保留到 tombstone 到期，使同批更晚到达者复用同一结果而不会再次启动；
- task completion 不得提前删除 tombstone；tombstone 不参与 priority 更新；250ms 租约到期后才恢复普通新任务创建。
- tombstone 保存绝对单调过期时刻；`subscribe` 在 admission 线性化点惰性清理已过期墓碑，后台 sleep 任务只负责主动回收，调度延迟不得延长语义租约。

这与 credential refresh 的 orphan handoff 不同：后者在有界窗口内允许原任务继续，以复用昂贵刷新；取消墓碑始终终止原任务，只为取消前已存在的调用保留一次有界 replacement 机会。

## 8. Namespace revocation fence

每个任务捕获 `NamespaceGeneration`。登出/清理时：

1. 原子标记旧 generation revoked；
2. 取消相关 subscriber/task；
3. UI 立即清除该 namespace 的私有结果；
4. Commit 前再次校验 generation；
5. 旧任务即使稍后完成，也不得写入 memory/disk/analysis；
6. 物理文件可异步清理，但逻辑可达性必须立即为零。

## 9. Retry

v1 只对幂等 GET 的明确瞬态 transport error 做有限重试；统一 disposition、回退顺序和公开错误见 `error-recovery.md`：

- 共享任务拥有统一 retry budget；新订阅者加入不重置预算；
- cancellation 不触发 retry；
- 401/403 默认不重试，授权适配器最多执行一次显式 refresh cycle；
- 429/503 只有策略允许且 `Retry-After`/预算可接受时重试；
- retry 不能跨 FetchExecutionKey 的凭证/locator generation 静默继续。

## 10. Property tests

- **SCHED-PT-001**: visible + prefetch 合并，visible 取消后 effective priority 降级；
- **SCHED-PT-002**: prefetch 运行中 visible 加入，priority 提升；
- **SCHED-PT-003**: 多订阅者随机 join/leave 后 effective priority 始终等于最大值；
- **SCHED-PT-004**: 最后订阅者离开只取消一次；
- **SCHED-PT-005**: 旧 token 不收事件，其他 token 不受影响；
- **SCHED-PT-006**: token 刷新缓存可复用，但旧/新凭证 fetch 不错误合并；
- **SCHED-PT-007**: namespace revoke 与 Commit 竞态下持久化始终为零；
- **SCHED-PT-008**: retry budget 不被新 subscriber 重置；
- **SCHED-PT-009**: 不兼容 network/cache/range mode 不合并；
- **SCHED-PT-010**: 任务完成、取消和错误的任意竞态不 double-complete；
- **SCHED-PT-011**: permit 等待中取消不泄漏资源；
- **SCHED-PT-012**: 同级任务和不同 pipeline/namespace 不永久饥饿；
- **SCHED-PT-013**: 某 subscriber 取消后立即结束自身等待，不等待共享底层任务完成；其他 subscriber 和底层任务不受影响；
- **SCHED-PT-014**: 固定种子生成的多订阅者退出序列中，subscriber count、effective priority、底层 operation 次数与最终 cancellation 次数始终满足不变量，并可由 seed 重放；
- **SCHED-PT-015**: 底层共享任务完成后，registry entry 必须先按 taskID 清理，再向订阅者发布结果；后续订阅不得加入已完成任务；
- **SCHED-PT-016**: 允许 late handoff 的共享任务必须绑定有界 lease；lease token 失效、任务完成、新订阅加入或租约到期的任意竞态都不能误取消活跃任务，也不能留下永久零订阅者条目。
- **SCHED-PT-017**: 相同 namespace generation 与 RenderKey 的并发请求必须共享 transform task；namespace revoke 必须取消对应 transform，不得发布迟到 RenderedMemory。
- **SCHED-PT-021**: 最后订阅者取消后，底层任务立即取消且进入有界 cancellation tombstone；窗口内迟到订阅不得启动第二个 operation，completion 不得提前删除墓碑，租约到期后新请求才可创建任务。
- **SCHED-PT-022**: cancellation tombstone 以顶层 admission cutoff 区分取消前已开始的调用与取消后新调用；前者只允许形成一个 replacement cohort 并复用其终态，后者仍不得复活已取消任务。
