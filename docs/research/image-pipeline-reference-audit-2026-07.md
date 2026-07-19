# 图片加载管线参考审计（2026-07）

> **状态：Research。** 本文记录参考来源、观察和取舍，不构成稳定 API 承诺。

## 1. 参考基线

本轮审计固定到以下上游提交，避免“参考最新版”成为不可复现叙述：

| 项目 | 审计提交 | 重点 |
|---|---|---|
| Nuke | `63a8fcbd6621340a2410bc3e9575ac97058615f4` | pipeline、request options、prefetch、metrics、UI |
| Kingfisher | `db0ea414e13bf85f562bd4613589ffafa184968b` | downloader/cache、request modifier、processor、SwiftUI |
| SDWebImage | `c3ad5e1a9bf55c9b76d4c362430b5fcded96c502` | 多 loader/cache/transformer、平台覆盖、示例生态 |
| PINRemoteImage | `c0d5cfa1947f2456ddb321a85b347b3d60d83254` | 下载优先级、任务合并、渐进加载、缓存 |

平台语义以 Apple 官方 `URLSessionConfiguration`、`URLRequest`、`URLSessionTaskMetrics`、ImageIO 和 Swift Concurrency 文档为首要依据；RFC 9110/9111 决定 HTTP 语义。

## 2. 结论

Fovea 在 namespace 撤销、HTTP record、持久发布、目标像素准入和证据治理上形成了较强的局部契约，但在生态成熟度、格式覆盖、prefetch、平台样例、真实应用验证和长期 API 稳定性上仍明显落后于成熟项目。因此不能声称整体超越或“世界最好”。

本轮补齐的能力：

- 请求级 cellular/constrained/expensive 权限进入精确执行身份；
- 官方 URLSession 会话具备明确的连接等待、超时和每主机连接上限；
- URLSession 事务摘要暴露协议、连接复用、代理及网络成本标记，但不暴露 URL、IP 或 header；
- 解码按保守 working-set 估算进行带权准入；
- Profile ACL 在缓存和网络访问前 fail closed；
- 可编译 Gallery 与显式 opt-in 的真实网络实验。

## 3. 为什么没有加入通用拦截器 DAG

成熟库普遍提供 request modifier、delegate 或 processor 扩展点。这些能力有价值，但直接照搬到 Fovea 会产生两个风险：

1. 在 key 冻结后修改 URL、header、网络权限或授权语义，会使实际请求与缓存/共享身份不一致；
2. 任意用户回调进入 actor、锁或 commit 区间，会破坏取消、重入和故障边界。

当前策略是使用有类型的窄接缝：不可变 `ImageRequest`、`ImageRequestNetworkPolicy`、`ProfileAccessPolicy`、`CredentialRefreshingImageLoader`、`ImageTransforming`、`HTTPTransporting` 与显式 composition root。未来若加入 request preparer，必须在 key 冻结前运行，或提供版本化、非敏感 execution fingerprint；不得提供无法审计的 post-key mutation。

## 4. 网络路由与代理假设

- 官方 transport 使用系统 `URLSession` 路由，遵循系统代理/PAC/VPN；不自建 socket，也不绕过代理。
- 远程图片默认只允许 HTTPS；明文 HTTP 仅限精确 loopback host，用于可控本地 origin 和确定性协议实验。
- 自定义 `URLSessionConfiguration` 默认 `.taskLocal`，因为代理、`URLProtocol`、client identity 和共享 session state 可能改变响应语义。
- 调用者显式启用复用时，context identifier 必须覆盖这些语义，但不得包含秘密。
- 请求级 constrained/expensive/cellular 权限不会进入持久缓存身份，但必须进入 exact execution identity。
- Fovea 当前不实现自定义代理池、按域路由器、SOCKS 隧道或网络沙箱；这些属于宿主/系统网络栈责任。

## 5. 尚未达到的证据

- 与 Nuke、Kingfisher、SDWebImage 在同一真机、同一数据集、同一网络条件下的预注册比较；
- 真实应用长期滚动、后台/前台、内存警告与账户切换试用；
- HTTP/3、复杂企业代理、TLS client identity、VPN 切换和网络路径变化矩阵；
- 动图、AVIF/JXL/SVG/HDR 等成熟格式覆盖；
- 端到端能耗、CPU 时间、峰值 RSS 和主线程 trace；
- 独立维护者对全部 R3 契约的理解签署与外部审计。

这些缺口存在时，任何“世界最好”结论都不成立。
