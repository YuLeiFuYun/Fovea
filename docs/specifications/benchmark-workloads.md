# Canonical Benchmark Workloads

> **状态：Proposed，Phase 0a harness / Phase 0b 存在性门禁规范。**  
> 所有竞品和 Fovea 必须使用相同图片、服务端、目标像素、设备、编译优化、网络条件和缓存状态。

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
- `no-store`、namespace/revoke 和迟到 UI 结果没有已知错误；
- 不允许以未完成的 0b corpus 阻塞 0a 代码合并。

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

## W4：Adaptive Representation（非 v1 阻塞）

用于多尺寸、格式、SDR/HDR 候选选择。只有在 W1-W3 稳定后才用于决定 RepresentationSelector 是否毕业。

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

