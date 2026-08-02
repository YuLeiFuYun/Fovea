# 贡献指南

Fovea 当前处于 `0b-in-progress`，公共 API、持久格式和性能契约尚未稳定。贡献目标不是扩张功能清单，而是用可复现证据强化当前阶段的正确性边界。

## 开始之前

先执行连续性入口：

```sh
scripts/project-session-bootstrap.sh
```

它会验证并输出活跃讨论决策、W1-W15 状态、能力缺口、负结果、阶段阻塞和开放事项。在阅读生成的 `.artifacts/project-memory/current-context.md` 前，不应开始多步骤修改。

随后：

1. 阅读 `docs/IMPLEMENTATION_STATUS.md`、`docs/ARCHITECTURE.md`、`docs/specifications/interdisciplinary-engineering.md` 和与改动相关的活动规格；
2. 检查 `docs/project-memory/project-memory.json`、`docs/project-memory/discussion-ledger.json`、`docs/engineering-knowledge.json` 与 Accepted ADR。Proposed ADR 不得覆盖已执行代码和活动规格；
3. 对身份、HTTP、鉴权、持久化、并发、安全、发布或公共 API 的变更，先写明不变量、失败模式和迁移影响；
4. 新接受的长期讨论结论必须在任务结束前进入 discussion ledger、ADR、专项规范、workload registry、claim family、negative-results 或 project memory；
5. 不提交真实凭证、私有 URL、账户标识、用户缓存、开发者签名材料或机器专属配置。

## 变更原则

- 保持依赖方向和固定职责 stage；不要引入 service locator、任意 interceptor 图或运行时全局注册表；
- 资源限制、安全策略、取消和错误传播必须显式且可测试；
- 新公共符号需要真实外部用例、文档和 API 审查；仅供 package 内兄弟 target 使用的声明应使用 `package`；
- 新规格必须由失败测试、实现碰撞或安全事件驱动；不要为假想未来能力扩大治理面；
- 每个缺陷修复都应增加永久回归测试；高风险不变量应考虑加入 mutation catalog；
- 跨学科概念只能生成候选假设，必须翻译为状态、边界、指标、反例和适用范围；
- 重大问题解决后检查是否产生可复用“金蛋”。promoted 发现必须有真实资产、独立证据、复用边界和过度推广风险；发现“不应抽象”同样可以登记。

## 本地验证

确定性验证默认不依赖公网：

```sh
scripts/verify.sh
```

关键不变量变异测试：

```sh
RUN_CRITICAL_MUTANTS=1 scripts/verify.sh
```

真实网络实验是独立环境证据：

```sh
RUN_LIVE_NETWORK=1 scripts/verify.sh
```

提交前至少确保格式、严格并发编译、单元/集成测试、文档和结构门禁通过。不要把本地工件描述为 protected CI、独立审计或最终 merge commit 的发布证据。

## 提交与评审

提交应保持单一目的，并说明：

- 改变的契约及其适用边界；
- 新增或修改的测试 ID；
- 失败时的系统行为；
- 资源、隐私、缓存身份和兼容性影响；
- 未验证的假设与回滚方式；
- 关联的 `FOVEA-LAW-*`，以及是否新增、更新或明确拒绝某项 `FOVEA-EGG-*`。

安全问题按 `SECURITY.md` 私下报告。贡献按照根目录 `LICENSE` 中的 MIT License 条款提交。
