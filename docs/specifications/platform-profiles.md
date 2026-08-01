# 平台默认配置

> **状态：Active Phase 0a 支持声明 / 后续平台候选。**
> 数值为保守起点，必须通过真机 trace 调整；调用者可以显式覆盖，但不能绕过安全硬上限。

## 1. 设计原则

- 公共 API 按最低共同能力设计；
- 每个平台有不同默认预算，而不是同一配置条件编译；
- correctness lane 覆盖最低系统；performance lane 分为主力设备持续门禁与低资源平台周期验证；
- Experimental codec/AI 不进入默认 product graph。

## 2. 当前支持与后续候选

Phase 0a 的 Package manifest 只声明并持续验证：

| 平台 | deployment target | 当前默认 fetch/decode | 验证状态 |
|---|---:|---:|---|
| iOS/iPadOS | 15+ | 6 / 2，等待队列各 512 | iOS Simulator required；真机性能仍待证明 |
| macOS | 12+ | 6 / 2，等待队列各 512 | SwiftPM、Release、TSan、ASan required |

watchOS、tvOS 与 visionOS 仍是后续候选，不在当前 manifest，不构成支持承诺。它们只有在建立对应编译 lane、最低系统验证、资源 profile 和 UI adapter 契约后才可加入。

Phase 0a 数值是静态 hard cap，不是最终性能承诺。thermal、Low Power Mode、后台、memory pressure、公平性和动态收缩属于完整 resource governor。

## 3. 安全默认

- iOS 以设备内存档位选择后续动态限制；
- 候选平台在加入支持矩阵前必须定义独立限制；
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

- iOS 15 与 macOS 12 以最低 deployment target 编译；运行时测试使用可安装的代表性 runtime，并记录旧系统 coverage gap；
- 未在 Package manifest 声明的平台不得出现在“已支持”列表；
- identity、HTTP profile、schema migration、security、scheduler、resource permit、diagnostics schema、state machine；
- 不运行重型实验模块；
- 允许使用 simulator 验证逻辑，但内存/能耗结论不能来自 simulator；
- API availability tests 必须证明最低 deployment target 不会触发未保护的新系统符号。

### Current performance — primary（定期与发布门禁）

- 当前稳定 iOS/iPadOS 与 macOS 的代表性真机；
- Instruments/OSSignposter、energy、HDR、颜色正确性和现代 codec；
- 与 Nuke/Kingfisher 相同设备对照；
- iOS 至少覆盖一台最低性能档和一台当前主流设备。

### Future platform admission

watchOS、tvOS、visionOS 每个平台必须先具备最低系统编译、代表性真机资源数据、取消/pressure 测试和明确 adapter 责任，才能加入 manifest。缺少证据时保持 unsupported，而不是用 simulator 或“代码大概可编译”替代。

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
