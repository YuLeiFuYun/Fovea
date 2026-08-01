# 竞品差异与验收契约

> **状态：Active Phase 0b comparison contract。**
> 本文避免把竞品已有能力包装成创新。精确版本由 `research/comparator-lock.json` 固定，行为必须由 Comparative Lab adapter 与可重现工件核实；“未知”不得写成“没有”。

## 当前精确对照基线

| 项目 | 版本 | 完整提交 | Phase 0b 角色 | 当前执行状态 |
|---|---:|---|---|---|
| Fovea | 当前工作树 | runner 注入 HEAD + tree digest + dirty 状态 | 待判定实现 | adapter 严格编译通过 |
| Nuke | 13.0.6 | `63a8fcbd6621340a2410bc3e9575ac97058615f4` | required | adapter 严格编译通过 |
| Kingfisher | 8.11.0 | `410984bf301f4fa224fe56277b3f8672cc465c79` | required | adapter 编译通过；Xcode 27/macOS 27 下存在固定上游警告 |
| SDWebImage | 5.21.7 | `2de3a496eaf6df9a1312862adcfd54acd73c39c0` | required | adapter 编译通过；原生测试失败与工具链/外部依赖分类保留 |
| AlamofireImage | 4.4.0 | `4cf73d601c482b7d77bae47de3ef1b8bcf328ec1` | required | adapter 编译通过；SwiftPM 原生测试结果单独分类 |

上游源码只进入 `.artifacts/comparators/sources`，不进入 Fovea 生产依赖图。Fovea dirty tree 必须同时记录 tree digest；只记录 HEAD 的工件无效。Kingfisher 当前上游警告包括旧 UTI 常量和 Swift 6 捕获诊断，它们是工具链兼容信号，不自动构成性能或正确性优劣证据，也不得通过修改固定上游源码隐藏。

统一协议与适配器位于 `Benchmarks/ComparativeLab`。五个隔离 App 已绑定统一协议：Fovea、Nuke、Kingfisher、SDWebImage 与 AlamofireImage。当前还只允许声明 adapter、真实 W2 correctness probe 和 Simulator 功能校准；正式 W1/W2/W3、多重复真机统计与稳定系统复制仍未完成。

## 比较本体、可比性与声明门

`specifications/comparison-ontology.md` 将对象分为平台基线、客户端管线、可迁移机制、缓存系统、codec engine、算法模拟器和相邻系统。`specifications/comparability-contract.md` 要求在排序前比较十一项语义维度，并按 D0-D5 区分磁盘持久化。

正式汇总禁止加权总分，只允许输出 `empirically-superior`、`empirically-equivalent`、`empirically-noninferior`、`inferior`、`inconclusive`、`not-comparable`、`capability-gap` 等受控状态。并列必须通过预注册 delta 的 TOST；`p > 0.05` 不能解释为等价。机器策略位于 `../Benchmarks/claim-policy.json`，门禁入口为 `scripts/check-comparison-governance.py`。

Apple URLSession + URLCache + ImageIO、AsyncImage 与 PINRemoteImage 已登记为下一批直接对手，但在完成源码/系统身份绑定和统一 adapter 前不具备声明资格。Glide、Coil、Fresco、Picasso、Caffeine、Moka、CacheLib、libvips 等只按注册角色贡献 challenge、算法 trace 或组件研究。

## 原则

- pipeline、缓存、取消、progressive、prefetch 和 task coalescing 是入场能力；
- Fovea 的主张必须绑定 workload、正确性 profile 和指标；
- 只比较相同功能、相同目标像素和相同缓存状态；
- 竞品允许使用其推荐配置，不人为设置劣势；
- HTTP 比较区分“系统 URLCache/native cache”“库自有缓存”和“Fovea Private Image Cache Profile”；
- 无法等价配置时报告语义差异，不把缺失配置伪装成性能胜利。

## 当前对照矩阵

| Contract ID | 契约 | Nuke 当前公开能力 | Kingfisher 当前公开能力 | Fovea 要证明的增量 | 门禁 |
|---|---|---|---|---|---|
| COMP-CONTRACT-SHARING-001 | task/stage coalescing | 已公开支持 task coalescing、阶段复用和优先级传播 | 已公开支持可取消下载和复用已下载内容；具体阶段粒度由 adapter 核实 | 不是差异点；FetchExecutionKey 避免凭证/签名 URL 错误合并；有效优先级随订阅者集合重算 | W1 + Scheduler suite |
| COMP-CONTRACT-TARGET-001 | target-size/downsample | 支持 processing/downsample 路径；默认路径行为由 adapter 测量 | 提供 DownsamplingImageProcessor | 目标像素成为默认不变量；未知 target 不把全尺寸结果写 RenderedMemory | W2 |
| COMP-CONTRACT-HTTP-001 | HTTP cache/validator | 支持 native HTTP cache、Range 和 validators；具体行为由 adapter/property test 核实 | 自有 cache FAQ 明确不直接支持 ETag/Last-Modified；URLSession/URLCache 行为需分开测 | 版本化 Private Image Cache Profile，显式 freshness/Age/Vary/304，并通过外部 conformance corpus | G0 HTTP profile |
| COMP-CONTRACT-AUTH-001 | auth namespace/logout/no-store | 不作静态断言，Phase 0b 核实可配置方式 | 可加 auth header，但 namespace 清理保证需核实 | 跨账户泄漏为零；NamespaceGeneration 阻止清理后在途任务重新提交；no-store 不满足新请求 | W3 |
| COMP-CONTRACT-CANCEL-001 | cancel waste | 支持 cancellation/coalescing/range resume | 支持 cancelable downloading | 将取消后字节、CPU、解码时间作为一等指标并设门限；共享优先级可降级 | W1 |
| COMP-CONTRACT-SECURITY-001 | security limits | 不作静态断言，按版本核实 | 不作静态断言，按版本核实 | DecodeLimits、默认拒绝矩阵和 codec fuzz 进入 Core v1 gate | Security suite |
| COMP-CONTRACT-DURABILITY-001 | cache durability | 不作静态断言，按实际缓存后端核实 | 不作静态断言，按实际缓存后端核实 | 持久 key canonical encoding、StoreGeneration、惰性迁移与 crash matrix | G0 |
| COMP-CONTRACT-BENCHMARK-001 | reproducible benchmark | 各项目有性能主张与测试 | 各项目有测试和性能建议 | 公开 harness、raw trace、CI、置信区间和 provisional gate | G0/W1-W3 |

## 资料入口

- Nuke: https://kean.blog/nuke/home
- Nuke coalescing design: https://kean.blog/post/nuke-9
- Kingfisher: https://github.com/onevcat/Kingfisher
- Kingfisher FAQ: https://github.com/onevcat/Kingfisher/wiki/FAQ
- SDWebImage: https://github.com/SDWebImage/SDWebImage
- RFC 9111: https://www.rfc-editor.org/rfc/rfc9111.html
- Web Platform Tests HTTP cache: https://github.com/web-platform-tests/wpt/tree/master/fetch/http-cache
- HTTP cache tests: https://cache-tests.fyi/


## Adapter 结论词汇

```text
supported       可由推荐或明确配置表达，且测试通过
unsupported     当前版本没有可表达路径
failed          可配置但实际测试失败
incomparable    无法以同一方法可靠测量该指标
unknown         尚未完成核实，不得作为差异证据
app-composed    需要应用自行组合额外组件或生命周期约束
```

Correctness Path 的差异必须在预注册的全部相关对照中成立；不能选择一个较弱 adapter 过门。`app-composed` 只有在 Fovea 提供内建、默认且不可绕过的保证，而竞品确需应用额外拼装时，才可作为差异证据。

## Path B 机器可汇总证据

Correctness Path 的每个主张必须为每个预注册相关竞品生成一条 JSON 记录，并通过 `schemas/competitive-contract-evidence.schema.json`。模板见 `templates/COMPETITIVE_CONTRACT_EVIDENCE.json`。记录至少包含：

```text
contractID / claim
competitor + exact version/commit
adapter version and configuration
result: supported | unsupported | failed | app-composed | incomparable | unknown
test IDs and reproduction locator
raw evidence digest
evidence date and accountable reviewer
coverage gaps
```

`unsupported`、`failed`、`app-composed` 没有可重现 test/artifact 和 digest 时不能作为 Path B 证据。汇总器必须拒绝缺少任一相关竞品记录、使用 `unknown` 证明差异或重复使用过期版本证据。

## Phase 0b adapter 输出

当前实现路径：`Benchmarks/ComparativeLab/Sources/ComparativeLabCore`、五个 adapter package 与 `Benchmarks/ComparativeLab/Apps`。精确对象分类见 `research/comparator-registry.json`；没有源码锁与 adapter 的研究对象不得进入端到端排名。

每个竞品 adapter 必须记录：

```text
library version / commit
configuration
cache backend and policy
target-size request expression
cancellation mechanism
shared-task priority behavior
HTTP/URLCache configuration
binary flags and compiler optimization
unsupported metric or semantic gap
```

HTTP 对照还要记录：

```text
是否使用 URLCache
Vary/validator/304 的实际行为
auth/private/no-store 行为
Range/resume 行为
外部 profile tests 哪些可适用
```

无法等价配置时，报告差异，不伪造“公平数值”。
