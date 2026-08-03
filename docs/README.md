# Fovea 设计文档索引

## 权威范围与冲突处理

1. 当前代码、测试和不可变实验工件决定已执行事实；
2. `project-memory/project-memory.json` 与 `project-memory/discussion-ledger.json` 决定跨会话活跃要求、开放事项与已接受讨论；
3. Accepted ADR 决定其明确范围内的决策；
4. `specifications/` 与 `Benchmarks/workload-registry.json` 决定可执行语义、测试、workload 和默认行为；
5. `ARCHITECTURE.md` 决定系统边界、产品范围和阶段门禁；
6. Technology Radar / Competitive Contracts 提供研究与对照信息，不构成稳定 API。

出现直接冲突时停止实现并提交文档修复，不能由实现者静默选择。

## 实现者最短路径

### 当前 0b 实现者必读

0. 运行 `scripts/project-session-bootstrap.sh` 并阅读生成的 `.artifacts/project-memory/current-context.md`；
1. `project-memory/README.md`、`project-memory/project-memory.json`、`project-memory/discussion-ledger.json`；
2. `IMPLEMENTATION_STATUS.md` 与 `ARCHITECTURE.md` §3、§4、§8、§11、§18；
3. 与改动直接相关的活动 `specifications/`；
4. `TEST_CATALOG.md` 与 `test-traceability.json`；
5. `specifications/benchmark-workloads.md`、`../Benchmarks/workload-registry.json`、HTTP/cache/AI assurance 规格；
6. Accepted ADR。Proposed ADR 只记录待接受决策，不得覆盖已执行的活动规格和代码事实。

### 历史审查

`specifications/core-surface.md` 只记录 Phase 0a 的历史实现面与符号预算，不再是当前白名单。`COMPETITIVE_CONTRACTS.md`、Technology Radar 与 Proposed ADR 提供研究背景，不构成已交付能力声明。

## 文档冻结

当前阶段新增活动能力必须同时更新架构、对应规格、追踪矩阵和可执行证据。只有愿景而无失败测试、trace 或安全事件的扩展继续保留在 Proposed/Experimental，不得进入 README 的“当前已实现”清单。

## 当前权威文档

- [项目连续性与权威记忆](project-memory/README.md)
- [机器可读项目记忆](project-memory/project-memory.json)
- [讨论决策账本](project-memory/discussion-ledger.json)
- [已接受 W1-W15 矩阵](project-memory/accepted-workload-matrix.md)
- [机器可读 W1-W15 注册表](../Benchmarks/workload-registry.json)
- [Phase 0b 收口与 Phase 1 入口](PHASE0B_GRADUATION_AND_PHASE1_ENTRY.md)
- [机器可读阶段状态](phase0b-status.json)
- [当前实现状态](IMPLEMENTATION_STATUS.md)
- [架构](ARCHITECTURE.md)
- [跨学科工程定律与发现机制](specifications/interdisciplinary-engineering.md)
- [工程知识与金蛋机器注册表](engineering-knowledge.json)
- [竞品差异与验收契约](COMPETITIVE_CONTRACTS.md)
- [技术雷达](TECHNOLOGY_RADAR.md)
- [测试 ID 注册表](TEST_CATALOG.md)
- [AI 主导软件开发质量专题研究（2026）](research/AI_ASSISTED_SOFTWARE_QUALITY_2026.md)
- [图片加载管线参考审计（2026-07）](research/image-pipeline-reference-audit-2026-07.md)
- [Fovea 世界级工程审查（2026-07）](research/world-class-engineering-audit-2026-07.md)
- [研究与实现来源清单](research/reference-provenance.json)
- [竞品精确版本锁](research/comparator-lock.json)
- [比较本体与能力分类](specifications/comparison-ontology.md)
- [语义可比性与最佳声明契约](specifications/comparability-contract.md)
- [机器可读比较本体](research/comparison-ontology.json)
- [竞品与研究对象注册表](research/comparator-registry.json)
- [有限作用域声明策略](../Benchmarks/claim-policy.json)
- [统计声明族](../Benchmarks/statistical-claim-families.json)
- [数学理论注册表](research/mathematical-theory-registry.json)
- [负结果注册表](research/negative-results.json)
- [Comparative Lab](../Benchmarks/ComparativeLab/README.md)
- [Cache Lab](../Benchmarks/CacheLab/README.md)
- [Demo 与真实网络实验](../Examples/README.md)

## ADR

- [ADR-0001：Reality Gap](adr/0001-reality-gap.md)
- [ADR-0002：持久缓存演进](adr/0002-persistent-cache-evolution.md)
- [ADR-0003：HTTP Cache Profile 与一致性测试](adr/0003-http-cache-conformance-profile.md)
- [ADR-0004：FetchExecutionKey 与共享优先级](adr/0004-fetch-execution-and-shared-priority.md)
- [ADR-0005：Namespace 撤销与派生权限继承](adr/0005-namespace-revocation-and-derived-inheritance.md)
- [ADR-0006：不可变 Pipeline 配置](adr/0006-immutable-pipeline-configuration.md)
- [ADR-0007：缓存配额与不透明 Blob 标识](adr/0007-cache-quotas-and-opaque-blob-locators.md)
- [ADR-0008：Phase 0a/0b 交付门禁](adr/0008-phase-0-delivery-gates.md)
- [ADR-0009：AI 主导实现的独立质量保障](adr/0009-ai-generated-code-assurance.md)
- [ADR-0010：OriginalEncoded 存储规模、预算与近似持久 LRU](adr/0010-original-encoded-store-scale-and-recency.md)
- [ADR-0011：版本化图像 codec 能力契约与保守准入](adr/0011-codec-capability-contract.md)
- [ADR-0012：可插拔 Codec、独立 ImageIO 产品与渲染缓存边界](adr/0012-pluggable-codec-and-cache-boundaries.md)

## 可执行规格

- [Phase 0a 历史实现面与符号预算](specifications/core-surface.md)
- [Source 身份与失效](specifications/source-identity.md)
- [Target Geometry 与像素规范化](specifications/target-geometry.md)
- [缓存、身份与持久格式](specifications/cache-semantics.md)
- [鉴权上下文与 Cookie 集成](specifications/auth-context-integration.md)
- [HTTP 缓存一致性](specifications/http-cache-conformance.md)
- [调度、共享任务与取消](specifications/scheduler-semantics.md)
- [Swift 并发与所有权](specifications/concurrency-contracts.md)
- [Pipeline 配置与依赖注入](specifications/pipeline-configuration.md)
- [资源预算与压力响应](specifications/resource-budgeting.md)
- [错误、重试与回退](specifications/error-recovery.md)
- [缓存预算、配额与 GC](specifications/cache-budget-gc.md)
- [诊断与事件隐私契约](specifications/diagnostics-contract.md)
- [图像表示、颜色与动态范围](specifications/image-representation.md)
- [动画图像策略](specifications/animation-policy.md)
- [公共 API、发布与依赖治理](specifications/api-release-policy.md)
- [Canonical Benchmark Workloads](specifications/benchmark-workloads.md)
- [安全默认拒绝矩阵](specifications/security-defaults.md)
- [SwiftUI 图片状态机](specifications/swiftui-image-state.md)
- [平台默认配置](specifications/platform-profiles.md)
- [AI 主导开发质量保障](specifications/ai-development-assurance.md)
- [跨学科工程定律与发现机制](specifications/interdisciplinary-engineering.md)

## 可执行治理工件

- [跨学科工程知识 JSON Schema](schemas/engineering-knowledge.schema.json)
- [工程知识与金蛋机器注册表](engineering-knowledge.json)
- [PR Evidence Bundle JSON Schema](schemas/ai-pr-evidence-bundle.schema.json)
- [竞品契约证据 JSON Schema](schemas/competitive-contract-evidence.schema.json)
- [AI-Assisted Change Review 模板](templates/AI_CHANGE_REVIEW.md)
- [竞品契约证据模板](templates/COMPETITIVE_CONTRACT_EVIDENCE.json)

## 跨仓 Conformance

- [Persistent Store Provider Conformance v1](../ConformanceKits/PersistentStoreProvider/v1/README.md)
- [Image Codec Conformance v1](../ConformanceKits/ImageCodec/v1/README.md)
