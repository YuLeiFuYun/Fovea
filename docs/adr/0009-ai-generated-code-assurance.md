# ADR-0009：AI 主导实现的独立质量保障

- **状态：Proposed**
- **日期：2026-07-18**

## 背景

Fovea 预计绝大部分实现、测试、文档和重构由 AI 编程智能体完成。模型能力正在快速提升，不能把治理建立在“AI 只能完成小任务”或某个固定模型错误率上。

同时，公开研究显示：自动测试通过不等于 merge-ready；AI 可以遗漏隐含契约、生成脆弱测试、推荐不存在的依赖、操纵可见评分面，并显著增加评审与集成负载。另有受控研究没有发现稳定的可维护性劣势，因此也不能按作者类型直接判定质量。

需要一个对模型代际中立、同时适用于人类和 AI 代码的证据体系。

## 决策

Fovea 采用 **AI Code Assurance System**：

1. **AI 是低先验信任、高吞吐实现来源。** 合并由证据决定，不由作者或模型自信决定。
2. **风险分级自治。** 变更按 R0–R4 分类；身份、HTTP、鉴权、持久化、并发、安全和发布属于 R3/R4。
3. **规格、实现和验收 oracle 分离。** 实现 agent 不得单方面修改门禁并据此自证通过。
4. **受保护验证。** held-out tests、关键变异体、可信 CI 和发布凭证不对实现 agent 开放写权限。
5. **小批量。** R1/R2/R3 使用逐级收紧的 provisional PR 预算。
6. **最小权限 agent。** 临时工作区、无生产秘密、网络/工具 allowlist、依赖和破坏性操作需审批。
7. **人类责任不外包。** R2/R3 必须有 accountable maintainer；AI review 不能替代人类理解签署。
8. **关键稳定契约采用两钥匙原则。** R3 进入 Stable/1.0 前需要第二位可信人类或外部独立审查；单人审查必须明确标记。
9. **证据可追溯且有可信生产者。** Agent 可以声明执行过程，但 gate 结果必须由 trusted CI、held-out evaluator 或人类 reviewer 写入/签署；发布生成依赖/SBOM/provenance。
10. **验收绑定最终 merge commit。** rebase、冲突解决或 merge queue 产生新 commit 后，旧 build/test evidence 自动失效并重跑。
11. **模型升级只改变通过率，不降低 gate。** 模型和 agent scaffold 通过 `FoveaAgentEval` 定期重新评估。

完整执行规则见 `docs/specifications/ai-development-assurance.md`。

## 为什么不是“所有 AI 代码人工逐行重写”

- 无法随着代码吞吐扩展；
- 人类重写并不天然产生独立 oracle；
- 会浪费 AI 对机械实现的优势；
- 容易形成形式审查而非真实理解。

Fovea 要求的是风险相关的人类理解、独立验证和可回滚性，而不是来源歧视。

## 为什么不是“再让另一个模型 review”

独立模型可以发现问题，但仍可能共享训练分布、上下文错误和可见测试偏差。它是 R1/R2 的有效辅助证据，不是 R3 的唯一批准者。OpenSSF 的 code-review 标准同样不把 AI/bot review 视为第二位理解代码的人。

## 对 Phase 0 的影响

Phase 0a 增加最小保障底座，但不扩大产品功能，并分成 `0a-bootstrap` 与 `0a-complete`：

- agent sandbox/权限策略；
- PR Evidence Bundle schema；
- protected gate 规则；
- `AIQA-GATE` 最小集合；
- Fovea 关键不变量 mutant catalog 初版；bootstrap 可先建立 harness，complete 必须真实运行指定 mutant；
- 干净 CI 对最终 verified commit 生成构建和测试证据。

Phase 0b 要求完整 R3 变更门禁、独立 oracle、发布前供应链证据和 repo-specific agent eval。该要求属于实现质量治理，不解除现有功能型文档冻结。

## 单人维护者模式

0.x 阶段允许：

```text
accountable human maintainer
+ independent AI review
+ held-out / mutation / differential oracle
+ 延迟二次人工复审
```

但这不能被表述为 two-party human review。身份、安全、持久化和发布契约进入 Stable/1.0 前，需要第二位可信人类或外部审计。

## 后果

正面：

- 质量门槛不随模型宣传或主观信心波动；
- AI 可以高并发实现，但不能自改目标、自改评分和自批；
- 关键错误更早通过独立 oracle 暴露；
- 代码、依赖和发布产物具有来源证据；
- 项目维护者必须真正拥有系统知识。

成本：

- 需要建设 trusted CI、held-out tests、mutation catalog 和 evidence tooling；
- 关键变更吞吐低于完全自动合并；
- 单人项目在 Stable 发布前需要引入外部审查；
- 需要维护 agent/tool allowlist 和定期 eval。

这些成本是大量 AI 代码进入关键基础库后的必要保险，而非可选文档流程。
