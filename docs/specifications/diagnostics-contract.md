# 诊断、事件与隐私契约

> **状态：Proposed，Phase 0a 子集 / Core v1 Candidate 规格。**

## 1. 目标

诊断必须足以重建请求决策和性能路径，但不能成为秘密、内容指纹或跨账户行为的旁路。日志、signpost、测试 trace 和导出报告共享同一结构化事件模型。

## 2. 事件信封

```text
DiagnosticEvent
├── schemaVersion
├── eventKind / reasonCode
├── timestamp / duration
├── RequestTraceID
├── SharedTaskID（可选）
├── stage
├── sanitized dimensions
├── namespace class（脱敏）
└── build/config fingerprint（非秘密）
```

- `RequestTraceID`、`SharedTaskID` 使用随机、进程或 trace 局部 ID；
- 不使用 ContentID、URL hash、账户 ID 或 PhysicalBlobID 作为 trace ID；
- 事件 schema 独立版本化，未知字段可忽略，未知高版本不得被旧导出器错误解释。

## 3. 数据分类

默认允许：

```text
阶段与 reason code
字节/像素/时长的数值或桶化值
缓存类别与命中结果
HTTP profile outcome
requested/applied priority
匿名化平台/OS/build 信息
```

默认禁止：

```text
raw URL、path、query
Authorization、Cookie、签名
ContentID / AnalysisKey / PhysicalBlobID
原始 namespace/user/tenant ID
图片内容、模型输入或特征向量
完整 response headers
```

需要定位某个业务资源时，由 App 在自己的受控诊断层提供短期、不可逆且不跨会话稳定的标签，Fovea 不生成长期内容指纹。

## 4. OSLog 与 signpost

- 动态值默认使用 private privacy；
- signpost name/category 使用静态低基数字符串；
- 不把 URL、key 或错误自由文本作为 signpost name；
- signpost interval 必须成对完成，取消/错误也输出终止事件；
- production 日志级别与采样由配置决定，不影响请求 key；
- Unified Logging 可写入内存和磁盘，因此仍按持久化敏感数据处理。

## 5. Sink 与背压

`PipelineObserver`/diagnostics sink 只能观察：

- 不在 actor/锁内调用；
- 不得阻塞网络、解码、UI 或 Commit；
- 使用有界队列；队列满时按优先级丢弃低价值事件，并输出聚合 `diagnosticEventsDropped`；
- sink 崩溃、超时或写失败不能改变图片请求结果；
- 用户提供的 sink 明确 `@Sendable` 和执行器，不允许回调进入 pipeline 修改状态。

## 6. 采样与导出

生产模式：

- 默认采样成功请求；
- 安全错误、crash-adjacent、schema corruption 可提高采样，但仍脱敏；
- 不跨 namespace 关联同一内容；
- retention 由 App 决定，Fovea 不隐式上传。

Benchmark/Test 模式：

- 可记录完整结构化事件和确定性时钟；
- 仍不记录原始凭证与图片内容；
- raw trace 附 build SHA、配置、数据集版本和 schemaVersion。

## 7. 稳定 reason codes

reason code 是程序可断言的有限枚举，例如：

```text
freshHit
staleRevalidate
networkJoined
priorityEscalated
priorityDowngraded
notStoredNoStore
cacheWriteDegraded
namespaceRevoked
schemaMiss
securityRejected
previewDroppedBackpressure
```

已发布 reason code 不改变含义；废弃时保留兼容映射。自由文本只用于人类说明，不能作为测试或遥测聚合键。

## 8. Property tests

- **DIAG-PT-001**: 任何事件不含 token/Cookie/raw URL/ContentID；
- **DIAG-PT-002**: 相同内容跨 namespace 不产生可关联稳定 ID；
- **DIAG-PT-003**: sink 阻塞或抛错不影响 final；
- **DIAG-PT-004**: 队列满时有界丢弃且 pipeline 不积压；
- **DIAG-PT-005**: interval 在 success/failure/cancel 下均闭合；
- **DIAG-PT-006**: 未知新事件字段不会使旧 reader crash；
- **DIAG-PT-007**: reason code 含义在 schema 版本内稳定；
- **DIAG-PT-008**: benchmark trace 可重建阶段顺序和关键指标；
- **DIAG-PT-009**: production 采样配置不改变请求身份或调度结果；
- **DIAG-PT-010**: diagnostics retention/upload 不由 Fovea 隐式执行。