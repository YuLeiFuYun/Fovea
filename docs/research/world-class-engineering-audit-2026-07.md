# Fovea 世界级工程审查（2026-07）

> **状态：Research / current implementation assessment。** 本文评价当前实现，不构成“世界最好”认证或稳定 API 承诺。

## 结论

Fovea 的缓存身份、namespace 撤销、持久发布、并发 single-flight、目标像素解码与安全失败边界已经达到较高工程质量；但项目整体仍不能称为“世界最好”。成熟度、生态、格式覆盖、真机性能、长期真实应用验证、SwiftUI 行为覆盖、跨架构键证据和独立审计仍存在明确缺口。

当前保证阶段保持 `0b-in-progress`。

## 分项判断

| 领域 | 当前判断 | 主要依据 | 未达到世界级认证的原因 |
|---|---|---|---|
| 架构与边界 | 强 | 固定职责 coordinator、分层 package、typed seam、无通用 service locator | API 稳定性与真实应用演化尚未证明 |
| 耦合 | 较低 | Core 不依赖 UI；HTTP、持久化、解码边界清楚 | composition root 与平台示例仍年轻 |
| 状态管理 | 强 | actor、不可变 request/config、namespace generation、display identity 栅栏 | 尚无长期复杂宿主状态压力证据 |
| 错误处理 | 强 | 结构化 category/stage/disposition/reason；fail closed；rollback/cleanup 证据 | 部分 best-effort 物理清理依赖后续 GC 收敛 |
| Swift 风格 | 强 | Swift 6 strict concurrency、package implementation API、Sendable、无 `@unchecked` | 尚未经过广泛外部 API review |
| 扩展机制 | 克制 | transport/decoder/transformer/diagnostics/ACL/credential typed seam | 无通用 middleware；这是有意取舍，不是功能等价 |
| 网络与代理 | 较强 | 系统 URLSession、系统代理/PAC/VPN、请求网络权限、HTTPS 默认、降级 redirect 拒绝 | 无自定义路由器、代理池、HTTP/3/企业代理矩阵 |
| 生命周期 | 较强 | subscriber cancellation、UI identity、memory pressure、writer lease、进程组清理 | 无后台 URLSession、跨进程全局生命周期控制 |
| 资源治理 | 较强 | fetch/decode hard cap、weighted working-set、memory cost、body limit、queue limit | 无 CPU 时间、能耗、thermal 动态预算和 namespace 加权公平 |
| Profile ACL | 有界且明确 | 精确 namespace/auth-context allowlist；系统组合根 public-only | 不是 RBAC/ABAC/entitlement 引擎，不推断业务角色 |
| 日志与可观测性 | 较强 | 有界异步 sink、脱敏 reason、URLSession transaction summary | 无 production exporter、SLO、跨进程 trace/metrics backend |
| 文档 | 较强 | 活动规格、ADR、追踪矩阵、研究记录、事实/目标分离 | 人工理解签署与外部维护者验证缺失 |
| 测试 | 强但不全面 | macOS/iOS、TSan/ASan、mutation、coverage、HTTP corpus、loopback 网络 | SwiftUI 行覆盖约 37%；无全格式、真机网络/能耗/企业环境矩阵 |
| Demo | 可用 | macOS Gallery、opt-in 公网 Network Lab、确定性 loopback origin | 尚无 iOS 示例 App、复杂认证服务、长时间滚动和离线/切网演示 |
| 工具与门禁 | 强 | warnings-as-errors、strict format、coverage、mutation、rollback、证据 bundle | 无受保护远端 required checks、独立 held-out evaluator、供应链签名 |

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

1. `CACHE-PT-017` 跨架构稳定键向量仍缺 x86_64/Rosetta 或独立 runner 证据；
2. SwiftUI 生产源码行覆盖约 37%，声明式 view tree 与真实布局测试不足；
3. 没有真机 Instruments 下的 CPU、能耗、峰值 RSS、主线程和滚动帧率比较；
4. 没有与 Nuke、Kingfisher、SDWebImage 在同一设备/数据集/网络下的预注册 non-inferiority 实验；
5. 没有动画、AVIF/JXL/SVG/HDR 等成熟格式生态；
6. 没有 iOS 示例 App、复杂认证 origin、后台下载和网络路径切换实验；
7. 没有远端 branch protection、独立 held-out evaluator 与 accountable human attestation；
8. Profile ACL 只是精确 allowlist，不是完整业务权限系统；
9. 资源治理没有 CPU 时间/能耗/thermal/namespace 公平等动态预算；
10. 单 writer 采用 fail-closed 进程租约，不是完整跨进程多 writer 数据库。

## 可接受的“世界级”表述

可以表述为：

> Fovea 已在若干高风险局部契约上采用接近顶级基础设施项目的工程方法，并建立了可证伪门禁。

不能表述为：

> Fovea 的整体架构、功能、性能、测试或工具链已经是世界最好，或已全面超越成熟图片加载项目。
