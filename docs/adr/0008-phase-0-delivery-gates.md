# ADR-0008：Phase 0a/0b 交付门禁与文档冻结

- **状态：Proposed**
- **日期：2026-07-18**

## 背景

现有 Phase 0 同时要求最小可运行切片、外部 HTTP 一致性语料、持久化 crash matrix、双竞品适配器、双设备复现和性能存在性证明。每一项都有价值，但把它们全部放在第一个工程门禁，会导致实现尚未形成时先建设完整验证宇宙。

AI 降低了并行原型和测试生成成本，但不会消除集成顺序。正确做法不是删除严格门禁，而是把“能运行”与“值得进入 Core v1 Candidate”分开。

## 决策

### Phase 0a：Runnable Slice

目标是形成可执行、可替换、可观测的最小垂直切片：

```text
URL
→ FetchVariantKey / FetchExecutionKey
→ 有界 Transport
→ OriginalEncoded 单进程原子提交
→ ImageIO target-size decode
→ RenderedMemory
→ 一个 UI surface
```

0a 必须具备最小安全和身份不变量，但不要求完成外部 HTTP corpus、完整 StoreGeneration crash matrix、双 15% 性能门或全平台 UI。

0a 内部再分两段：

```text
0a-bootstrap（最多前 1–3 个 PR）
  最小产品切片 + 基础产品测试
  AIQA 只强制权限隔离、基础 Evidence、clean CI、gate 不可篡改、依赖默认拒绝和 accountable owner
  mutant/rollback harness 可以 scaffolded，但不能伪报 pass

0a-complete
  TEST_CATALOG 的 0a 产品测试全部通过
  AIQA-GATE-001...011 全部通过
  指定 critical mutants 被真实执行并杀死
```

通过 0a-bootstrap 只允许继续构建；只有 0a-complete 才算 Phase 0a 完成。两者都不形成公开兼容承诺，也不证明项目相对竞品值得存在。

### Phase 0b：Existence Gate

0b 承担完整 G0、W1、W2、W3、竞品适配器、外部 HTTP profile corpus、升级/撤销竞态和双设备复现。通过 0b 后才可进入 Core v1 Candidate。

存在性支持两条路径：

1. **Performance Path**：严格性能门禁和所有正确性门禁均通过。
2. **Correctness Path**：所有正确性门禁通过，target-pixel invariant 成立，性能满足预注册 non-inferiority 护栏，并由适配器证明至少一个关键正确性契约在对照实现中不可表达、未支持或实际失败。

Correctness Path 不得宣传“性能领先”；它只证明 Fovea 作为更严格的正确性/安全实现有继续建设价值。

### 文档冻结

从本 ADR 生效到 0a 完成：

- 不新增功能型大规格；
- 只允许修复实现 blocker、规范矛盾、安全缺口和 API 命名不一致；
- 新 capability slot 必须有实现碰撞证据和独立 ADR；
- FoveaLab 文档不得进入 0a PR 的阻塞条件；
- 新文档/大章节默认拒绝，除非引用失败测试 ID、0a blocker 日志/trace，或明确安全事件。

AI 主导实现的隔离、Evidence Bundle 和独立质量门由后续 ADR-0009 扩展；它们是交付控制，不重新扩大 0a 的产品功能范围。

## 后果

- 主线可以尽快获得真实代码反馈；
- 0b 的严格门禁全部保留，没有以“先跑起来”为由取消；
- 文档维护转为实现驱动，而不是继续前置穷举；
- 0a 原型失败可以低成本重写，不被 0b 基础设施沉没成本绑架。
