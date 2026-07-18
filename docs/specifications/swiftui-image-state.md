# SwiftUI 图片状态机规范

> **状态：Proposed，Core v1 Candidate 规格。**

## 1. 目标

确保 body 重算、identity 变化、view 消失、缓存同步命中和迟到异步结果不会造成重复订阅、闪烁或旧图覆盖新图。

## 2. 状态

```text
idle
loading(placeholderVisible, requestToken)
preview(image, requestToken)
final(image, source, requestToken)
failed(error, requestToken)
cancelled(previousToken)
```

`source` 至少区分：

```text
renderedMemory
originalOrDerivedCache
networkOrSource
progressive
```

## 3. 事件与转移

```text
idle --start(identity)--> loading
loading --preview(token)--> preview
loading/preview --final(token)--> final
loading/preview --failure(token)--> failed
loading/preview --identityChanged--> cancelled -> loading(new token)
loading/preview --viewDisappeared--> cancelled
failed --retry(same identity)--> loading(new token)
final --identityChanged--> cancelled -> loading(new token)
```

## 4. Request token 铁律

- 每次开始或重试生成单调递增/唯一 token；
- 只有事件 token 与当前 token 完全相同时才能改变 UI；
- 旧 token 的 preview/final/failure 全部丢弃；
- 丢弃迟到结果不等于一定取消共享上游任务，由订阅引用计数决定；
- token 不进入缓存 key，它只保护 UI 生命周期。

## 5. Identity

SwiftUI task identity 由规范化的：

```text
logical source identity
+ target pixels
+ content mode / transform intent
+ request-visible policies that affect result
```

组成。placeholder 样式、transition 时长和纯展示配置不应触发新的图片请求。

## 6. Placeholder 与 redaction

- `loading` 可以显示 placeholder 或 redacted content；
- memory cache 同步/近同步命中时默认不先闪现 placeholder；
- identity 改变时是否保留旧图直到新 preview 到达由显式 `retentionPolicy` 控制；默认清除私有/跨账户旧图；
- `no-store` final 可以继续由当前 view token 显示，但不能被新的 request/view 查询为缓存命中；
- failure placeholder 不得被旧 token 的 final 覆盖。

## 7. Transition

默认规则：

| 来源 | 默认 transition |
|---|---|
| RenderedMemory | 无动画 |
| 磁盘缓存 | 无动画或极短、由调用者开启 |
| progressive preview → final | 可使用轻量 crossfade |
| network/source 首次 final | 标准 crossfade |
| identity 跨账户变化 | 不保留旧图，不 crossfade 私有旧内容 |

Reduce Motion 开启时禁用非必要 transition。

## 8. Preview

- preview 可以多次到达，但只保留最新、质量单调不下降的结果；
- completeness/fidelity 相同或更差的 preview 可丢弃；
- final 到达后拒绝所有 preview；
- preview 不能被当成最终成功用于长期状态恢复。

## 9. View 生命周期

- `onDisappear` 默认取消当前 UI 订阅；
- 列表预取由独立 prefetch token 管理，不与 view token 混用；
- body 重算但 identity 未变化时不得创建新订阅；
- layout 为 0/unknown 时不启动原尺寸 decode；可保持 idle/loading placeholder 或仅预取 encoded；
- 连续 geometry 变化遵循 target geometry debounce/hysteresis，不每帧创建新订阅；
- scene/background 策略由 pipeline 决定，view 不自行保持隐藏任务。

错误到 UI action 的统一默认规则见 `error-recovery.md`。

## 10. 测试矩阵

- **UI-PT-001**: 连续切换 A→B→C，A/B final 迟到不能覆盖 C；
- **UI-PT-002**: memory hit 不出现 placeholder 闪烁；
- **UI-PT-003**: preview 后 identity 改变，旧 final 被丢弃；
- **UI-PT-004**: view disappear 后无 UI 更新；
- **UI-PT-005**: body 重算 100 次只产生一个订阅；
- **UI-PT-006**: retry 使用新 token；
- **UI-PT-007**: Reduce Motion 禁止 transition；
- **UI-PT-008**: 账户切换默认立即清除旧私有图；
- **UI-PT-009**: cache hit 与 network final 的状态序列可预测；
- **UI-PT-010**: cancellation 与共享上游引用计数互不破坏；
- **UI-PT-011**: 0×0 初始布局不触发 decode，稳定尺寸后只启动一次；
- **UI-PT-012**: 连续 resize 不产生无界 request token/RenderKey。
- **UI-PT-013**: no-store final 仅当前 view token 可继续显示，新 request 不命中；
- **UI-PT-014**: namespaceRevoked/securityLimit 使用统一错误恢复矩阵；
- **UI-PT-015**: 每个成功图像必须显式选择 decorative 或提供 accessibility label，不存在静默 decorative 默认值。
