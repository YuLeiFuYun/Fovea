# Fovea 设计文档索引

## 权威范围与冲突处理

1. Accepted ADR：决定其明确范围内的决策；
2. `specifications/`：决定可执行语义、测试和默认行为；
3. `ARCHITECTURE.md`：决定系统边界、产品范围和阶段门禁；
4. Technology Radar / Competitive Contracts：提供研究与对照信息，不构成稳定 API。

出现直接冲突时停止实现并提交文档修复，不能由实现者静默选择。

## 实现者最短路径

### Phase 0a 必读

1. `specifications/phase-0a-surface.md`（允许/禁止实现面）；
2. `ARCHITECTURE.md` §3、§6、§8、§18；
3. `specifications/cache-semantics.md` 的 key/200/304/no-store/commit 子集；
4. `specifications/auth-context-integration.md`；
5. `specifications/scheduler-semantics.md`；
6. `specifications/target-geometry.md`；
7. `TEST_CATALOG.md` 的 Phase 0a IDs；
8. `specifications/benchmark-workloads.md` 的 0a smoke gate；
9. `specifications/ai-development-assurance.md` §16 的 0a-bootstrap/0a-complete AIQA 门禁。

### Phase 0b / 审查者必读

`ARCHITECTURE.md`、`COMPETITIVE_CONTRACTS.md`、`TEST_CATALOG.md`、benchmark/http/cache/AI assurance specs，以及 ADR-0002 至 ADR-0009。

## 文档冻结

Phase 0a 完成前只接受实现 blocker、规范矛盾、安全缺口和命名修正；新文档/大章节必须附失败测试 ID、blocker 日志/trace 或安全事件，否则默认拒绝。见 ADR-0008。

## 当前权威文档

- [架构](ARCHITECTURE.md)
- [竞品差异与验收契约](COMPETITIVE_CONTRACTS.md)
- [技术雷达](TECHNOLOGY_RADAR.md)
- [测试 ID 注册表](TEST_CATALOG.md)
- [AI 主导软件开发质量专题研究（2026）](research/AI_ASSISTED_SOFTWARE_QUALITY_2026.md)

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

## 可执行规格

- [Phase 0a 实现面与符号预算](specifications/phase-0a-surface.md)
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

## 可执行治理工件

- [PR Evidence Bundle JSON Schema](schemas/ai-pr-evidence-bundle.schema.json)
- [竞品契约证据 JSON Schema](schemas/competitive-contract-evidence.schema.json)
- [AI-Assisted Change Review 模板](templates/AI_CHANGE_REVIEW.md)
- [竞品契约证据模板](templates/COMPETITIVE_CONTRACT_EVIDENCE.json)

## 历史文档

- [V1 历史版本](archive/ARCHITECTURE_V1.md)
- [V2 前瞻草案历史版本](archive/ARCHITECTURE_V2_DRAFT.md)
- [规格化收敛前版本](archive/ARCHITECTURE_PRE_SPEC_REFINEMENT_2026-07-18.md)
- [持久化与一致性复审前版本](archive/ARCHITECTURE_PRE_DURABILITY_REVIEW_2026-07-18.md)
- [系统边界复审前版本](archive/ARCHITECTURE_PRE_BOUNDARY_REVIEW_2026-07-18.md)
- [交付性复审前版本](archive/ARCHITECTURE_PRE_DELIVERY_REVIEW_2026-07-18.md)
- [AI 质量保障专题前版本](archive/ARCHITECTURE_PRE_AI_ASSURANCE_REVIEW_2026-07-18.md)
- [Phase 0a surface 收敛前版本](archive/ARCHITECTURE_PRE_PHASE0A_SURFACE_REVIEW_2026-07-18.md)

历史文档不指导实现。活动文档的权威范围按本文开头的顺序处理。
