# Fovea Agent Continuity Protocol

本文件适用于任何在本仓库工作的 AI、自动化代理或人工协作者。它不是建议，而是开始多步骤任务前的强制协议。

## 1. 开始任务前

必须运行：

```sh
python3 scripts/check-project-memory.py
python3 scripts/check-workload-registry.py
python3 scripts/render-project-context.py
cat .artifacts/project-memory/current-context.md
```

在读取上下文前，不得：

- 修改生产代码、测试、规范或实验计划；
- 宣称某阶段、workload 或能力已完成；
- 删除、重命名、重新编号已接受的 W1-W15；
- 用当前会话摘要替代仓库中的 project memory。

## 2. 权威连续性来源

按以下顺序解释项目事实：

1. 当前代码、测试和不可变实验工件；
2. `docs/project-memory/project-memory.json`；
3. `docs/project-memory/discussion-ledger.json`；
4. `docs/project-memory/long-horizon-roadmap.json` 与其 canonical plan；
5. `Benchmarks/workload-registry.json`、claim policy、claim families、ADR 和专项规范；
6. 当前或历史聊天上下文。

发现冲突时必须 fail closed：记录冲突、停止相关声明、显式解决。不得静默选择更方便的版本。

## 3. 状态词必须精确

以下状态不得混用：

- `planned`
- `specified`
- `partially-implemented`
- `implemented`
- `calibrated`
- `formally-verified`
- `release-claim-eligible`
- `capability-gap`
- `not-comparable`
- `inconclusive`

W1-W3 是当前 Phase 0b 可执行子集；它们完成不表示 W4-W15 完成。

## 3.1 长期路线映射

每个多步骤任务还必须读取生成上下文中的 `Long-horizon roadmap control plane`，并在开始修改前明确映射到：

- 一个或多个 P0-P9 phase；
- 一个活跃 open obligation；
- 当前执行队列中的项目，或新建且落库的队列项目。

不得因当前任务不涉及某阶段而删除、隐藏或暗示其已经完成。P0-P9 的删除、重编号或实质性重排必须有 discussion-ledger supersession。

## 4. 讨论与决策落库

用户确认或明确要求的长期决策，在任务结束前必须进入下列至少一处：

- `docs/project-memory/discussion-ledger.json`
- ADR
- 专项规范
- workload registry
- claim family / negative-results registry
- `project-memory.json` 的 standing requirements、capability gaps 或 open obligations

任何 supersession 必须记录：旧决策 ID、新决策 ID、理由、受影响文件和迁移状态。

## 5. 任务结束前

必须：

1. 更新已完成证据、能力缺口、负结果和开放事项；
2. 保留未完成工作，不得因本轮未处理而从报告或目录消失；
3. 运行 project-memory、workload-registry、文档和追踪门；
4. 报告本轮完成项与仍阻塞项；
5. 不得在用户未明确要求时执行 `git reset`、commit、tag 或 push。
