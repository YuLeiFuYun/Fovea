# Target Geometry 与像素规范化

> **状态：Proposed，Phase 0a/Core v1 Candidate 规格。**

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

## 5. 动态 resize 与尺寸爆炸

macOS 窗口拖动、iPad 分屏和 visionOS 布局变化可能每帧产生不同尺寸。默认策略：

- 对连续变化 debounce；
- 当前结果仍足够清晰时使用 hysteresis，不立即重解码；
- 可采用少量向上取整 bucket，但 bucket policy/version 必须进入 DecodePlan fingerprint；
- 不允许无界尺寸变体写入 RenderedMemory/DerivedEncoded；
- resize 交互期间的中间 bucket 结果只属于当前 task/view token，不进入可被其他请求查询的缓存；
- 只有满足 stable-target 条件（hysteresis 完成、交互结束或稳定窗口到期）的结果才准入正常 RenderedMemory；
- 最终稳定尺寸到达后再请求精确结果；旧 bucket 可在新结果到达前用于显示，但不能污染长期缓存统计。

## 6. API 契约

推荐：

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
- **GEO-PT-010**: stable-target 产生后最多一个长期 RenderKey 被准入。
