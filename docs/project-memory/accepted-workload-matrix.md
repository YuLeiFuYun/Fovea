# Accepted W1–W15 Workload Matrix

> 来源：用户提供的前期讨论附件 `SRC-DISCUSSION-COMPARISON-ROADMAP-01`，SHA-256 `361438a15ca974aee4245a393052ee7a9a09fabc1954c1cee76afecf617000bf`。
>
> 本文件保留已接受的名称和核心目的。详细 fixture、语义剖面、主指标和 runner 可继续细化，但不得静默改号、换义或删除；任何调整必须通过 supersession 记录。

| ID | 已接受 workload | 核心目的 |
|---|---|---|
| W1 | 快速滚动图片流 | 取消、去重、卡顿、扫描污染 |
| W2 | 12/24/48 MP hero 图 | 下采样、峰值内存、色彩和方向 |
| W3 | 鉴权图库 | `no-store`、`Vary`、跨用户隔离、redirect |
| W4 | 渐进 JPEG | 首个可接受结果、扫描质量、取消 |
| W5 | GIF/APNG/WebP 动图 | 帧调度、帧缓存、掉帧、内存 |
| W6 | 弱网和中断恢复 | retry、resume、Range、流量浪费 |
| W7 | 1,000 并发请求 | 去重、线程数、锁竞争、公平性 |
| W8 | 缓存重启与损坏 | durability、恢复、外部删除 |
| W9 | 敌意图片 corpus | crash、OOM、超限、fuzz |
| W10 | SwiftUI identity churn | view 生命周期、旧图闪现、取消 |
| W11 | 多尺寸同源图片 | 编码下载共享、变体缓存 |
| W12 | 内存警告/后台切换 | 回收速度、状态一致性 |
| W13 | phase-changing cache trace | 淘汰策略自适应 |
| W14 | 离线/重验证 | stale、304、过期行为 |
| W15 | 低数据/昂贵网络 | 策略切换、优先级和预取抑制 |

## 已接受的边界

- W1–W3 是当前 Phase 0b 最小端到端闭环，不是完整比较体系。
- W4、W5、W6 若尚未实现，必须显示为 `capability-gap`，不能从矩阵中消失。
- W7–W15 即使 runner 尚未建立，也必须保留计划、状态、依赖和开放事项。
- 原仓库中的 “Adaptive Representation” 仍有价值，但不再占用 W4；它作为辅助 workload `X1-ADAPTIVE-REPRESENTATION-V1` 保留。

## Codec contract 与 workload 的关系（2026-07-27）

- W2 现在可以按 backend fingerprint 隔离 decode/render identity，并用 conservative working-set join 做分配前准入；这只是 host contract 改进，不等于新的大图 codec 已通过 W2。
- W4 的 strict progressive generation 值语义和模型检查已建立，但 production incremental input、preview cadence、final promotion、UI identity fence 和比较实验仍缺失；状态保持 `capability-gap`。
- W5 的 animated track 与 checked frame timing 词汇已建立，但 track enumeration、disposal/blend、frame cache、clock 和 playback 仍缺失；状态保持 `capability-gap`。
- W9 新增 capability/resource fail-closed 与有限模型证据，但独立 codec 的 parser/decode fuzz、sanitizer、历史漏洞 corpus 和 held-out corpus 尚未完成。
- 未来 codec 不得仅凭通过单元测试进入 W1-W3 或成为默认后端；必须先通过跨仓库 conformance kit，再按 `docs/roadmaps/fovea-codec-parallel-roadmap.md` 执行 shadow、canary、物理设备和 rollback 门。
