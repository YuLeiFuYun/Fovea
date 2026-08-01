# Fovea 世界级工程审查（2026-07）

> **状态：Research / current implementation assessment。** 本文评价当前实现，不构成“世界最好”认证或稳定 API 承诺。

## 结论

Fovea 的缓存身份、namespace 撤销、持久发布、并发 single-flight、目标像素解码、网络目的地约束与安全失败边界已经达到较高工程质量；但项目整体仍不能称为“世界最好”。成熟度、生态、格式覆盖、真机性能、长期真实应用验证和独立审计仍存在明确缺口。持久键已有固定 golden vectors 与双架构 CI lane，但每个提交仍必须等待对应远端 run 才能形成证据。

当前保证阶段保持 `0b-in-progress`。

## 分项判断

| 领域 | 当前判断 | 主要依据 | 未达到世界级认证的原因 |
|---|---|---|---|
| 架构与边界 | 强 | 固定职责 coordinator、分层 package、typed seam、无通用 service locator | API 稳定性与真实应用演化尚未证明 |
| 耦合 | 较低 | Core 不依赖 UI；HTTP、持久化、解码边界清楚 | composition root 与平台示例仍年轻 |
| 状态管理 | 强 | actor、不可变 request/config、namespace generation、display identity 栅栏 | 尚无长期复杂宿主状态压力证据 |
| 错误处理 | 强 | 结构化 category/stage/disposition/reason；fail closed；rollback/cleanup 证据 | 部分 best-effort 物理清理依赖后续 GC 收敛 |
| Swift 风格 | 强 | Swift 6 strict concurrency、package implementation API、显式 `@concurrent` 边界；生产模块无并发逃逸，示例仅保留一个经锁保护且被精确 allowlist 约束的 `URLProtocol` 兼容桥 | 尚未经过广泛外部 API review；Foundation 旧协议兼容桥仍依赖人工不变量 |
| 扩展机制 | 克制 | transport/decoder/transformer/diagnostics/ACL/credential typed seam | 无通用 middleware；这是有意取舍，不是功能等价 |
| 网络与代理 | 强边界、有限范围 | URLSession ambient state 清除；系统路由默认；代理 metrics fail-closed；精确 origin policy 同时覆盖缓存前、初始请求和 redirect | 无 IP/CIDR egress、DNS rebinding 防护、Network Extension、企业代理/HTTP3 真机矩阵 |
| 生命周期 | 较强 | subscriber cancellation、UI identity、memory pressure、writer lease、有界 refresh handoff、测试子进程组清理 | 无后台 URLSession、跨进程全局生命周期控制和长期 App 状态迁移数据 |
| 资源治理 | 较强 | fetch/decode hard cap、weighted working-set、memory cost、body limit、queue limit | 无 CPU 时间、能耗、thermal 动态预算和 namespace 加权公平 |
| Profile ACL | 有界且明确 | 精确 namespace/auth-context allowlist；public-only 默认；可组合精确 origin policy并在缓存前拒绝 | 不是 RBAC/ABAC/entitlement 引擎，不推断业务角色或 IP 级网络拓扑 |
| 日志与可观测性 | 较强 | 有界异步 sink、脱敏 reason、URLSession transaction summary、OSLog/Signpost exporter 与一致采样 | 无 SLO、跨进程 trace/metrics backend 与长期生产数据 |
| 文档 | 较强但未世界级 | 活动规格、ADR、追踪矩阵、研究记录、DocC 编译；生产公开类型 100% 有文档、公开符号门槛 30% | 成员级覆盖仍约三分之一，缺迁移指南、教程深度、外部维护者验证与人工理解签署 |
| 测试 | 强但不全面 | macOS/iOS、TSan/ASan、逐文件 coverage、mutation、HTTP corpus、成功与预期失败 loopback chaos | 无全格式、真机网络/能耗/企业环境矩阵；不能穷举全部并发 interleaving，当前证据仍主要由项目自身生成 |
| Demo | 较强且可证伪 | iOS 15+ FoveaWorkbench 交互默认真实图片且自动化默认确定性、四 origin iOS/CLI HTTPS 矩阵、macOS Gallery、确定性 URLSession chaos、生产管线集成与 iPhone/iPad UI 自动化 | 尚无真实 OAuth/Cookie 服务、后台 URLSession、长时间滚动、真机切网和企业代理实验 |
| 工具与门禁 | 强 | warnings-as-errors、strict format、coverage、mutation、rollback、证据 bundle | 无受保护远端 required checks、独立 held-out evaluator、供应链签名 |

## 本轮复审实际修复

1. 关闭生产默认的 shared-task 高基数 cancellation 侧表，并保留显式测试 instrumentation；
2. 将 permit 释放收敛为作用域语义，覆盖成功、异常与取消；
3. 为 OSLog 活动 signpost 建立真正的全局上限，并在 diagnostics drop 时闭合未配对区间；
4. 为 credential refresh 增加复用时限、remembered-scope 容量与 namespace 失效，并阻止已取消调用者消费 remembered credential 后继续认证重放；
5. 为 namespace registry 增加 fail-closed 容量，且不淘汰已撤销墓碑；
6. 将 persistent store 进程 registry 改为弱引用，并把 writer lease 绑定到 store actor 生命周期；
7. 区分缓存内容损坏与暂时性文件 I/O 故障，避免错误删除有效索引；
8. 将 URLSession task 总时长、redirect 与可选阶段时长完整传播到结构化 diagnostics 和真实网络工件；
9. 覆盖率工件升级为 tree-bound、逐文件阈值与未覆盖函数明细；DocC 增加 100% 公开类型和 30% 公开符号门禁；
10. demo/NetworkLab 改为直接执行已构建二进制，消除当前 Swift 工具链下 `swift run` 只构建未执行的假阳性；
11. 将 FoveaWorkbench 的确定性 origin 计数迁移到 actor，移除 `Task.detached` 与静态 `nonisolated(unsafe)`；`URLProtocol` 仅保留一个最窄 `@unchecked Sendable` 兼容桥，并由结构门禁精确限定文件与数量；
12. 修复 Demo `startLoading`/`stopLoading` 的任务登记竞态，并让 iPhone/iPad UI 测试对 SwiftUI beta runtime 的辅助功能容器差异保持行为级验证；
13. 将公共 `PipelineFailure` 的 reason/status 不变量应用到直接构造和 Codable 解码，避免自由文本或秘密进入稳定错误契约；
14. 将高成本变异门改为 tree-bound 原子 checkpoint，可在中断后安全恢复，并扩展到 70 个关键 mutant。

这些修复提高了长期运行与证据可信度，但不构成整体“世界最好”认证。

## KISS / DRY / 高内聚低耦合

- **高内聚低耦合：基本遵循。** `FoveaPipeline` 是公共门面；fetch、HTTP response、decode/delivery、persistence 与 UI session 分离。
- **KISS：基本遵循。** 未引入通用 interceptor DAG、service locator 或反射式插件系统；优先选择静态 typed seam。
- **DRY：基本遵循。** URL 安全策略、redirect 规则、错误归一化、文件安全与持久发布均集中；仍需警惕规格/manifest/runner 三处 ID 治理的维护成本。

## 为什么没有通用 middleware / interceptor

对图片管线而言，任意拦截器若在 key 冻结后修改 URL、header、授权、网络权限或 transform，会让实际执行与缓存/共享身份分叉；若在 actor/commit 区间调用未知代码，又会引入重入和故障传播。因此当前只保留可审计的 typed seam。

未来若加入 request preparer，必须满足：

1. 在 identity 冻结前执行；或提供版本化、非敏感 execution fingerprint；
2. 明确同步/异步、取消和重入语义；
3. 不在文件锁、actor critical section 或持久事务中调用宿主代码；
4. 具有 mutation 与跨订阅身份测试。

## 当前最重要的缺口

1. `CACHE-PT-017` 已落地固定 canonical bytes/SHA-256 vectors，并配置 arm64/x86_64 独立 runner；本地环境无 Rosetta，当前改动仍须等待远端 Intel run 才能声称双架构通过；
2. SwiftUI 已补阶段内容树与公共 body 构造测试，但真实窗口布局、环境变化和长期交互覆盖仍不足；
3. 没有真机 Instruments 下的 CPU、能耗、峰值 RSS、主线程和滚动帧率比较；
4. 没有与 Nuke、Kingfisher、SDWebImage 在同一设备/数据集/网络下的预注册 non-inferiority 实验；
5. 没有动画、AVIF/JXL/SVG/HDR 等成熟格式生态；
6. FoveaWorkbench 已覆盖确定性认证与网络故障，但仍没有真实 OAuth/Cookie origin、后台下载和真机网络路径切换实验；
7. 没有远端 branch protection、独立 held-out evaluator 与 accountable human attestation；
8. Profile ACL 与 origin allowlist 是机制层安全边界，不是完整 RBAC/ABAC、entitlement 或 IP 级 egress 系统；
9. 资源治理没有 CPU 时间/能耗/thermal/namespace 公平等动态预算；
10. 单 writer 采用 fail-closed 进程租约，不是完整跨进程多 writer 数据库。

## 可接受的“世界级”表述

可以表述为：

> Fovea 已在若干高风险局部契约上采用接近顶级基础设施项目的工程方法，并建立了可证伪门禁。

不能表述为：

> Fovea 的整体架构、功能、性能、测试或工具链已经是世界最好，或已全面超越成熟图片加载项目。
