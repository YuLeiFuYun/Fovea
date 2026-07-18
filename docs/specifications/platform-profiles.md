# 平台默认配置

> **状态：Proposed。**  
> 数值为保守起点，必须通过真机 trace 调整；调用者可以显式覆盖，但不能绕过安全硬上限。

## 1. 设计原则

- 公共 API 按最低共同能力设计；
- 每个平台有不同默认预算，而不是同一配置条件编译；
- correctness lane 覆盖最低系统；performance lane 分为主力设备持续门禁与低资源平台周期验证；
- Experimental codec/AI 不进入默认 product graph。

## 2. 初始 profile

| 平台 | Network | DiskIO | Decode | Process | RenderedMemory | 动画/DerivedEncoded 默认 |
|---|---:|---:|---:|---:|---:|---|
| watchOS 8+ | 2 | 1 | 1 | 1 | 进程建议预算的较小比例，硬上限最低 | 动画保守；Derived 写关闭 |
| iOS/iPadOS 15+ | 4 | 2 | 2 | 2 | 按 physical memory 与 pressure 动态确定 | 动画按需；Derived 写关闭 |
| tvOS 15+ | 4 | 2 | 2 | 2 | 可高于 iOS，但单图 cost cap 仍生效 | 大图常见，Derived 仍需准入 |
| macOS 12+ | 6 | 3 | 物理核心和 pressure 决定，初始 3 | 初始 3 | 按窗口/进程预算动态确定 | 多窗口隔离统计 |
| visionOS 1+ | 4 | 2 | 2 | 2 | 高分辨率但禁止无界缓存 | 辅助/空间表示显式请求 |

表中并发数不是 API 承诺，而是 permit 上限的初始候选。thermal、Low Power Mode、后台、磁盘压力和 memory pressure 可以向下收缩到 1。完整准入、公平性和网络限制见 `resource-budgeting.md`。

## 3. 安全默认

- watchOS 使用最小 pixel/frame/metadata 限制；
- iOS/tvOS/visionOS 以设备内存档位选择限制；
- macOS 仍保留硬上限，不能因内存较多而允许任意解压；
- SVG external resources 和 script 在所有平台默认禁止；
- 第三方 codec 的 fuzz/security policy 不因平台改变；
- namespace revoke、schema mismatch 和 no-store 在所有平台保持同一正确性语义；
- store hard limit、namespace quota 和 PhysicalBlobID 隔离不因平台放宽；
- ContentID/URL/账户标识不进入 production diagnostics。

## 4. 功能矩阵

```text
Core correctness: all supported OS baselines
Modern performance features: availability-gated
AVIF/JXL/JPEG AI fallback: optional codec product
HDR gain map / spatial attachment: capability-gated
GPU/ANE enhancement: experimental and explicit
Animation frame cache: independent budget and visibility-driven
```

## 5. App Extension / Widget

- App 与 Widget 默认使用独立 store/namespace；
- 共享展示需求使用显式公开缩略图 export directory，Widget 只读；
- 不共享认证 OriginalEncoded、主 metadata generation 或 GC ledger；
- 完整模式见 `cache-semantics.md` 的 App/Widget 推荐共享模式。

## 6. CI lanes

### Baseline correctness（每个 PR）

- 所有平台以最低 deployment target 编译；运行时测试使用当前 Xcode 可安装的最旧对应 runtime，并在可获得的旧真机上做周期验证；
- 目标基线仍为 iOS 15 / macOS 12 / watchOS 8 / tvOS 15 / visionOS 1，但若当前 CI 无法安装精确旧 runtime，必须明确记录 coverage gap，不能假装已运行；
- identity、HTTP profile、schema migration、security、scheduler、resource permit、diagnostics schema、state machine；
- 不运行重型实验模块；
- 允许使用 simulator 验证逻辑，但内存/能耗结论不能来自 simulator；
- API availability tests 必须证明最低 deployment target 不会触发未保护的新系统符号。

### Current performance — primary（定期与发布门禁）

- 当前稳定 iOS/iPadOS、macOS、visionOS 的代表性真机；
- Instruments/OSSignposter、energy、HDR、颜色正确性和现代 codec；
- 与 Nuke/Kingfisher 相同设备对照；
- iOS 至少覆盖一台最低性能档和一台当前主流设备。

### Current performance — constrained platforms（周期与 release candidate）

- watchOS：峰值内存、DecodeLimits、动画降级、取消浪费、Low Data Mode/pressure 收缩；
- tvOS：大图、长时间运行、内存 pressure 和焦点快速切换；
- 不要求每个 PR 都运行真机性能门禁，但 release candidate 必须有结果；
- 缺少可用真机时明确标记“未证明”，不能用 simulator 数据代替。

### Codec security

- macOS sanitizer/fuzz lane；
- corpus regression；
- 第三方依赖版本与 CVE 检查；
- 新 codec/model artifact 进入默认或 Trial product 前必须通过。

### External HTTP conformance

- Phase 0a：只运行内部最小 HTTP tests，外部 corpus harness 可并行建设但不阻塞 PR；
- Phase 0b 起：pin `cache-tests.fyi` / WPT 适用 corpus commit，required profile cases 每个 PR 运行；
- corpus 升级单独 PR，保留 provenance manifest；
- not-applicable 分类变化需要 review。
