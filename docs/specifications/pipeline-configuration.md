# Pipeline 配置、注册与依赖注入规范

> **状态：Active Phase 0b 实现子集 / Core v1 Candidate 规格。**

## 1. 目标

Fovea 允许提供 `Fovea.shared` 作为便捷入口，但不得依赖可在运行时任意变化的全局注册表。网络、缓存、codec、processor、时钟和安全策略必须由可审计的 pipeline 配置显式构造。

## 2. 不可变配置快照

```text
PipelineConfiguration
├── source loaders
├── transport / HTTP profile
├── memory and disk stores
├── codec registry
├── processor registry
├── security policy
├── resource budgets
├── diagnostics sink
├── clocks
└── feature capabilities
```

规则：

- pipeline 初始化完成后，配置快照不可变；
- 修改配置必须创建新的 pipeline 或新的 configuration generation；
- 进行中的请求继续使用其启动时捕获的配置快照；
- 新配置不能悄悄改变旧任务的 key、decoder 或安全语义；
- 配置中影响字节或像素的部分必须通过对应 fingerprint 进入 key；
- 纯诊断采样率等不影响结果的配置不得污染缓存身份。

## 3. Phase 0a 已实现配置

当前公开 `PipelineConfiguration` 只包含已生效且可测试的静态值：

```text
memoryCostLimit
DecodeLimits
TransportRetryPolicy
StaleFallbackPolicy
maximumTransportBytes
transportMemoryThreshold
maximumConcurrentFetches / maximumQueuedFetches
maximumConcurrentDecodes / maximumQueuedDecodes
maximumDecodeWorkingSetBytes
```

具体 transport、encoded store、record store、decoder、diagnostics 与 `ProfileAccessPolicy` 可在 `FoveaPipeline` composition root 显式注入。官方 `FoveaSystemPipeline.open` 提供安全默认组合：禁用 URLCache/Cookie 的 transport、明确的 `URLSessionTransportPolicy`、同一 StoreGeneration 下的 stores、默认 public-only 的 Profile policy 接缝与 ImageIO target decoder。时钟、namespace registry、stage registry 与 executor 是 `package` 实现细节，不进入外部 API。同步 ImageIO probe/decode 由专用 Dispatch work executor 执行，不占用 Swift cooperative executor。

运行预算不得通过初始化器旁路覆盖：内存成本上限只能来自已冻结的 `PipelineConfiguration.memoryCostLimit`，并进入 full fingerprint。语义 fingerprint 只包含会改变字节、像素或传输语义的字段；并发度、队列长度和内存成本等运行参数只进入 full fingerprint。配置指纹与实际运行值必须一一对应。

完整 codec/processor/source/advisor registry 仍是后续候选，不得把下文目标模型描述为当前实现。

## 4. `Fovea.shared`

`Fovea.shared` 是默认 pipeline 的只读 façade：

- 不暴露 `registerGlobally`、`setDefaultDecoder` 一类全局可变 API；
- 测试和多账户 App 应显式持有独立 pipeline；
- 更换账户不能只修改 shared pipeline 内的 token，必须通过 AuthorizationContextID/NamespaceGeneration 形成新的请求上下文；
- 默认 pipeline 的替换只允许发生在应用 composition root，且已有请求不迁移到新实例。

## 5. Registry

codec、processor、source loader 和 advisor 注册采用构造期 builder，完成后冻结：

```text
RegistryBuilder
  -> validate duplicate IDs / priorities / fingerprints
  -> freeze
  -> ImmutableRegistry
```

- registry ID 必须稳定、版本化、可诊断；
- 同一 ID 的重复注册默认失败，不按“最后一个覆盖”处理；
- decoder 选择顺序由 format probe、capability 与显式 priority 决定；
- fallback decoder 只能处理同一已探测格式，不能绕过 DecodeLimits 或 MIME/magic 安全结论；
- 导入一个模块不得自动改变全局 pipeline 行为。

## 6. 依赖共享

多个 pipeline 可以显式共享：

- Transport；
- 只读 codec registry；
- 同一 namespace 安全策略下的 Akashic store coordinator。

不得隐式共享：

- task registry；
- UI subscriber；
- namespace generation；
- 可变授权状态；
- 未声明多进程安全的 disk writer。

共享 store 时必须使用相同 StoreGeneration、key schema、payload layer 和安全策略；否则构造失败或使用独立 store。

## 7. 测试可替换性

测试必须可以注入：

```text
package-only TestWallClock
FakeTransport
InMemoryStore
DeterministicScheduler
FailureInjector
RecordingDiagnosticsSink
```

不得依赖 method swizzling、全局单例重置或真实 sleep 才能测试核心状态机。

## 8. Property tests

- **PIPE-PT-001**: 等价配置产生稳定且相同的 fingerprint；
- **PIPE-PT-002**: 语义字段改变 semantic/full fingerprint，纯运行字段只改变 full fingerprint；
- **PIPE-PT-003**: 新 configuration generation 不改变旧任务结果；当前 generation 语义是构造新 pipeline，旧实例与其进行中任务继续持有不可变旧快照，不支持热改同一实例；
- **PIPE-PT-004**: pipeline identity 独立、配置快照不可变，且运行预算不能绕过配置另行覆盖；
- **PIPE-PT-005**: 导入扩展或实验模块不自动改变 pipeline；当前架构不存在全局默认 pipeline 或自动 registry，所有能力只在 composition root 显式注入；
- **PIPE-PT-006**: 两个 pipeline 不隐式共享 subscriber/task state；
- **PIPE-PT-007**: 共享 store 的 schema/security 不兼容时 fail closed；
- **PIPE-PT-008**: 测试 pipeline 可完全脱离全局 shared 状态运行。
- **PIPE-PT-009**: 官方安全组合根在同一缓存根复用兼容 StoreGeneration，并只组合安全默认 transport、持久 stores 与 target-pixel decoder；
- **PIPE-PT-010**: 旧配置缺少 decode working-set 字段时采用安全默认值；新预算只改变 full fingerprint 并与实际运行值一致。
