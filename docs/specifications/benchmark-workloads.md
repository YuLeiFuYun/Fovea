# Canonical Benchmark Workloads

> **状态：Proposed，Phase 0a harness / Phase 0b 存在性门禁规范。**
> 所有竞品和 Fovea 必须使用相同图片、服务端、目标像素、设备、编译优化、网络条件和缓存状态。

## 当前物理设备与 beta OS 证据政策

当前唯一物理设备是 iPhone 16e / iOS 27 beta，机器角色固定为 `primary-current-mid`，不得重命名为最低性能档。该设备可用于 adapter 等价性、实验噪声、目标像素、取消和 provisional W1/W2/W3 trace，但所有工件必须标记 beta channel 与 `provisional=true`。

Phase 0b 正式毕业仍要求：

- 同一 iPhone 16e 在稳定公开 iOS build 上复跑；
- 另一台较低性能物理设备复跑；
- 模拟器不计入任一物理设备槽位；
- beta 结果不得支持 release 性能声明；
- 设备工件不得保存 UDID、序列号、用户设备名、主机名或账户标识。

设备与阶段状态见 `../PHASE0B_GRADUATION_AND_PHASE1_ENTRY.md` 和 `../phase0b-status.json`。

## 通用指标

每个 workload 至少输出：

```text
TTFP / final latency（p50/p95；样本充分时 p99）
main-thread hitch / dropped frames
peak physical footprint / dirty memory
page faults
decoded megapixels
network bytes / disk read-write bytes
CPU time / energy estimate
single-flight joins
cancelled download bytes
cancelled decode/process time
object hit rate / byte hit rate
binary size
```

禁止只报告平均值。所有结果保存原始 trace、设备型号、OS、构建 SHA 和置信区间。

## 测量纪律与噪声基线

- 每个配置至少完成 20 次有效重复；冷缓存场景至少 10 次完全重置重复；
- 先运行空载/重复基线，估计设备与 harness 噪声；
- 报告中位数、p95 和 95% bootstrap confidence interval；只有独立样本数足够时才报告 p99；
- 若基线 coefficient of variation 超过 5%，该指标不得用于门禁，必须先修复 harness；
- p99 至少需要 200 个独立观测；若数据来自同一次 run 内的多图片事件，bootstrap 必须以 run/session 为 cluster 重采样，禁止把相关事件伪装成独立样本；
- 延迟/内存等主门禁指标在执行前预注册，不能测试后从大量指标中挑选最有利结果；
- Fovea 与竞品交错运行，避免温度、电量和系统状态按顺序偏置；
- 每个 workload 在运行前预注册竞品版本、推荐配置、允许的调优范围和一个 primary comparator；
- 多个合法竞品配置形成 Pareto frontier。主收益和回归护栏必须与同一个 comparator 配置或同一个预注册 frontier point 比较，禁止把不同配置的单项最优拼成不存在的“虚拟竞品”；
- 同时报告 Nuke/Kingfisher 各指标最优包络，作为额外压力参考，但不单独决定通过；
- 无法等价配置时标记为不可比较，不得选择性忽略；
- provisional 门限只能通过 ADR 调整，且必须在查看待判定实现结果前完成。

## 固定执行剖面

门禁 run 禁止使用未记录的办公室 Wi-Fi 或手工滚动。所有剖面必须提交机器可读 artifact 和 checksum。

### 网络

```text
NET-LOCAL-V1
  deterministic local origin
  RTT 25 ms, down 50 Mbit/s, up 10 Mbit/s, loss 0%

NET-CONSTRAINED-V1
  RTT 100 ms, down 8 Mbit/s, up 2 Mbit/s, loss 0.5%
```

W1/W2 provisional 性能门以 `NET-LOCAL-V1` 为主，`NET-CONSTRAINED-V1` 作为敏感性报告；W3 使用 deterministic origin 和显式断网步骤。实际整形工具、观测 RTT/吞吐/丢包和偏差必须记录。

### 滚动

`W1-SCROLL-V1` 使用提交到仓库的时间戳/normalized-offset trace，而不是人工手势。provisional trace 为 40 秒：2 秒 idle；以 1.5 viewport/s 前滚；三次 1.5 秒、2.0 viewport/s 的反向 burst；两次 0.5 秒暂停；最后离开并重复进入一次。真实 point offset 由运行设备 viewport 换算。viewport、cell geometry、refresh rate、Reduce Motion 和 accessibility 设置进入 run manifest。

## 可比性规则

1. 每个 workload 在运行前预注册最多 3 个候选主收益指标；
2. adapter 无法可靠获得某指标时标记 `incomparable`，不能用于通过或失败；
3. 统一 harness 的外部计量（network proxy、Instruments、OS signpost、process memory）只有两边使用同一方法时才可比较；
4. 每个 workload 至少保留 1 个可比较主指标；全部不可比时结果为 `unproven`，不能毕业；
5. 不得用“竞品未暴露内部计数”推断其值为零或较差；
6. `incomparable`、`unsupported`、`failed` 和 `not measured` 必须分别报告。

## Phase 0a smoke gate

0a 不要求性能胜出，只要求：

- 最小切片可以在固定数据和 deterministic origin 上重复运行；
- `TEST_CATALOG.md` 中 Phase 0a IDs 全部通过；
- W1/W2 能输出原始 trace、target pixels、decoded megapixels、内存和取消事件；
- W3 smoke 输出账户隔离、`no-store`、logout cleanup、跨 origin redirect 和 commit race 的机器可读零违规矩阵；
- `no-store`、namespace/revoke 和迟到 UI 结果没有已知错误；
- 不允许以未完成的 0b corpus 阻塞 0a 代码合并。

### Phase 0a harness 实现与 artifact

当前 smoke harness 位于 `FoveaTesting/BenchmarkSmokeHarness.swift`，测试入口位于 `BenchmarkSmokeTests.swift`。运行 `scripts/verify.sh` 会在 `.artifacts/benchmarks/` 生成 W1/W2 JSON，并由 `scripts/validate-benchmark-artifacts.py` 校验。artifact 结构由 `docs/schemas/benchmark-smoke-artifact.schema.json` 固定。

这些 smoke 数值只证明 harness、追踪和关键不变量可重复执行，不构成竞品性能结论，也不得用于 Phase 0b 的 15% 存在性判定。

## G0：协议与持久化正确性硬门禁

G0 属于 Phase 0b，不比较性能；任何失败都阻止进入 Core v1 Candidate：

```text
persistent key golden vectors 跨进程/架构一致
旧 schema 兼容读或稳定 miss，不 crash
StoreGeneration 原子切换 crash matrix 全通过
namespace revoke 与 Commit 竞态残留 = 0
shared task priority property tests = 100% pass
Private Image Cache Profile required external corpus = 100% pass
```

外部 HTTP corpus 必须固定 upstream commit，并维护来源、license、RFC section 和 applicability manifest。WPT 是 Fetch/browser 视角，只统计经评审为 Fovea profile `required` 的用例。

## W1：Feed Scroll

### 目的

验证列表滚动、复用、取消、请求共享和内存缓存行为。

### 数据集

- 1000 个逻辑条目；
- 混合唯一 URL 与重复资源；
- 目标像素集中在头像和 feed 缩略图；
- 包含少量远大于目标尺寸的源图；
- 固定、明确可缓存的公开资源，不包含鉴权变量或 `no-store`；
- 主门禁不把 HTTP 隐私语义成本混入一般缓存性能。

### 操作

- 固定滚动轨迹和速度；
- 多次快速反向滚动；
- 重复进入页面；
- 冷缓存、暖磁盘、暖内存分别执行。

### 核心判据

```text
scroll hitch
peak dirty memory
decoded megapixels
cancel waste
network duplicate bytes
post-scroll cache pollution
```

## W1-NOSTORE-SENS：严格 no-store 敏感性（非阻塞）

使用与 W1 相同的滚动 trace，将 10%、50%、100% 响应切换为 `Cache-Control: no-store`。报告重复下载、重复解码、cancel waste、hitch 和峰值内存，但不参与 Phase 0b 存在性硬门。该报告用于量化严格语义的成本，禁止据此放宽 `no-store` 或建立 page/session reusable cache。

## W2：Detail Hero

### 目的

验证大图目标尺寸解码和峰值内存。

### 数据集

- 12MP、24MP、48MP 静态图片；
- JPEG、HEIF/系统支持格式；
- Display P3/普通 sRGB、EXIF orientation、alpha 样本；
- 目标尺寸显著小于源尺寸；
- HDR/gain-map 样本作为 Core v1/Phase 2 扩展，不阻塞 Phase 0a。

### 操作

- 列表缩略图进入详情；
- 不同屏幕 scale；
- 旋转/窗口尺寸变化；
- 冷缓存和 OriginalEncoded 命中。

### 核心判据

```text
输出像素尺寸/orientation/color 基本正确
是否产生无必要全尺寸位图
peak memory
decoded megapixels
TTFP / final latency
main-thread work
```

## W3：Auth Gallery

### 目的

验证鉴权、身份、安全 namespace、`no-store`、重定向和登出清理。通用 freshness/Age/Vary/304 一致性只在 G0 统计。

### 数据集

- 相同 URL 在账户 A/B 返回不同字节；
- cookie、Bearer token、signed URL；
- `private`、`no-store`、fresh、stale、304、Vary；
- 跨 origin redirect；
- 断网与 stale policy。

### 操作

- A 登录并访问；
- 登出并清理；
- B 登录访问相同 URL；
- 并发切换 namespace；
- 检查内存、磁盘、metadata 和日志。

### 核心判据

```text
跨账户像素泄漏 = 0
跨账户 metadata/blob 生命周期耦合 = 0
no-store reusable memory/disk writes = 0
logout 后污染 = 0
Authorization 不随跨 origin redirect 泄漏
logout 与在途 Commit 竞态残留 = 0
```

## W4：渐进 JPEG

### 目的

验证首个可接受渐进结果、扫描质量演进、最终像素正确性和取消传播。

### 核心判据

```text
time to first acceptable preview
preview quality over time
final pixel correctness
post-cancel bytes/decode work
peak buffering memory
```

当前状态：`capability-gap`。在生产 progressive event 路径、fixture corpus 和统一 adapter 合同完成前，不得从矩阵中删除，也不得以普通 JPEG 最终解码冒充支持。

## W5：GIF/APNG/WebP 动图

### 目的

验证帧调度、帧缓存、掉帧、循环语义和内存边界。

### 核心判据

```text
startup latency
frame timing error / dropped frames
peak frame-cache memory
decode CPU / energy
loop and lifecycle correctness
```

当前状态：`capability-gap`。静态 WebP 或首帧解码不等于动图支持。

## W6：弱网和中断恢复

### 目的

验证 retry、resume、Range、断线重连、取消和流量浪费。

### 核心判据

```text
recovery success rate
resume-saved bytes
duplicate network bytes
retry amplification
time to recovery
```

当前状态：retry 基础设施已存在，完整 resumable transfer 仍为 `capability-gap`。

## W7：1,000 并发请求

### 目的

验证请求合并、线程/任务数量、锁竞争、容量约束、公平性和尾延迟。

### 核心判据

```text
origin request count
peak thread/task count
p99 queue delay
lock wait
starvation / fairness gap
aggregate subscriber wait
```

当前状态：底层 single-flight、permit 与调度测试存在，统一五库 1,000 请求 runner 尚未完成。

## W8：缓存重启与损坏

### 目的

验证 durability、进程重启恢复、外部删除、损坏隔离和原子发布。

### 核心判据

```text
restart recovery time
corruption rejection
external deletion convergence
partial publication count
read/write throughput within the same durability level
```

当前状态：Cache Lab V2 已完成绑定 source、plan 与 claim-family digest 的 20-block schema 3 本地正式重跑；硬正确性、劣势和证据不足均为 0。仍需 clean final source 与 trusted CI 下按相同计划复跑，并扩展真实进程终止矩阵和 held-out corpus。

## W9：敌意图片 corpus

### 目的

验证 crash、OOM、维度/帧数/解压比上限、畸形数据和持续 fuzz。

### 核心判据

```text
crash / hang / OOM count
limit violation count
rejection latency
false rejection rate
fuzz throughput and sanitizer findings
```

当前状态：Fovea 有部分输入检查与测试，但完整 hostile corpus、长期 fuzz 和跨库统一 runner 尚未完成。

## W10：SwiftUI identity churn

### 目的

验证 View identity 快速变化、旧结果闪现、取消、消失/重现和 generation 正确性。

### 核心判据

```text
wrong-image flash count
stale result publication count
cancel latency
visible blank duration
live task count
```

当前状态：Fovea SwiftUI 状态测试存在，统一端到端 churn runner 尚未完成。

## W11：多尺寸同源图片

### 目的

验证相同编码资源的下载共享、不同 target/transform 的变体身份和缓存复用。

### 核心判据

```text
origin download count
encoded byte duplication
variant cache hit rate
decode/transform count
peak memory
```

当前状态：Fovea 已有 encoded/decode sharing 单元证据，专项比较 workload 尚未完成。

## W12：内存警告/后台切换

### 目的

验证资源回收速度、后台/前台状态一致性、缓存清理和旧 generation 抑制。

### 核心判据

```text
memory release latency
post-pressure resident memory
resource leak count
cache repopulation time
network refetch bytes
```

当前状态：Fovea 内存压力机制存在，缺少脚本化 OS 压力和五库物理 runner。

## W13：phase-changing cache trace

### 目的

验证热点、扫描、churn 和大小/成本分布切换下的淘汰策略自适应。

### 核心判据

```text
dynamic/windowed regret
object and byte hit regret
cost-weighted saved work
p99 operation latency
metadata/update overhead
```

当前状态：研究模拟器与当前 Cache Lab schema 3 本地 formal 证据均存在；hot-scan 和并发主指标已无劣势或证据不足。仍需 clean trusted 重跑、held-out 真实图片 trace、large-trace 下界方法和 dynamic-regret 声明族扩展。

## W14：离线/重验证

### 目的

验证 offline、stale、304、过期、Vary 和显式 fallback policy。

### 核心判据

```text
protocol violation count
offline success rate
304/revalidation latency
revalidation network bytes
stale serve correctness
```

当前状态：Fovea conformance 和 stale fallback 测试存在，统一竞品语义 adapter 尚未完成。

## W15：低数据/昂贵网络

### 目的

验证 constrained/expensive network 下的策略切换、优先级和预取抑制。

### 核心判据

```text
expensive-network bytes
unnecessary prefetch count
visible deadline miss rate
policy switch latency
quality degradation / user-visible failure
```

当前状态：完整公开策略控制面和真机网络 profile 尚未完成。

## X1：Adaptive Representation（辅助 workload，非 W1-W15 编号）

用于多尺寸、格式、SDR/HDR 候选选择。该 workload 保留原规范价值，但不再占用 W4。只有在 W2、W4、W5、W11 与网络策略稳定后，才用于决定 RepresentationSelector 是否毕业。

核心指标：下载字节、TTFP、最终质量、错误候选率、fallback 成本和选择器自身开销。

## Phase 0b provisional 门限

以下数字用于让 Phase 0b 可裁决，不是永久营销指标。通过后再用 ADR 根据更多设备和真实 trace 调整。

### 硬失败

任何一项发生即失败，不能用其他性能收益交换：

- crash、hang、错误像素/orientation/color 或跨请求迟到覆盖；
- W2 在 targetPixels 明显小于 sourcePixels 时产生无必要全尺寸位图；
- G0 任一协议/持久化门禁失败；
- W3 任一泄漏、污染、`no-store` 持久化、revoked generation 复活或跨 origin Authorization 泄漏非零；
- 缺失原始 trace、设备信息或无法复现实验。

### W1：Feed Scroll

至少一项预注册主收益相对同一 primary comparator 或预注册 Pareto point 改善 **≥15%**，且 95% CI 的保守端仍显示 **≥5%** 改善：

- cancel waste bytes；
- main-thread hitch time / hitch count；
- peak dirty memory。

同时满足回归护栏：

- p95 final latency 退化不超过 **5%**；
- peak dirty memory（若不是主收益）退化不超过 **10%**；
- network bytes 退化不超过 **10%**；
- post-scroll cache pollution 不高于同一 comparator **10%** 以上；并单独报告竞品最优包络。

### W2：Detail Hero

必须先通过输出尺寸、orientation、alpha 与受控 color reference 的正确性门禁，满足 target-pixel invariant，并且相对同一 primary comparator 或预注册 Pareto point，以下至少一项改善 **≥15%**，95% CI 保守端仍改善 **≥5%**：

- decoded megapixels；
- peak dirty memory。

同时满足：

- p95 final latency 退化不超过 **5%**；
- TTFP 退化不超过 **5%**；
- main-thread work 不高于同一 comparator **10%** 以上；并单独报告竞品最优包络。

### W3：Auth Gallery

以下全部必须为零或完全符合规范：

```text
cross-account pixel leak = 0
cross-account metadata/blob coupling = 0
no-store reusable cache writes = 0
logout residue = 0
cross-origin authorization leak = 0
namespace revoke/commit race residue = 0
```

### Phase 0b 存在性路径

所有路径都必须先满足：G0 全过、W3 全过、target-pixel/output correctness 全过、至少一台最低性能档设备和一台当前主流设备复现。

#### Path A：Performance

- W1 和 W2 均满足各自 15% 主收益门；
- 所有回归护栏通过；
- 每个 workload 至少一个可比较主指标；
- 可以在证据范围内声称性能优势。

#### Path B：Correctness

- 预注册的相关对照至少包括 Nuke 与 Kingfisher；正确性差异必须在全部相关对照中 `unsupported`、无法安全表达或实际失败，或证明它们必须依赖应用层额外拼装而 Fovea 提供内建不可绕过保证；`unknown` 不能作为证据；
- W1 和 W2 至少各有一个统一方法可比较指标；
- p95 final latency non-inferiority margin 为 +5%；
- peak dirty memory、network bytes 和 main-thread work 的 non-inferiority margin 为 +10%；
- 95% CI 的不利端不得越过对应 margin；
- 不要求 15% 性能改善，但不得宣传“更快”或“更省内存”；
- 只允许以 HTTP/安全/身份/目标像素正确性为首要价值进入 Core v1 Candidate，性能工作继续接受 Path A 门禁。

### Phase 0b 毕业报告

报告必须包含：

1. 选择的存在性路径及预注册理由；
2. `TEST_CATALOG.md` 的 ID 结果矩阵；
3. primary comparator、Pareto frontier 候选和 adapter 版本；
4. 固定网络/滚动 trace、设备、OS、构建 SHA；
5. raw trace、置信区间、不可比指标和 coverage gaps；
6. 同一门禁中的主收益与护栏必须来自同一 comparator 配置；
7. 任何无法可靠测量的指标记录为 `unproven`，不能按通过处理。
