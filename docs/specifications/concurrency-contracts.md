# Swift 并发与所有权契约

> **状态：Proposed，Core v1 Candidate 规格。**

## 1. 原则

- 公共值模型优先满足 `Sendable`；
- UI 类型与展示状态固定在 `@MainActor`；
- mutable pixel/storage object 必须单一所有者或显式同步；
- 不因编译器报错而大面积添加 `@unchecked Sendable`；
- 持锁期间不得 `await`、调用未知回调或执行用户代码；
- PipelineConfiguration/Registry 构造后不可变，运行中不通过全局状态热修改。

## 2. 类型边界

### FoveaCore

Request、key、policy、event、error 等公共值类型必须是真正的 `Sendable`。闭包型扩展点必须标记 `@Sendable`，并明确执行器语义。Pipeline/Registry 使用不可变快照；配置变化创建新 generation，不在 actor 内热替换依赖。

### ImageCraft

- `CGImage`/Core Foundation 对象只能通过审计过的不可变 wrapper 跨任务传递；
- wrapper 若使用 `@unchecked Sendable`，必须在源码注释与测试中证明底层对象创建后不再可变、不暴露 mutable data provider；
- `NSImage`、`UIImageView`、`NSImageView` 不进入 Core 并发边界；
- 可变 pixel buffer、CIContext/Metal command resource 由专用 executor、actor 或池管理，不自由共享。

### UI

UIKit/AppKit/SwiftUI adapter 和状态机更新均在 MainActor。Pipeline 不在后台线程直接写 view。

## 3. ByteStream 所有权

Transport body 默认是单消费者异步序列。若需要同时 hash、staging write 和 progressive decode，由 Fovea 内部的受控 fan-out 组件完成：

- 有界缓冲；
- 慢消费者背压或按策略丢弃 preview 更新；
- staging/hash 不得丢字节；
- sequence/iterator 不向用户暴露多消费者假设；
- consumer 取消后的 buffer 回收可证明。

## 4. Actor 与锁

- actor 保护任务注册表、订阅关系、namespace generation 等粗粒度状态；
- memory cache 热路径可使用稳定地址锁；
- 锁内只做 O(1) 元数据更新，不做 I/O、解码、hash 大块数据或回调；
- 锁顺序必须文档化，禁止跨模块隐式嵌套锁；
- continuation 只能完成一次，所有完成路径使用统一状态机。

## 5. Resource permit 与 observer

- Network/Disk/Decode/Process permit 的获取与释放必须结构化、幂等；
- 等待 permit 的任务可取消，取消后不泄漏 reservation；
- diagnostics observer 在锁/actor 外通过有界队列调用；
- observer 阻塞、失败或事件丢弃不得反向阻塞 pipeline；
- 用户闭包不得在持锁、metadata transaction 或 MainActor 不必要区域执行。

详细规则见 `resource-budgeting.md`、`diagnostics-contract.md` 与 `pipeline-configuration.md`。

## 6. Cancellation

Swift task cancellation、URLSession cancellation 和 Fovea Subscriber cancellation 是不同信号。适配层负责映射，但任何一层取消都必须幂等，并在结构化事件中记录实际生效阶段。

## 7. 测试

- Swift strict concurrency 无未解释 warning；
- Thread Sanitizer 覆盖任务 join/leave、cache get/put、namespace revoke；
- 随机化 cancellation/finish/error 竞态；
- ByteStream 慢 decoder、慢 disk、consumer cancel 的背压测试；
- MainActor 断言覆盖全部 UI 状态变更；
- `@unchecked Sendable` 类型维护显式 allowlist，新增项需要 review；
- permit wait/cancel/pressure transition 随机化测试；
- diagnostics sink 阻塞或抛错不影响请求；
- pipeline configuration generation 切换不改变旧任务。
