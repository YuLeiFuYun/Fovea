# 分层验证与证据新鲜度

Fovea 不再把所有测试、所有平台和所有证明串成每次修改都必须执行的单一命令。验证采用分层门禁：高频门提供快速且保守的反馈，昂贵门提供低频、源码绑定的资格证据。降低耗时不能以静默漏测为代价。

## Profile

### `smart`：默认开发门

```sh
scripts/verify.sh
```

默认门读取相对 `FOVEA_VERIFY_BASE`、`FOVEA_BASE_COMMIT` 或当前 `HEAD` 的实际变更，并执行：

- 并行静态门：工具链、项目记忆、工作负载、架构、组件 pin、traceability、工具合同、敏感材料、供应链和 Swift 格式；
- 测试文件变更：按测试类型生成精确 `swift test --filter`；
- 产品源码或依赖变更：升级为根包全量测试；
- HTTP/transport 变更：增加 WPT conformance 和确定性 loopback；
- cache/benchmark 变更：增加 CacheLab；
- Workbench 应用源码变更：增加 55 项宿主单元/集成测试；验证脚本变更只运行工具合同，不启动 Simulator；
- 无法分类的路径或任何删除路径：自动升级为 `premerge`，不得跳过。

目标预算为常规测试变更 5 分钟以内。该预算是工程目标，不是超时后把失败改成成功。

只查看计划而不执行：

```sh
python3 scripts/run-verification-profile.py --profile smart --plan
```

### `premerge`：合并前确定性门

```sh
FOVEA_VERIFY_PROFILE=premerge scripts/verify.sh
```

该门执行全部高频静态门、根包全量测试、CacheLab 和 loopback；源码或依赖改变时增加 Release 构建，Workbench 应用或验证工具改变时增加带 Release 审计的双设备 smoke。它不执行完整视觉矩阵、19 项 iPhone UI、5 项 iPad UI、sanitizer、clean-copy、完整源码回退调查和 mutation。

目标预算为 15 分钟左右。Simulator 基础设施异常最多按既有策略重试一次。

### `workbench-smoke`：有界 UI 门

```sh
FOVEA_VERIFY_PROFILE=workbench-smoke scripts/verify.sh
```

运行 55 项 Workbench 单元/集成测试，以及：

- iPhone：单图加载并发布预期/实际证据的代表测试；
- iPad：响应式生态图谱代表测试。

每种设备只执行一项 UI。高频 smoke 不重复执行 Release 双架构审计；该证明保留在 `premerge`（Workbench 相关变更）和 `qualification`。240-cell feed 耐久测试、完整生态故事矩阵和双方向视觉捕获不属于高频门。

### `qualification`：最大资格矩阵

```sh
FOVEA_VERIFY_PROFILE=qualification scripts/verify.sh
```

仅在以下情况执行：

- 发布候选首次形成；
- 产品源码、依赖 pin、工具链或资格门实现发生变化；
- 资格证书缺失或失效；
- 专门调查 sanitizer、mutation、源码回退、视觉或长时 UI 问题。

该 profile 强制执行完整 Workbench、当前组件 clean-copy、production coverage、Release、ThreadSanitizer、AddressSanitizer、iOS 包测试和关键 mutation，调用方不能通过环境变量关闭其中任一项。成功后写入：

```text
.artifacts/verification/qualification-certificate.json
```

证书绑定完整工作树 tree、Xcode/Swift 版本、`Package.resolved`、组件 pin 和 qualification run ID。八项昂贵证明各自在成功后写入同一 run ID、同一工作树的阶段回执；证书同时绑定这些回执的 SHA-256，缺少、跨运行、跨 tree 或被修改的回执都会拒绝签发或复用。写入器只接受 `qualification` 入口建立的活动上下文，不能在缺少完整阶段回执时独立生成证明。源码内容相同的提交前后可以复用；任一绑定项变化都会失效。

### `release`：发布快速复核

```sh
FOVEA_VERIFY_PROFILE=release scripts/verify.sh
```

发布复核首先验证当前 tree 的 qualification certificate，然后重新执行快速静态门、根测试、CacheLab、loopback、coverage、Release 构建和 Workbench build/unit。它复用的是同一输入上的已通过证明，不复用不同源码或不同工具链上的结果。

## 严谨性边界

1. 未知变更必须升级，不得默认归类为“无需测试”。
2. 资格证据只能在输入指纹完全一致时复用。
3. 端到端 UI 耐久测试验证的是跨层行为和基础设施，不替代单元、模型或状态机证明。
4. 高频门失败立即停止；qualification 的失败不得被较低 profile 覆盖。
5. 每次执行写入 `.artifacts/verification/latest.json`，包括变更分类、实际命令、退出码和逐阶段耗时。
6. 公网实验继续独立执行，不进入确定性高频门。
