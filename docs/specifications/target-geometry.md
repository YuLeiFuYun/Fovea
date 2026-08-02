# Target Geometry 与像素规范化

> **状态：Active。** 当前实现只接受 `TargetGeometryPolicy` schema 3；旧量化策略不兼容。

## 1. 核心不变量

Fovea 的图片 API 必须明确区分：

```text
display-target request   已知目标像素，允许目标尺寸解码与 RenderedMemory
original-size request    显式 opt-in，允许原尺寸解码并接受资源成本
encoded-data request     只取编码字节，不产生解压位图
```

无 UI 的 async API 默认要求 target；不得把缺失 target 静默解释为“解码原图”。

## 2. 公共输入与内部表示

公共 UI API 可以接收：

```text
points size + display scale + content mode
```

规范化后内部只使用整数 target pixels：

- 正数有限值；
- 默认按 `ceil(points * scale)`，避免低于显示需要；
- 0、负数、NaN、Infinity 视为 unknown/invalid；
- 超过 DecodeLimits 时拒绝或按显式 policy clamp；
- DecodeKey/RenderKey 保存最终选定的像素语义，不保存等价 point 表达。

## 3. 布局尚未确定

SwiftUI/UIKit/AppKit view 在尺寸为 0 或尚未布局时：

- 可以解析 Source、查询 metadata 或预取 OriginalEncoded；
- 不发起原尺寸 DecodeAtTarget；
- final decode 等待第一个稳定非零 target；
- placeholder 不因此闪烁或重复订阅。

## 4. Fit/Fill 与 DecodePlan

最终 decode extent 依赖 source dimensions、orientation、content mode 和 crop：

1. Probe 获取安全尺寸/orientation；
2. TransformPlanner 计算 source region 与 output extent；
3. 尽可能把 region/orientation/resize 下推到 DecodePlan；
4. RenderKey 使用实际 output pixels 和规范化 plan。

不能仅用 view bounding box 作为所有 fit/fill 情况的最终 key。

## 5. 动态 resize、迟滞与混合量化

macOS 窗口拖动、iPad 分屏和连续布局变化可能每帧产生不同尺寸。当前 schema 3 将量化职责分成两个阶段：

- `ceil(points × scale)`，始终不低于显示需要；
- transient 尺寸在小尺寸使用固定 `bucketStep`，超过阈值后使用几何增长；
- stable 尺寸使用精确整数像素，不承受几何桶的长期超采样；
- transient 与 stable 之间切换时强制重新解析，迟滞只在同一准入类别内复用；
- growth/shrink hysteresis 抑制同一阶段边界附近往返重解码；
- 原始尺寸先检查最大维度，解析后再检查最大像素总数；
- resize 中间结果标记为 transient，不进入正常 RenderedMemory；
- 只有 stable target 才可持久复用；
- policy schema 和全部量化参数进入 fingerprint。

旧 schema 1/2 直接解码失败，不保留迁移分支。研究和回归保留旧线性策略作为离线对照，但生产 API 只有当前两阶段量化。

对 transient 的 257...4096 全域实现级枚举要求：尺寸不向下量化，`bucket/raw ≤ 1.07`，面积膨胀 `≤ 1.145`，且生成身份数少于纯 16px 线性桶的三分之一。stable 阶段要求 `resolved = ceil(points × scale)`，因此最终像素膨胀只来自点到像素的必要上取整。该边界只描述像素与资源，不等价于完整感知率失真最优。

## 6. 候选 API 契约

以下是方向性语法，不是 Phase 0b 当前可编译 API：

```swift
let image = try await Fovea.shared.image(
    for: url,
    target: .pixels(width: 600, height: 400),
    contentMode: .fill
)

let data = try await Fovea.shared.encodedData(for: url)

let original = try await Fovea.shared.image(
    for: url,
    target: .originalSize,
    resourcePolicy: .explicitlyAllowOriginalDecode
)
```

不提供或不推荐无参数 `image(for: url)` 原图快捷路径。

## 7. Property tests

- **GEO-PT-001**: 相同最终 pixels、不同 points/scale 表达得到同一 DecodeKey；
- **GEO-PT-002**: 0×0 布局不触发全尺寸 decode；
- **GEO-PT-003**: original-size 必须显式 opt-in；
- **GEO-PT-004**: fit/fill/orientation 产生正确 extent；
- **GEO-PT-005**: 连续 resize 不无界制造 key；
- **GEO-PT-006**: bucket/hysteresis policy 变化进入 fingerprint；
- **GEO-PT-007**: target 超限在分配前拒绝；
- **GEO-PT-008**: encoded-data request 不产生 decoded megapixels。当前 `EncodedDataLoading.encodedData(for:)` 只读取 fresh 已验证缓存或执行不持久化的新网络获取；新字节在未经图像验证前不得写入 OriginalEncoded/record。
- **GEO-PT-009**: resize 中间 bucket 不进入正常 RenderedMemory admission/hit-rate；
- **GEO-PT-010**: stable-target 产生后最多一个长期 RenderKey 被准入；
- **MATH-PT-011**: transient 几何桶切换到 stable 时必须重新解析为精确像素，且 stable 迟滞不得复用 transient 桶。
