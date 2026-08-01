# 诊断、事件与隐私契约

> **状态：Active Phase 0b 子集 / Core v1 Candidate 扩展。**

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

- Phase 0a 的 `keyDigest` 字段语义是每 Pipeline 随机加盐的短期 correlation digest，不是持久 key digest；事件构造与 Codable 解码只接受 64 位小写 SHA-256 形式，任意 URL、token、自由文本或非规范摘要在进入 sink 前统一删除；
- 同一 Pipeline 内可关联阶段，跨 Pipeline/进程不可稳定关联；
- `RequestTraceID`、`SharedTaskID` 使用随机、进程或 trace 局部 ID；
- 不使用 ContentID、FetchVariantKey/FetchExecutionKey 原始 digest、URL hash、账户 ID 或 PhysicalBlobID 作为 trace ID；
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

- 所有动态 log/signpost payload 强制使用 private privacy；不得因为字段已做 schema 清洗就降级为 public；
- signpost name/category 使用静态低基数字符串；
- 不把 URL、key 或错误自由文本作为 signpost name；
- signpost interval 必须成对完成，取消/错误也输出终止事件；
- production 日志级别与采样由 `OSLogDiagnosticsConfiguration` 决定，不影响请求 key、调度、重试或缓存；
- Unified Logging 可写入内存和磁盘，因此仍按持久化敏感数据处理。

## 5. Sink 与背压

`PipelineObserver`/diagnostics sink 只能观察：

- 不在 actor/锁内调用；
- 不得阻塞网络、解码、UI 或 Commit；
- 内置 ring buffer 容量最大 65,536；sequence 达到 `UInt64.max` 时只对当前有界可见 ring 重新编号，不回绕；外部 sink 自动经过单消费者 `bufferingOldest` relay；
- 队列满时丢弃新事件，累计 dropped count，并在容量恢复后输出聚合 `diagnosticsDropped`；
- sink 崩溃、超时或写失败不能改变图片请求结果；
- 用户提供的 sink 明确 `@Sendable` 和执行器，不允许回调进入 pipeline 修改状态。


## 6. Phase 0a 已实现子集

- `DiagnosticEvent.schemaVersion = 7`；当前 reader 对未知 schema 失败关闭，schema 迁移必须显式设计；
- fetch/decode 的 queued、started、completed/failed/cancelled 事件可区分 permit 等待与实际工作，并为 signpost 提供相关终止事件；
- decode working-set reservation 与 admission rejection 记录脱敏字节估算和有限 reason code；
- 官方 URLSession transport 汇总 task duration、transaction count、协商协议、连接复用、系统代理、cellular/expensive/constrained 标记；不输出 URL、IP、header 或原始 metrics 对象；`TransportNetworkMetrics` 的直接构造与 Codable 解码共享硬上限：计数最多 4,096，时长最多 24 小时，解码协议候选最多 64 个且最终最多保留 8 个合法唯一值；
- `PipelineFailure` 的 category/stage/disposition/reasonCode 进入结构化失败事件；
- cache read/write degradation、missing Content-Type、namespace revoke 与 diagnostics drop 均有有限 reason code；`reason` 仅接受 1–96 字节的小写 ASCII 字母、数字和连字符，其他输入统一收敛为 `invalid-reason-code`；
- 任意外部 sink 被有界 relay 隔离，阻塞或缓慢消费不延迟图片 final；
- 每 Pipeline 随机盐重写所有稳定 key digest，原始 URL、token、ContentID、namespace 与持久 digest 不离开 pipeline；`DiagnosticEvent` 对 byte/item/pixel/dimension/attempt/network count/duration 使用领域上限，构造与反序列化不能制造极值遥测或无界协议数组。

`FoveaObservability` 已提供 OSLog/OSSignpost 生产出口和 correlation-stable 采样；跨进程 trace backend、retention 与上传仍属于宿主或后续阶段。


### 6.1 官方 OSLog 适配器

`FoveaObservability` 独立依赖 `FoveaCore`，Core 不直接导入 OSLog。适配器遵循：

- subsystem/category 必须是 1–128 / 1–64 字节的静态 ASCII 标识符，拒绝 path、空格和动态主体值；
- event message 只由显式白名单字段组装，correlation digest 只输出 16 位短期前缀；短期前缀、尺寸、状态码、网络属性与时序组合仍视为行为指纹并保持 private；
- negotiated protocol 再次做长度和字符集收敛，未知值归并为 `other`；
- fetch/decode 使用静态 `FoveaFetch` / `FoveaDecode` interval；没有对应 begin 的 terminal 只发 event，绝不制造孤立 end；
- `.oneIn(n)` 对同一 correlation 的普通事件做一致决定，关键失败与取消绕过采样；
- signpost 和 OSLog 仅观察，不上传、不持有业务 retention 策略。

## 7. 采样与导出

生产模式：

- 默认采样成功请求；
- 安全错误、crash-adjacent、schema corruption 可提高采样，但仍脱敏；
- 不跨 namespace 关联同一内容；
- retention 由 App 决定，Fovea 不隐式上传。

Benchmark/Test 模式：

- 可记录完整结构化事件和确定性时钟；
- 仍不记录原始凭证与图片内容；
- raw trace 附 build SHA、配置、数据集版本和 schemaVersion。

## 8. 稳定 reason codes

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

## 9. Property tests

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
- **DIAG-PT-011**: 官方 transport 通过真实 URLSession delegate 路径产生脱敏事务摘要，摘要不改变请求结果或身份。
- **DIAG-PT-013**: `DiagnosticEvent` 直接构造和 Codable 解码共享同一清洗边界；只接受当前 schema，`keyDigest` 只接受规范 SHA-256，非法 HTTP 状态、负数、超大正数、零像素、自由文本 reason、异常协议名与超过 64 项的协议候选不得进入 sink。数量使用 `itemCount`，字节使用 `byteCount`，不得混用。

## 长期运行序列收敛

诊断 ring、permit waiter 和 OSLog 活动 interval 都不得使用可观察的无符号回绕。达到 `UInt64.max` 时只对当前有界可观察集合重新编号，并保持原始年龄顺序；OSLog fetch/decode interval 共用一个全局序列，容量淘汰不会因回绕误关刚开始的区间。
