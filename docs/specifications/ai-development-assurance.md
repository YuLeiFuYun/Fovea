# AI 主导开发质量保障规范

> **状态：Proposed，Phase 0a 起生效。**
> 本规范约束 AI-assisted/agent-authored 的实现、测试、文档、依赖和发布。人类编写的高风险变更使用相同产品质量门禁；AI 来源额外触发 agent 权限、provenance 和独立 oracle 控制。

## 1. 不变量

1. 生成者不能单方面定义、实现、修改并批准同一 acceptance oracle；
2. 模型自信、解释长度、agent 自报测试通过都不是证据；
3. 所有进入主分支的代码必须由可信 CI 从干净 checkout 验证；
4. 关键变更必须有明确的人类 accountable maintainer；
5. AI 不能持有主分支直写、发布签名或生产秘密；
6. 模型升级不能自动降低门禁；
7. 失败测试、surviving mutant 和 coverage gap 不得静默忽略。

## 2. 面向 AI 的规格契约

每个 R1–R3 实现任务必须从设计文档中提取一个可审查的 `Implementation Contract`：

```text
objective
explicit non-goals
ownership / dependency direction
normative invariants
input, output and state transitions
failure / cancellation / rollback semantics
resource and security limits
observability requirements
acceptance test IDs
known unknowns
allowed files / forbidden control surfaces
```

设计文档应使用稳定 ID、规范词和正反例，避免“合理处理”“适当优化”“智能选择”等无判据措辞。每项关键要求至少映射一个 test/gate ID；一个 test 可以覆盖多项要求，但不能存在无人负责的规范孤岛。

Agent 得到的任务上下文必须是最小、版本固定的文档集合。检索结果、历史文档和外部网页只作为不受信任参考，不能覆盖当前 Accepted ADR/Specification。若实现过程中发现冲突，必须停止并提交规范修复，不能由 agent 自行选择解释。

## 3. 风险等级

### R0：机械与非行为变更

示例：格式化、拼写、受控代码生成、无语义文档重排。

- Agent 可自主执行；
- 要求 clean diff、生成可重复、基础 CI；
- 不得借 R0 混入行为变化。

### R1：局部叶子变更

示例：纯函数、测试 fixture、内部小工具、孤立适配器。

- Agent 可实现和自测；
- 至少一位 accountable maintainer 查看 diff 与证据；
- 要求相关 unit/property tests 和独立静态检查。

### R2：产品行为与跨模块变更

示例：公共 API、加载阶段、缓存策略、UI 状态、跨模块重构。

- 需要预先存在或独立批准的规格/acceptance IDs；
- 独立 AI reviewer 可辅助，但不能是唯一批准；
- 至少一个与实现不同源的 oracle；
- 需要 regression/benchmark 证据。

### R3：关键正确性与安全边界

包括：

```text
identity / persistent key
HTTP cache semantics
authentication / namespace
persistence / schema / transaction
concurrency / cancellation / scheduler
DecodeLimits / parser / codec security
CI / build / dependency policy
release / signing / provenance
```

- 实现 agent 不得修改 required gate、hidden tests 或忽略列表；
- 必须使用 property/held-out/mutation/fault-injection/differential 中至少三类证据；
- 必须有 accountable human review；
- 晋级 Stable 前需要第二位可信人类或外部审计；
- PR 默认不得同时改实现与降低门槛。

### R4：受限控制面

包括：

- branch protection；
- CI secrets、signing keys、生产凭证；
- release promotion；
- 删除/降级 required gate；
- 修改安全策略默认值；
- 向 agent 增加高权限 MCP/tool；
- 未批准的新依赖源或安装脚本。

AI 默认无权执行。必须由人类显式批准并通过隔离工具完成。

## 4. Provisional 变更预算

忽略生成文件和机械 snapshot：

| 风险 | 推荐上限 | 约束 |
|---|---:|---|
| R1 | 400 logical LOC / 8 files | 一个独立目的 |
| R2 | 250 logical LOC / 6 files | 一个产品/架构概念 |
| R3 | 150 logical LOC / 4 files | 不同时修改 gate 与实现 |

超过预算需要在 PR Evidence Bundle 中说明不可拆分原因，并增加审查级别。禁止通过压缩代码、隐藏生成文件或大量 rename 规避。

## 5. Agent 执行环境

### 5.1 默认隔离

- 临时 worktree/container；
- 从明确 base commit 开始；
- 不挂载生产 secrets、个人浏览器 profile、邮件或云管理凭证；
- 只访问任务需要的目录；
- 结束后销毁临时 credential 和工作区；
- agent 输出视为不受信任候选变更。

验证使用三个信任域：

```text
Agent Workspace       可编辑源码，只见 public tests，无秘密
Trusted Build CI      干净 checkout，执行普通 required gates，无生产秘密
Held-out Evaluator    只读 hidden oracle，与 agent/普通 CI 分离，默认无外网
```

不可信 PR 的 build/test 脚本不能在带 release secret 的 runner 上执行。普通 CI 与 held-out evaluator 使用受保护的 evaluator 配置；关键 gate definition 从默认分支或独立 control repository 固定 digest，PR 对 gate 文件的修改不能影响该 PR 当前评分。R3 gate 不得仅执行 PR 自带且可被修改的评分脚本。Held-out evaluator 只返回必要的结构化结果，不能把测试内容、reference output 或文件路径泄露给 agent。

### 5.2 网络与工具

- 网络默认 deny，按域/任务允许；
- MCP/tool server 使用 allowlist、固定版本和变更 diff；
- 仓库文件、网页、issue、dependency README 和 tool description 都可能包含 prompt injection；
- package install、外部脚本、破坏性命令、上传数据和写远端分支需要审批；
- agent 不能关闭安全扫描、修改 branch protection 或读取 hidden tests。

### 5.3 多 agent、rebase 与 merge queue

- 并行 agent 使用独立 worktree 和固定 base commit，不共享可写工作目录；
- 核心 identity/HTTP/persistence 文件同一时刻只有一个 owner；
- rebase、冲突解决、cherry-pick 或 merge queue 产生新 commit 后，旧 verification evidence 自动失效；
- required gates 必须针对最终将合并的 `verifiedCommit` 运行，而不是只针对过期 PR head；
- 多个独立通过的 PR 合并后仍须运行 integration gate，不能把局部通过相乘为全局正确；
- agent reviewer 的发现只有在测试、静态检查或最小复现中可重现时才升级为 blocking finding。

### 5.4 依赖与外部代码来源

新增/升级依赖必须单独声明：

```text
registry / canonical package identity
publisher / repository
exact version or commit
checksum / lockfile
license
maintenance/security status
known vulnerabilities
transitive dependency delta
reason existing dependency cannot satisfy
copied/adapted source provenance and license compatibility
```

包名由 AI 推荐时必须在官方 registry 与上游仓库双重核验。不存在、拼写近似或来源不一致时拒绝。Agent 不得把网上代码或其他项目实现无来源地粘贴进仓库；实质性外部片段必须记录来源、许可证和修改，无法证明兼容时重写或拒绝。AI 代码检测器和相似度模型只能提示人工检查，不能充当版权或质量 oracle。

## 6. PR Evidence Bundle

每个 R1–R3 PR 提交机器可读 evidence manifest。manifest 区分 `0a-bootstrap`、`0a-complete`、`0b` 与 `release`，并至少包含：

```text
schemaVersion
changeID / baseCommit / headCommit / verifiedCommit
assuranceStage / taskContextFingerprint
riskClass
issue / ADR / specification / test IDs
model and agent tool versions
agent configuration fingerprint
allowed tools and network domains
human accountable owner
changed files and logical diff size
commands executed
tests / fuzz / benchmark / static analysis results
held-out result locator
mutation result locator
evidence producer / immutable digest
dependency changes
known assumptions / unproven items
rollback plan
review and approval records
```

禁止记录 raw token、Cookie、私有 prompt secrets 或完整敏感会话。需要调试时保存脱敏摘要和不可逆 fingerprint。`taskContextFingerprint` 是规范 commit、Implementation Contract、脱敏任务文本与 agent 配置的规范化摘要，不包含 secret。Agent 自报的命令或测试结果只能标记为 `agent-declared`，不能满足 required gate；`trusted-ci`、`held-out-evaluator`、`human-reviewer` 或 `release-builder` 才能生成相应可信证明。Evidence locator 必须绑定 immutable digest 或受保护 CI run。Evidence Bundle 使用 `docs/schemas/ai-pr-evidence-bundle.schema.json` 校验；人类签署使用 `docs/templates/AI_CHANGE_REVIEW.md`。

## 7. 验收 oracle 分离

### 7.1 可见测试

Agent 可以读取并运行：

- unit tests；
- format/lint/type checks；
- 公共 property tests；
- 公共 regression fixtures。

它们主要支持开发反馈，不能单独证明 R2/R3 完成。

### 7.2 受保护证据

R2/R3 至少使用一类，R3 至少使用三类：

- held-out tests；
- 旋转 hidden scenarios；
- reference implementation/differential tests；
- metamorphic/property sequence tests；
- curated critical mutants；
- fault injection/crash matrix；
- fuzz/sanitizer corpus；
- controlled benchmark/non-inferiority gate；
- executable reference state model / model checking（适用于 revoke/commit、record/blob transaction、subscriber/cancel 等有限状态协议）。

受保护 oracle 由可信 CI 或独立 verifier 管理，agent 工作区不能写入。不同模型、不同提示或第二个 agent 只构成辅助多样性，不自动构成独立 oracle；R3 至少有一个基于独立规格、reference model、held-out corpus 或人工裁决的验证面。

### 7.3 Gate 变更

- required test/gate 的新增可以与功能 PR 并行，但批准权独立；
- 删除、放宽、skip 或改变 expected result 属于 R4；
- 测试失败不能通过重录 snapshot 或扩大 tolerance 自动解决；
- flaky test 先隔离根因，不能无期限 retry 到绿。

## 8. Fovea 关键变异体目录

以下 mutant 必须在对应模块进入 Phase 0b/Stable 前被测试杀死：

| ID | 人为错误 |
|---|---|
| **AIQA-MUT-001** | 从 FetchVariantKey 删除 SecurityNamespaceID |
| **AIQA-MUT-002** | 使用 FetchVariantKey 而非 FetchExecutionKey 合并精确网络任务 |
| **AIQA-MUT-003** | token refresh 不改变 CredentialGeneration |
| **AIQA-MUT-004** | 把 stale record 当 fresh |
| **AIQA-MUT-005** | 304 创建新的 ContentID/blob |
| **AIQA-MUT-006** | `Vary` mismatch 仍命中 |
| **AIQA-MUT-007** | `no-store` 写入 RenderedMemory 或磁盘 |
| **AIQA-MUT-008** | namespace revoke 后仍允许 Commit |
| **AIQA-MUT-009** | unknown target 静默原尺寸 decode |
| **AIQA-MUT-010** | target-size path 先产生全尺寸位图 |
| **AIQA-MUT-011** | subscriber 离开后不重算最大优先级 |
| **AIQA-MUT-012** | cancel/complete 竞态 double resume |
| **AIQA-MUT-013** | 使用 Swift Hasher 生成持久 key |
| **AIQA-MUT-014** | 过度规范化 signed/query URL 导致错误共享 |
| **AIQA-MUT-015** | Probe/security reject 后仍发布 OriginalEncoded record |
| **AIQA-MUT-016** | cache write/diagnostics 失败覆盖成功 final |
| **AIQA-MUT-017** | revoke 后的新 200 record 错写为旧 NamespaceGeneration |
| **AIQA-MUT-018** | revoke 清理后晚到的 304 metadata refresh 重新写回旧 record |
| **AIQA-MUT-019** | generation revoke 后不回滚已发布 record |
| **AIQA-MUT-020** | transient geometry 进入 RenderedMemory |
| **AIQA-MUT-021** | 禁用编码容器 metadata 字节上限 |
| **AIQA-MUT-022** | 每个订阅者创建独立 DecodeKey registry，破坏解码 single-flight |
| **AIQA-MUT-023** | 304 同 variant 刷新取消后删除 metadata，而不是恢复旧快照 |
| **AIQA-MUT-024** | 内存缓存先执行可能溢出的成本加法，再尝试淘汰 |
| **AIQA-MUT-025** | 接受语义损坏的 OriginalEncoded manifest |
| **AIQA-MUT-026** | 接受语义损坏的 representation manifest |
| **AIQA-MUT-027** | 运行期接受非法 representation record |
| **AIQA-MUT-028** | 忽略畸形或冲突的 Content-Length |
| **AIQA-MUT-029** | 运行期接受非规范 ContentID 字符串 |
| **AIQA-MUT-030** | 接受硬链接的受管文件或锁 inode |
| **AIQA-MUT-031** | 将符号链接错误接受为受管目录 |
| **AIQA-MUT-032** | 在校验 `st_size` 上限前分配 metadata 文件 |
| **AIQA-MUT-033** | wall clock 回拨时拒绝有限且可保守处理的 record |
| **AIQA-MUT-034** | 从 exact execution identity 删除请求网络权限 |
| **AIQA-MUT-035** | 在缓存/网络访问前绕过 Profile ACL |
| **AIQA-MUT-036** | credential refresh 重置非凭证请求语义 |
| **AIQA-MUT-037** | 用一字节许可替代 decode working-set reservation |
| **AIQA-MUT-038** | 在 transport 完成前丢弃 URLSession 事务摘要 |
| **AIQA-MUT-039** | 等待 working-set 容量时继续占有 decode-count permit |
| **AIQA-MUT-040** | 接受远程明文 HTTP 图片 URL |
| **AIQA-MUT-041** | 允许 HTTPS redirect 降级到远程明文 HTTP |
| **AIQA-MUT-042** | 从 full configuration fingerprint 删除 decode working-set 预算 |
| **AIQA-MUT-043** | 官方系统组合根默认放开全部 profile |
| **AIQA-MUT-044** | 已完成共享任务在 registry 清理前发布结果 |
| **AIQA-MUT-045** | retry backoff 取消时遗漏 correlated fetch cancellation 终止事件 |
| **AIQA-MUT-046** | 保留 URLSession 环境 credential storage |
| **AIQA-MUT-047** | handoff lease 到期后仍保留零订阅者共享任务 |
| **AIQA-MUT-048** | 严格代理策略接受缺失指标或代理 transaction |
| **AIQA-MUT-049** | 删除 namespace identity 字节上限 |
| **AIQA-MUT-050** | namespace generation 从 `UInt64.max` 回绕到零 |
| **AIQA-MUT-051** | 初始 URLSession task 绕过 destination policy |
| **AIQA-MUT-052** | redirect 绕过精确 origin allowlist |
| **AIQA-MUT-053** | 缓存访问前绕过 destination policy |
| **AIQA-MUT-054** | transport identity 删除 destination policy fingerprint |
| **AIQA-MUT-055** | namespace registry 到达容量后仍接纳新的高基数 identity |
| **AIQA-MUT-056** | 进程 registry 强引用 store actor 与 writer lease，导致生命周期泄漏 |
| **AIQA-MUT-057** | 生产默认启用按 key 的高基数 cancellation 计数 |
| **AIQA-MUT-058** | signpost 活动区间按 stage 分别限额而非使用全局上限 |
| **AIQA-MUT-059** | remembered credential scope 超出上限后不淘汰 |
| **AIQA-MUT-060** | transport redirect metrics 在进入结构化 diagnostics 前丢失 |
| **AIQA-MUT-061** | 暂时性 blob I/O 故障被误判为内容损坏并触发删除 |
| **AIQA-MUT-062** | 已释放的弱 registry 元数据在高基数 cache root 下永久累积 |
| **AIQA-MUT-063** | 已取消调用者仍消费 remembered credential 并执行认证重放 |
| **AIQA-MUT-064** | namespace 请求绕过正在执行的 revoke cleanup barrier |
| **AIQA-MUT-065** | 内存压力 monitor 随临时组合根 wrapper 释放 |
| **AIQA-MUT-066** | diagnostics reason 接受自由文本 |
| **AIQA-MUT-067** | 内存清理把 item count 当作释放字节数 |
| **AIQA-MUT-068** | 接受未知序列化 diagnostics schema |
| **AIQA-MUT-069** | diagnostics drop count 写入 byteCount |

新增关键不变量时必须同步新增 mutant、活动规格 ID 和 traceability evidence。通过大量无关 mutant 获得高 mutation percentage 不能替代上述目录全部被杀死。

### 8.1 Phase 0a curated mutant runner

当前 curated required mutants `001...102` 由 `scripts/run-critical-mutants.py` 在隔离 Git worktree 中执行。每个 mutant 绑定一个明确产品测试；只有测试实际开始执行并转红才记为 `killed`。编译失败、超时或 mutation pattern 失配记为 `invalid`，不能冒充有效击杀。每个结果完成后都会原子写入 tree-bound checkpoint；`--resume` 只复用 commit/tree 一致、状态为 killed 且日志 SHA-256 匹配的结果。报告写入 `.artifacts/mutation/critical-mutants.json`，结构由 `docs/schemas/critical-mutation-report.schema.json` 固定，并由零依赖的 `scripts/validate-critical-mutation-report.py` 复核 commit、实际工作树 tree hash、是否包含未提交修改、Xcode/Swift 版本、结果集合、日志存在性和 SHA-256。本地 dirty workspace 会先被快照到隔离 worktree；可信 CI 只接受 `includesWorkingTreeChanges == false` 且 tree hash 等于 `HEAD^{tree}` 的报告。除组件 checkout 外，runner 允许把 mutant 的测试根显式绑定到仓库内独立 Swift package；该根仍必须位于同一 tree-bound snapshot 内。

该 runner 是 visible oracle，仍不能替代 protected CI、held-out evaluator 或 human attestation。

## 9. Human Comprehension Attestation

R2/R3 的 accountable maintainer 在合并前签署：

```text
我能解释本次变更保护的系统不变量；
我能描述主要失败、取消、竞态和回滚路径；
我确认没有引入第二套身份/状态源；
我知道哪些测试 oracle 与实现独立；
我检查了依赖、权限和敏感数据影响；
我能指出尚未证明的内容；
我能够在 AI 工具不可用时定位和回滚该变更。
```

AI 生成的说明可辅助阅读，但不能代替签署。若维护者无法完成，该 PR 继续拆分或退回。

## 10. Review 模式

### 10.1 双人团队

R3：实现者/agent owner 与独立 reviewer 分离。Stable release 使用 CODEOWNERS/branch protection 强制。

### 10.2 单人维护者

0.x 允许：

1. agent A 实现；
2. 独立模型/agent B 在不同上下文进行 adversarial review；
3. trusted CI 运行 held-out/mutation/fuzz；
4. 人类维护者完成 comprehension attestation；
5. 至少隔一个工作会话进行延迟复审；
6. 标记 `single-maintainer reviewed`。

此模式不满足 human two-party review。R3 契约进入 Stable/1.0 前必须获得第二人或外部审计。

## 11. 通用 PR 验收

所有 R1–R3 PR：

- issue/spec/test IDs 完整；
- clean checkout 可构建；
- zero compiler warning；
- Swift 6 strict concurrency；
- format/lint/SAST/secrets/dependency checks 通过；
- 相关测试通过且无新增未裁决 flake；
- 公共 API、错误、迁移和文档同步；
- 无未批准依赖、脚本和权限；
- evidence bundle 完整；
- rollback 可执行；
- accountable maintainer 签署。

R2/R3 额外要求独立 oracle；R3 使用 §7.2 的至少三类证据和对应 critical mutants。

## 12. 发布验收

发布候选必须：

- 所有 required `TEST_CATALOG` 和 `AIQA-GATE` 通过；
- 无 P0/P1 未裁决问题；
- required fuzz/sanitizer/benchmark/platform matrix 通过；
- SBOM、license、vulnerability 和 dependency provenance 完整；
- artifact 由 protected CI 从固定 commit 生成；
- release 签名和 SLSA-compatible provenance；
- 至少一次独立 rebuild/source-artifact 对应验证；
- schema/cache rollback 演练；
- release notes 标记 coverage gap 和 `unproven`；
- Stable R3 契约有 human two-party review 或外部审计。

## 13. 模型与工具版本漂移

- 优先记录不可变 model snapshot/version；只有可变 alias 时，同时记录 provider request ID、执行日期和配置 fingerprint；
- 不要求重现完全相同的生成轨迹，要求重现 clean build、测试、benchmark 和产物 provenance；
- provider/model/tool 静默升级导致行为显著变化时，按新的 agent configuration 运行 FoveaAgentEval；
- prompt 或上下文不保存原文时，至少保存脱敏 `taskContextFingerprint` 和所用规范 commit。

## 14. FoveaAgentEval

模型、agent scaffold 或主要工具升级时运行 repo-specific eval：

```text
Frozen Track    固定任务，测趋势
Rotating Track  隐藏/轮换任务，防过拟合和训练污染
Adversarial     prompt injection、依赖幻觉、gate tampering、secret access
Maintenance     在既有 AI 代码上做第二/第三次需求演进
```

评分：

- merge-ready 成功；
- held-out/critical mutant；
- 人工返工分钟；
- 变更规模；
- architecture/spec violations；
- permission/security incidents；
- 成本和完成时间。

不只使用 visible test pass、LOC 或 agent 自报完成率。

## 15. 质量指标

持续记录：

```text
mergeReadyFirstPassRate
humanReworkMinutes
ciFailureByCategory
heldOutGap
criticalMutantSurvival
escapedDefectsBySeverity
revertAndRollbackRate
changeFailureRate
30d/90dPostMergeChurn
reviewQueueTime
specTestTraceability
unapprovedDependencyAttempts
agentPermissionViolations
comprehensionAttestationFailure
```

指标按风险等级和工具版本分层。不得把提交量、AI 生成比例或接受 LOC 作为质量目标。

## 16. Phase 0a AIQA 引导轨

### 16.1 0a-bootstrap（最多前 1–3 个 PR）

允许先合并最小治理脚手架和产品垂直切片。必须真实通过：

- **AIQA-GATE-001**：agent 无生产秘密、无主分支直写；
- **AIQA-GATE-002**：基础 Evidence Bundle 可生成并通过 schema；
- **AIQA-GATE-003**：clean trusted CI 能构建并运行 0a 产品测试；
- **AIQA-GATE-004**：实现 agent 不能修改 protected gate/held-out store；
- **AIQA-GATE-005**：依赖新增默认拒绝且审批可审计；
- **AIQA-GATE-006**：R2/R3 有 human accountable owner；
- **AIQA-GATE-008**：agent/tool/model/base/verified commit 进入 evidence；
- **AIQA-GATE-010**：输出不含 secret 或未脱敏敏感数据；
- **AIQA-GATE-011**：工具超时会终止完整子进程组，不能留下孤立测试/编译进程。
- **AIQA-GATE-012**：统一门禁对全部 Python 工具执行 AST 解析、对 POSIX shell 执行 `sh -n`、解析受管 JSON，并将 `Tools`/`Examples` 纳入严格 swift-format；人工单次检查不能替代持续工具语法门。
- **AIQA-GATE-013**：关键标准、官方文档、论文与竞品实现必须进入机器校验的 provenance manifest，区分 adopted/reference/candidate/deferred；候选研究不得被 README 或实现状态页冒充为已交付能力。
- **AIQA-GATE-014**：长运行验证工具在测试超时以及 runner 自身收到 SIGINT/SIGTERM 时都必须终止当前子进程组并执行 worktree `finally` 清理；只验证内部 timeout 不足以证明不会留下孤立编译或测试进程。

`AIQA-GATE-007` 的 mutation harness 与 `AIQA-GATE-009` 的 rollback harness 可以标记为 `scaffolded`，但不得标记 `pass`。若仓库尚无远程 CI，第一条基础设施提交可由人类在全新本地 checkout 中运行固定 bootstrap 脚本；在第一个产品实现 PR 合并前，必须建立远程 required check 和受保护 control path。bootstrap 不是 Phase 0a 完成，不允许发布、宣称质量门通过或扩大 surface。

### 16.2 0a-complete

宣布 Phase 0a 完成前必须：

- **AIQA-GATE-007**：mutation harness 真实执行指定 critical mutants 并输出可信证明；
- **AIQA-GATE-009**：`scripts/verify-rollback.py` 在隔离 worktree 回滚到 base commit，surface、格式、测试与 Release build 全部恢复，并输出绑定 base/head/log digest 的报告；
- `AIQA-GATE-001...014` 全部通过；
- `AIQA-MUT-001`、`002`、`007`、`008`、`009`、`015` 被真实执行并杀死；
- required evidence 针对最终 `verifiedCommit`，由可信 producer 生成；`trusted-ci` 结果必须绑定持久化 CI run locator，Evidence Bundle 自身不能自证其可信来源；
- rollback 到 base commit 后 clean build 恢复；
- `core-surface.md` 无未经 ADR 批准的越界符号。

Phase 0b 再启用完整 R3 mutant catalog、FoveaAgentEval、供应链和发布门禁。

### 19.1 生产代码覆盖率防回退

- **AIQA-COV-001**：统一门禁必须生成排除 `FoveaTesting` 与生成文件的生产源码覆盖率报告；行/函数/区域覆盖率分别不得低于 85%/85%/78%。覆盖率只作为回退报警，不替代场景追踪、mutation、sanitizer 或 held-out evaluator。

- **DOCS-PT-001**: trusted verification must compile DocC archives for every production module, document 100% of public type/protocol declarations, retain at least 50% source-authored public-symbol documentation coverage and remain within reviewed per-module API budgets, and bind the report and log digest to the verified tree.

## 当前关键变异扩展

当前 required critical mutation catalog 为 `AIQA-MUT-001...102`。082–099 专门覆盖第二次反向复审发现的插件后置条件、严格 HTTP、强制重验证、取消语义、representation 冲突、decoder probe、retry sleeper、owner 析构、OSLog 回绕、staging 所有权、metadata fail-closed、统一注销与 GC 证据；100–102 继续覆盖 durable namespace generation、auth-like custom header 与 comparator telemetry/request-identity 对称性。新增定义必须通过全 catalog anchor 预检；无法应用的 mutant 视为治理漂移而不是 killed。
