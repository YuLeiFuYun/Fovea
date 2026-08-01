# 图片加载管线参考审计（2026-07）

> **状态：Research。** 本文记录参考来源、观察和取舍，不构成稳定 API 承诺。

## 1. 参考基线

本轮审计固定到以下上游提交，避免“参考最新版”成为不可复现叙述：

| 项目 | 审计提交 | 重点 |
|---|---|---|
| Nuke | `63a8fcbd6621340a2410bc3e9575ac97058615f4`（13.0.6） | pipeline、request options、prefetch、metrics、UI |
| Kingfisher | `410984bf301f4fa224fe56277b3f8672cc465c79`（8.11.0） | downloader/cache、request modifier、processor、SwiftUI |
| SDWebImage | `2de3a496eaf6df9a1312862adcfd54acd73c39c0`（5.21.7） | 多 loader/cache/transformer、平台覆盖、示例生态 |
| PINRemoteImage | `c0d5cfa1947f2456ddb321a85b347b3d60d83254` | 下载优先级、任务合并、渐进加载、缓存 |

平台语义以 Apple 官方 `URLSessionConfiguration`、`URLRequest`、`URLSessionTaskMetrics`、ImageIO 和 Swift Concurrency 文档为首要依据；RFC 9110/9111 决定 HTTP 语义。

## 2. 结论

Fovea 在 namespace 撤销、HTTP record、持久发布、目标像素准入和证据治理上形成了较强的局部契约，但在生态成熟度、格式覆盖、prefetch、平台样例、真实应用验证和长期 API 稳定性上仍明显落后于成熟项目。因此不能声称整体超越或“世界最好”。

本轮补齐的能力：

- 请求级 cellular/constrained/expensive 权限进入精确执行身份；
- 官方 URLSession 会话具备明确的连接等待、超时和每主机连接上限；
- URLSession 事务摘要暴露 task 总时长、redirect、协议、连接复用、代理、网络成本标记与可选阶段时长，但不暴露 URL、IP 或 header；
- 解码按保守 working-set 估算进行带权准入；
- Profile ACL 在缓存和网络访问前 fail closed；
- 可编译 Gallery、交互默认真实图片、自动化默认确定性的 FoveaWorkbench，以及计划任务/完成门使用的多 origin HTTPS 实验。

## 3. 为什么没有加入通用拦截器 DAG

成熟库普遍提供 request modifier、delegate 或 processor 扩展点。这些能力有价值，但直接照搬到 Fovea 会产生两个风险：

1. 在 key 冻结后修改 URL、header、网络权限或授权语义，会使实际请求与缓存/共享身份不一致；
2. 任意用户回调进入 actor、锁或 commit 区间，会破坏取消、重入和故障边界。

当前策略是使用有类型的窄接缝：不可变 `ImageRequest`、`ImageRequestNetworkPolicy`、`ProfileAccessPolicy`、`RefreshingImageLoader`、`ImageTransforming`、`HTTPTransporting` 与显式 composition root。未来若加入 request preparer，必须在 key 冻结前运行，或提供版本化、非敏感 execution fingerprint；不得提供无法审计的 post-key mutation。

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
- ImageIO incremental source 已进入 candidate provenance；生产渐进解码仍需完成 preview cadence、累计数据上限、working-set、取消和最终身份一致性设计与测试。

这些缺口存在时，任何“世界最好”结论都不成立。
## 6. 2026-07-20 上游能力复核

当前官方资料仍显示：Nuke 13 已把 request coalescing、优先级、prefetch、resumable download、progressive JPEG、HEIF/WebP/GIF 和 SwiftUI 作为成熟产品能力；Kingfisher 8 提供多层缓存、处理器、预取、Low Data Mode、SwiftUI 与 Live Photo；SDWebImage 提供 progressive/animated image、thumbnail decoding、多 cache/loader 与广泛 coder 插件。Fovea 不得把这些通用能力描述为独占创新。

可继续验证的差异候选限定为：namespace revoke commit fence、persistent/execution identity 分离、分配前资源预算、bounded HTTP metadata、tree-bound mutation/evidence。它们必须通过同设备 adapter 实验或对照行为测试，不能仅凭架构叙述升级为 superiority claim。

参考入口：

- https://github.com/kean/Nuke
- https://github.com/onevcat/Kingfisher
- https://github.com/SDWebImage/SDWebImage
- https://developer.apple.com/documentation/imageio/cgimagesource


## 7. 2026-07-25 精确适配器复核

Comparative Lab 已以完整提交固定 Nuke 13.0.6 与 Kingfisher 8.11.0，并为 Fovea、Nuke、Kingfisher 建立同一 `ComparatorAdapter` 契约。三者分别编译，避免一个 App 同时链接多个图片库造成启动、二进制和全局状态污染。

当前只可确认：

- Nuke 的 async task、像素 thumbnail、memory/data cache 和取消可映射；
- Kingfisher 的 DownsamplingImageProcessor、独立 cache/downloader、共享下载取消和 cache source 可映射；
- Fovea 的显式 target、稳定 logical source、结构化 failure 和 Swift Task 取消可映射；
- dirty Fovea 构建必须绑定 tree digest，不能只写 HEAD；
- Kingfisher 固定源码在 Xcode 27/macOS 27 SDK 下会产生 UTI deprecated 和捕获语义警告；适配器自身无警告。

这些是 adapter 可执行性证据，不是 W1/W2/W3 胜负结论。正式结论仍需真机 App、相同数据集和 trace、交错重复、外部 Instruments/网络计量与置信区间。
