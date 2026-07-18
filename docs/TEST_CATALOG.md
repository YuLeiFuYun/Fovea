# Fovea 测试 ID 注册表

> **状态：Proposed。**  
> 测试 ID 是稳定引用。实现文件名、测试框架和目录可以变化，但 ID 的语义不得静默改变；语义变化必须新建 ID，并将旧 ID 标记为 Superseded。

## 1. 命名空间

| 前缀 | 规格 |
|---|---|
| `CACHE-PT` | 缓存、身份、HTTP record、提交与持久化 |
| `AUTH-PT` | 鉴权上下文、Cookie、refresh 与账户切换 |
| `SCHED-PT` | single-flight、优先级、取消与 retry |
| `GEO-PT` | target pixels、布局与动态 resize |
| `UI-PT` | SwiftUI/UI token 与展示状态机 |
| `SOURCE-PT` | File/Data/Asset/Photos/Custom source identity |
| `ERR-PT` | 错误、重试与 fallback |
| `PIPE-PT` | Pipeline configuration 与 registry |
| `RES-PT` | 资源 permit、pressure 与公平性 |
| `GC-PT` | quota、lease、physical GC 与 ENOSPC |
| `DIAG-PT` | diagnostics schema、隐私与背压 |
| `IMG-PT` | orientation、颜色、alpha、HDR 与 attachments |
| `KEY-GV` | 持久键 canonical encoding golden vectors |
| `HTTP-CONF` | 外部 HTTP conformance manifest 用例 |
| `SEC-CASE` | 安全默认矩阵案例 |
| `AIQA-GATE` | AI agent 权限、证据、独立验收和发布治理 |
| `AIQA-MUT` | Fovea 关键不变量变异体 |
| `COMP-EVIDENCE` | 竞品契约的机器可汇总证据记录 |

## 2. Phase 0a 产品测试与 AIQA 分级

0a 只要求最小垂直切片的 blocker tests：

```text
KEY-GV-001      FetchVariantKey canonical bytes 稳定
CACHE-PT-003    账户 namespace 不串号
CACHE-PT-006    fresh record 不访问网络
CACHE-PT-008    304 复用 ContentID
CACHE-PT-010    incomplete 200 不生成 ContentID
CACHE-PT-015    revoked generation 不提交
CACHE-PT-017    持久 key golden vector
CACHE-PT-026    no-store 只允许 in-flight task cohort
CACHE-PT-029    Probe 失败时 OriginalEncoded 不可见
SCHED-PT-004    最后订阅者只取消一次
SCHED-PT-010    完成/取消/错误不 double-complete
GEO-PT-002      0x0 不触发原尺寸 decode
UI-PT-001       迟到结果不覆盖新 identity
AUTH-PT-001     token refresh 的 variant/execution key 分离
AUTH-PT-003     账户切换隔离
AUTH-PT-006     凭证不进入 key/log/trace
ERR-PT-001      cache write 失败不覆盖 final
AUTH-PT-010     public URL 不需要 auth provider/credential generation
CACHE-PT-031    ContentID 不得作为物理文件名
GC-PT-005       PhysicalBlobID 不泄漏 ContentID
GC-PT-011       0a soft cap 触发保守清理且不阻塞 final
SEC-CASE-014    认证响应只写入专属 namespace
SEC-CASE-015    相同 ContentID 跨 namespace 不共享物理 blob
SEC-CASE-016    登出撤销任务并清除 record/blob，晚到 commit 不复活
SEC-CASE-017    跨 origin redirect 剥离 Authorization/Cookie/API key
SEC-CASE-018    diagnostics 不含 token、Cookie 或稳定账户标识
```

0a-bootstrap 报告列出当时已执行项；0a-complete 报告必须列出全部产品 ID、结果、实现测试路径和 verified commit。

AI 主导实现分两级：

```text
0a-bootstrap（最多前 1–3 个 PR）
  AIQA-GATE-001...006
  AIQA-GATE-008
  AIQA-GATE-010
  AIQA-GATE-007/009 可 scaffolded，不得伪报 pass

0a-complete
  AIQA-GATE-001...010
  AIQA-MUT-001       namespace 不得从持久/请求身份消失
  AIQA-MUT-002       精确 fetch 不得错误按 FetchVariantKey 合并
  AIQA-MUT-007       no-store 不得进入 reusable cache
  AIQA-MUT-008       revoke 后不得 Commit
  AIQA-MUT-009       unknown target 不得原尺寸 decode
  AIQA-MUT-015       Probe reject 后不得发布 OriginalEncoded
```

只有 `0a-complete` 才算 Phase 0a 通过。定义与执行规则见 `specifications/ai-development-assurance.md`。

Phase 0a curated mutant 的可执行入口为 `scripts/run-critical-mutants.py`；报告 schema 为 `schemas/critical-mutation-report.schema.json`。

## 3. Phase 0b / G0

0b 只要求与存在性门禁直接相关的测试，不把后续能力重新塞回首个正式门禁。

### 0b required

```text
KEY-GV-001
CACHE-PT-001...010
CACHE-PT-013...015
CACHE-PT-017...019
CACHE-PT-021
CACHE-PT-023
CACHE-PT-025...031
AUTH-PT-001...010
SCHED-PT-001...010
GEO-PT-001...008
UI-PT-001...014
ERR-PT-001...014
PIPE-PT-001...008
IMG-PT-001...003
IMG-PT-006...008
```

此外：

- Private Image Cache Profile 中分类为 `required` 的 `HTTP-CONF-*` 全部通过；
- 安全矩阵中 Gate 为 `0a` 或 `0b` 的 `SEC-CASE-*` 全部通过；
- W1/W2/W3 对应的 benchmark/assertion 全部通过；
- `AIQA-GATE-001...010`、`AIQA-MUT-001...016` 全部通过，并有 R3 独立 oracle/evidence。

### 不阻塞 0b

以下测试仍须保留，但在对应能力进入 Core v1/Phase 2 时才升级为门禁：

```text
CACHE-PT-011      206 Range 完整拼接
CACHE-PT-016      Analysis 模型/revision 失效
CACHE-PT-020      多 record blob 引用回收
CACHE-PT-022      non-identity Content-Encoding Range
CACHE-PT-024      multi-process writer fail-closed
CACHE-PT-032...035 quota/lease/atime/GC degradation
SCHED-PT-011...012 permit/fairness
RES-PT-*          完整资源治理
GC-PT-*           完整 quota/GC
DIAG-PT-*         完整 diagnostics contract
IMG-PT-004...005  HDR tone-map / gain-map
IMG-PT-009...010  HDR fallback 与跨系统扩展验证
```

推迟门禁不等于删除测试；它只防止未进入当前产品范围的能力阻塞 0b。

## 4. 外部测试 ID

外部 corpus 的稳定 ID 不直接复用 upstream 文件路径。manifest 使用：

```text
HTTP-CONF-RFC9111-<section>-<sequence>
HTTP-CONF-WPT-<upstream-test-id>
HTTP-CONF-CACHE-TESTS-<upstream-test-id>
```

manifest 还必须记录 upstream commit、license、适用性分类、预期结果和 adaptation notes。

## 5. 维护规则

- 不能通过重排文档列表改变测试 ID；
- 修复测试实现但语义不变时保留 ID；
- 扩大或改变断言语义时创建新 ID；
- 删除测试必须通过 ADR，并在毕业矩阵中说明替代项；
- 一个测试可以覆盖多个 ID，但报告必须逐 ID 给出结果；
- 一个 ID 可以在 unit/property/integration/fuzz 多层实现，最终结果取最严格门禁。
