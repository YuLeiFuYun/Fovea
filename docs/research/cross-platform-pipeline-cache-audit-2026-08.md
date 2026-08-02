# 跨平台图片管线与缓存机制审计（2026-08）

> 状态：Research input，不是稳定 API、实现完成声明或性能证书。
> 对应路线：P6 跨仓 conformance、P7 scoped Pareto comparison、P9 evidence-led cross-platform expansion。
> 审计日期：2026-08-01。

## 1. 审计目的

Fovea 已完成 ImageCraft 与 Akashic 的物理拆分，当前风险不再是“缺少更多抽象”，而是：

1. 插件边界是否足以承载真实的非 Apple 实现；
2. shared work、取消、资源所有权和回收尾部是否有可执行 oracle；
3. 大图或局部图像工作负载是否必须引入 region/tile 级执行模型；
4. 当前 SIEVE 缓存策略是否应被 S3-FIFO、S4-FIFO 或学习型策略替换；
5. 跨平台扩展是否会迫使 Apple 路径退化为最低公分母。

本审计只吸收可验证机制。仓库规模、流行度、论文中的总体平均优势或其他平台的绝对性能，均不直接转化为 Fovea 的优越性声明。

## 2. 固定源码快照

本轮阅读以下上游源码快照；后续实现引用机制时必须重新锁定版本，而不是依赖浮动分支：

| 项目 | 固定提交 | 重点文件 | 角色 |
|---|---|---|---|
| Coil | `ec724ef5a72c787cf910de3cae3cc703b3337f25` | `ComponentRegistry.kt`、`RealImageLoader.kt` | Compose Multiplatform 图片加载器；组件组合与平台边界输入 |
| Glide | `688da5a311f0185c5d4ec97b4588c520d388c19c` | `Engine.java`、`ActiveResources.java` | shared job、active resource、内存/磁盘缓存与回收生命周期输入 |
| Fresco | `288a34c60a35d2d99912d43e2b6559af1e3fa61e` | `ProducerSequenceFactory.kt`、`ImagePipeline.kt`、`CloseableReference` | typed producer graph、request level、prefetch 和所有权诊断输入 |
| libvips | `2ff898f0a1637c45d15db532a7fbe2d30cc99aac` | `tilecache.c`、`region.c`、`threadpool.c` | demand-driven region/tile 工作集输入 |
| Caffeine | `946ca8b26001ee98c86ca004570d52c5260006ed` | `SievePolicy.java`、`S3FifoPolicy.java`、simulator | 缓存策略可执行 oracle 与 trace replay 输入 |

## 3. 机制判断

### 3.1 Coil：不可变组合优于运行时全局注册

Coil 的 `ComponentRegistry` 把 mapper、keyer、fetcher、decoder 与 interceptor 组合成一个构建完成后的组件表；`RealImageLoader` 持有该组合及 lazy memory/disk cache。

可采纳：

- 构建期注册、运行期只读；
- 平台特定 fetch/decode 与 common request/result 语义分离；
- 一个 composition root 明确拥有缓存和组件生命周期；
- 组件选择顺序必须可测试、可诊断、可冻结。

不可直接采纳：

- 任意组件可以重写身份或安全语义的通用 interceptor 链；
- 进程级可变 registry 或隐式 singleton；
- 使用运行时类型匹配代替有限 capability contract。

对 Fovea 的约束：新 codec 接入仍要求 `ImageCodec`；持久化替换仍必须是保持 generation、writer lease、revoke 与跨存储提交约束的 qualified bundle。不得把 Coil 风格组件表扩展成可改写 Fetch/Content/Decode/Render 身份的插件系统。

### 3.2 Glide：shared work 与资源回收是同一状态机

Glide `Engine` 同时协调 active resources、memory cache、in-flight jobs、disk cache provider 与 recycler。其取消路径通过锁和 `removeIfCurrent` 防止新请求附着到正在取消的旧 job。

可采纳为挑战测试：

- shared task 从“可加入”到“正在取消/已完成”的原子状态转换；
- 资源完成、进入 active set、释放、进入 memory cache 或销毁的所有权闭环；
- 回调重入和回收不得在持有核心锁时触发不可控工作；
- 对象池或 buffer pool 必须证明峰值、重用收益、清零策略和内存警告回收尾部。

不得因 Glide 使用对象池就默认在 Fovea 引入池。Apple 图像对象、解码后表面和变换缓冲的复制/别名语义不同，必须先通过 held-out workload 证明收益。

### 3.3 Fresco：producer graph 适合作为可观测性 oracle，不适合作为公共运行时

Fresco 用 typed producer sequence 表达 encoded/decoded fetch、memory/disk cache、prefetch、post-process 和 request level，并通过 `CloseableReference` 显式管理 native/pooled resources。

可采纳：

- 明确区分 memory-only、encoded-cache、disk、network 等最低允许请求层级；
- prefetch 与可见请求共用底层机制，但具有不同优先级、资格与结果交付契约；
- 资源所有权泄漏应有可观测事件、测试注入和终止时审计；
- pipeline stage graph 可用于离线 trace 和诊断，不必成为运行时公共 DAG。

拒绝：

- 把通用 producer graph 暴露为 Fovea 公共 API；
- 将引用计数包装器扩散到所有 Swift 调用方；
- 以复杂图结构替代当前明确的固定阶段和有限 composition seams。

### 3.4 libvips：局部工作集需要独立执行模型

libvips 的 tile cache 对 tile 使用 `DATA/CALC/PEND` 状态、引用计数、最大 tile 数、访问模式和可复用队列。其价值不只是“缓存 tile”，而是让需求驱动计算、并发等待和有界工作集形成统一模型。

可采纳为 ImageCraft/Fovea 后续实验：

- region/tile 请求必须携带坐标、输出表面、halo、访问模式和预算；
- 同 tile 计算去重与普通整图 DecodeKey 不应混为一个身份；
- tile 被等待、计算、复用或回收时需要明确状态机；
- 随机访问、顺序扫描和缩略图生成应使用不同 workload；
- 峰值工作集、重复计算、边界 halo、线程占用和取消回收尾部均为主要指标。

当前不把 region/tile API 加入公共产品。ImageCraft 的公开值类型仍以 `CGImage` 为核心，先做内部实验与第二实现，再决定是否存在可跨平台的最小语义层。

### 3.5 Caffeine：策略 simulator 是 oracle，不是依赖

Caffeine 的 simulator 已包含 SIEVE、S3-FIFO、W-TinyLFU 等策略实现。它适合作为相同 trace、相同容量/权重模型下的外部可执行 oracle。

Fovea/Akashic 的比较必须至少保留：

- object-count 与 byte-weight 两种容量约束；
- 命中率、byte hit ratio、延迟、写放大和 delayed-hit aggregate waiting；
- phase change、扫描污染、one-hit wonder、热点漂移和大对象挤占；
- 策略元数据成本、锁/原子操作成本和回收尾部；
- 与 Belady 离线界限的 gap，但不得把离线最优当作可部署基线。

Caffeine 只作为测试 oracle；Akashic 不增加 Java/JVM 运行时依赖。

## 4. 论文输入

### SIEVE（NSDI 2024）

论文强调命中路径无锁更新、简单实现和大量 trace 上的可扩展性。Fovea 已有 SIEVE 路径，但论文结果不能替代图片 workload 的权重、解码成本、写放大和 phase-change 证据。

来源：<https://www.usenix.org/conference/nsdi24/presentation/zhang-yazhuo>

### S3-FIFO（SOSP 2023）

S3-FIFO 通过 small/main/ghost FIFO 与 lazy promotion 处理 one-hit wonder。Fovea 已保留 S3-FIFO 负结果，后续比较必须解释反例域，而不是用新的总体平均覆盖旧负结果。

来源：<https://dl.acm.org/doi/10.1145/3600006.3613147>

### S4-FIFO / Learning-Augmented Heuristics（OSDI 2026）

S4-FIFO 将学习放在低频控制面，数据面继续使用简单 FIFO heuristic。该分层与 Fovea 的“策略建议不得控制安全与身份语义”相容，但当前仅进入离线 replay：

- 模型不能位于命中热路径；
- 必须有无模型回退；
- 训练 trace、held-out trace、漂移和最坏回归必须分开报告；
- 学习目标必须包含 byte cost、decode cost、write amplification 和用户可见等待，而不只是 miss ratio。

来源：<https://www.usenix.org/conference/osdi26/presentation/xia>

### Seer（NSDI 2024）

Seer 利用可提前观察的未来请求改进 prefetch/eviction。移动图片管线不能假设网络中存在此类预告，但 UI 可见性、列表滚动方向、布局测量和导航意图构成弱 future signal。它们只能输入 admission/prefetch policy，不能改变内容身份、授权或持久化资格。

来源：<https://www.usenix.org/conference/nsdi24/presentation/lei>

### Midas（NSDI 2024）

Midas 把 cache/soft state 视为可在内存压力下快速回收的应用管理对象。Apple 平台没有等价内核接口，但其“软状态分级、压力响应时间、极端压力下不 OOM”的评价框架可映射到 W12。

来源：<https://www.usenix.org/conference/nsdi24/presentation/qiao>

## 5. 采纳矩阵

| 机制 | 决定 | 路线 | 进入生产前证据 |
|---|---|---|---|
| 不可变组件组合 | 采纳设计原则 | P6 | capability selection、顺序确定性、错误稳定性、无全局状态测试 |
| shared job 取消原子性 | 采纳挑战测试 | P6/W7 | join-vs-cancel model check、回调重入、tombstone/retention 证明 |
| active resource 生命周期账本 | 采纳内部模型 | P0/P6/W12 | 所有权转移、峰值 alias、内存警告与取消回收尾部 |
| typed producer graph | 仅诊断/离线模型 | P6/P7 | 不增加公共 DAG；trace 与固定阶段一一映射 |
| region/tile demand execution | 实验 | P8/P9 | 真实第二 backend、局部 workload、峰值和正确性证据 |
| Caffeine simulator oracle | 采纳测试工具 | P7/W13 | 固定 revision、相同 trace/容量/权重、结果 schema |
| S4-FIFO | 评估 | P7/W13 | held-out 与最坏回归、无模型回退、控制面预算 |
| future-aware prefetch | 评估 | P7/W1/W10/W15 | UI signal 的因果增益、网络成本、误预取和隐私边界 |
| 全局可变 registry | 拒绝 | 全局 | 与身份、安全、可重复性和并发隔离冲突 |
| 默认学习型缓存 | 拒绝 | P7 | 无稳定 held-out、漂移和回退证据 |
| 公共通用 DAG | 拒绝 | P6 | 复杂度高且弱化固定阶段证明 |

## 6. 直接行动项

1. **P6：组件选择 conformance**
   为 codec 与 persistent-store bundle 建立构建期不可变选择测试；记录候选集合、选择原因、拒绝原因和 fingerprint。

2. **P6/W7：join-cancel-release 模型**
   把 Glide 的 cancelling-job 竞态转化为 Fovea `SharedTaskRegistry` 的有限状态模型和压力测试，覆盖新订阅者与最后订阅者取消交错。

3. **P0/W12：资源生命周期账本**
   扩展现有 ImageIO ledger，加入 active-render surface、memory-cache ownership、UI alias 和 memory-pressure reclaim tail。

4. **P7/W13：外部策略 oracle**
   用固定 Caffeine revision 对同一 immutable trace 运行 SIEVE、S3-FIFO、W-TinyLFU；增加 S4-FIFO 的离线参数建议实验，但不进入运行时依赖。

5. **P7/W1/W10/W15：弱 future signal**
   对滚动方向、viewport 距离、导航预热和 Low Data Mode 进行预注册消融；错误预取字节、能源与可见首帧同时计入损失。

6. **P8/P9：region/tile 原型**
   仅在第二 backend 存在后建立内部 tile request/identity/lifecycle 原型；不得提前改变 ImageCraft/Fovea 稳定产品面。

## 7. 停止条件

出现以下任一情况时停止扩张并回退：

- 新抽象不能由至少两个真实实现验证；
- 插件可以改变 Fovea 的身份、授权、namespace generation、revoke 或 commit eligibility；
- 新缓存策略只改善平均 miss ratio，却恶化任一硬正确性、写放大上界或预注册主要指标；
- region/tile 路径在目标 workload 中不能显著降低峰值或重复计算；
- 学习控制面没有确定性回退、held-out 证据或最坏回归界；
- 公共 API 增量超过其可证实的当前使用者和测试面。

## 8. 结论

跨平台项目最有价值的不是复制其 API，而是提取可证伪机制：不可变组合、shared-job 取消原子性、资源所有权账本、需求驱动局部工作集和可执行缓存 oracle。当前优先级仍是 Fovea 公共根、current-pin clean-copy、rollback、跨仓 conformance 和 scoped Pareto 证据；跨平台运行时与 tile API 保持实验状态，直到真实第二实现证明边界。
