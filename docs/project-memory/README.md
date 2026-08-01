# Fovea Project Memory

该目录是跨会话、跨模型、跨执行环境的权威连续性层。聊天记录、模型上下文、摘要和个人记忆都不是唯一事实源。

## 权威顺序

1. 已提交或当前工作树中的生产代码、测试和不可变实验工件；
2. `project-memory.json` 中的活跃约束、开放事项和证据边界；
3. `discussion-ledger.json` 中带来源的已接受讨论决策；
4. `long-horizon-roadmap.json` 中的 P0-P9 状态、依赖和执行队列；
5. 专项规范、ADR、workload registry、claim families 和研究注册表；
6. 会话上下文与临时摘要。

若低层来源与高层来源冲突，必须停止相关声明，记录冲突并显式解决；不得静默选择更方便的版本。

## 强制工作流

开始任何多步骤 Fovea 任务前：

```sh
python3 scripts/check-project-memory.py
python3 scripts/render-project-context.py
cat .artifacts/project-memory/current-context.md
```

结束任务前：

- 新接受的用户要求已进入 discussion ledger 或现有规范；
- 新产生的决定、负结果、能力缺口、阻塞项已更新；
- 已完成与未完成工作分开记录；
- 没有把当前阶段子集描述成完整路线；
- 运行 `scripts/check-project-memory.py` 和 `scripts/check-workload-registry.py`。

## 禁止事项

- 只依赖聊天摘要继续长期工程任务；
- 删除仍活跃的决策而不创建 supersession 记录；
- 将“计划”“已实现”“已校准”“已正式验证”混为一谈；
- 将 W1-W3 的当前执行结果外推为 W1-W15 完成；
- 因后续实现方便而自行重命名、重新编号或替换用户已接受的 workload。

## 长期路线控制面

`long-horizon-roadmap.json` 是长期路线的机器可读状态机，canonical narrative plan 为 `docs/roadmaps/fovea-next-action-direction-2026-08-01.md`。

它固定：

- P0-P9 phase 编号、依赖和退出条件；
- 当前 active frontier；
- 可跨会话保留的 execution queue；
- 研究输入的采用、延后或拒绝边界；
- 禁止静默删除、重编号和越级的路线不变量。

`check-project-memory.py` 会验证该文件；`render-project-context.py` 会把它注入每次任务必须读取的上下文。
