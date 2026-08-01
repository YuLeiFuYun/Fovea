# ADR-0004：FetchExecutionKey 与共享任务优先级

- **状态：Accepted**
- **接受日期：2026-07-20**
- **日期：2026-07-18**

- **接受依据：** 执行键、订阅者优先级重算、取消与合并兼容性均已有生产实现和回归测试。

## 背景

稳定缓存身份与某一次精确网络执行不是同一个概念。签名 URL、轮换 token、Cookie generation、Range 恢复和 revalidation mode 可能不应改变缓存选择语义，却会影响两个在途请求是否可以安全合并。

同时，多个订阅者共享任务时，优先级会随可见请求加入或退出而变化。若只在任务创建时设置一次优先级，列表滚动会形成持续的优先级反转。

## 决策

### 1. 五层持久身份保持不变，增加非持久执行键

`FetchVariantKey` 继续表示稳定的请求/缓存变体。新增只存在于当前进程和任务注册表中的：

```text
FetchExecutionKey
= FetchVariantKey
+ exact resolved locator fingerprint
+ credential generation fingerprint
+ request cache/revalidation mode
+ range/validator execution state
+ transport-affecting policy fingerprint
```

原始 token、Cookie、签名 query 不写日志或持久化；只在内存中生成不可逆 fingerprint。

- `FetchVariantKey`：用于 RepresentationRecord 候选选择。
- `FetchExecutionKey`：用于网络 single-flight。
- `ContentID`：用于完整字节去重。

签名 URL 刷新可以继续命中稳定 record，但过期 URL 的在途请求不会吞并使用新签名的请求。

### 2. 共享任务有效优先级

```text
effectivePriority = max(activeSubscriber.priority)
```

订阅者 join、leave、cancel 或 priority change 时立即重算：

- 高优先级可见订阅加入时提升；
- 可见订阅退出、仅剩 prefetch 时降级；
- 没有订阅者时进入取消/近完成策略；
- 本地 scheduler 必须重排，Swift `TaskPriority` 和 `URLSessionTask.priority` 只作 best-effort 映射。

### 3. 合并兼容性

只有执行语义兼容的订阅者才能共享 Fetch：

- 相同 security namespace 与 authorization context；
- 相同 FetchExecutionKey；
- 网络约束和 transport 行为兼容；
- 不将 `reload`、Range resume 和普通 revalidation 错误合并。

持久化意愿可以在 fetch 后按订阅者和响应策略重新计算，但 `no-store`、namespace revocation 和安全策略拥有否决权。

## 后果

任务注册表多维护一个内存键和订阅者优先级集合，但避免稳定缓存键被临时凭证污染，也避免可见请求取消后预取任务永久保持高优先级。

## 验证门禁

- visible + prefetch 合并后，visible 离开会降到 prefetch；
- 新 visible 加入会提升；
- 最后订阅者离开遵循取消策略；
- 轮换 token 可继续命中缓存，但不与旧凭证在途 fetch 错误合并；
- 不兼容 cache/range mode 不合并；
- 优先级变化不改变 key、缓存身份或结果像素。
