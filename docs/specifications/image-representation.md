# 图像表示、颜色与动态范围契约

> **状态：Proposed；基础静态 orientation/color/alpha 为 Phase 0b/Core v1，HDR/辅助平面为 Phase 2 capability。**

## 1. 目标

“成功解码”不只意味着获得像素。orientation、颜色空间、动态范围、alpha、像素格式和辅助平面必须具有明确语义，并参与 DecodeKey/RenderKey；否则相同字节可能在不同设备上显示不同或错误复用缓存。

## 2. 内部表示

建议使用不可变值模型：

```text
DecodedImage
├── primary CGImage/immutable surface
├── pixelSize
├── orientationState
├── colorDescription
├── dynamicRange
├── alphaDescription
├── pixelFormat/backend
├── displayReadiness
└── lazy attachments
```

平台 `UIImage`/`NSImage` 是 UI adapter 输出，不作为 Core 唯一真实模型。

## 3. Orientation

- Probe 读取容器 orientation；
- DecodePlan 明确 `.applyToPixels` 或 `.preserveMetadata`；
- 普通显示路径默认把 orientation 下推至 decode/transform，并输出逻辑 `.up` 的像素；
- 原编码数据 API 保留原始 metadata；
- orientation policy 必须进入 DecodeKey；
- crop/region 先在明确坐标空间中规范化，不能混用 encoded、oriented 和 display 坐标。

## 4. Color

默认行为：

- 保留并正确解释嵌入 ICC/ColorSync profile；
- 无 profile 时使用格式与平台定义的保守默认，不自行猜测广色域；
- 只有 DisplayContext/TransformPlan 要求时才转换输出色彩空间；
- source profile、working space、output space 和 rendering intent 分开记录；
- P3 到 sRGB、HDR 到 SDR 等转换必须显式且 fingerprinted；
- 不因 resize/downsample 静默剥离颜色语义。

颜色参数进入 DecodeKey 还是 RenderKey，取决于转换发生阶段；同一语义不得重复编码两次。

## 5. Dynamic range 与 HDR

```text
DynamicRangePolicy
├── preserveSource
├── preferHDRWhenDisplaySupports
├── forceSDR(toneMapPolicy)
└── rejectUnsupported
```

规则：

- HDR、gain map、extended-range surface 不得静默当作普通 SDR 复用；
- tone mapping 算法/版本进入 RenderKey；
- 不支持 HDR 的平台使用明确 fallback，不能丢失附件后仍标记为等价；
- gain map、depth、matte 等 attachment 默认 lazy，只有请求或处理确实需要时加载；
- attachment selection 进入 DecodeKey。

## 6. Alpha 与像素格式

- 明确 straight/premultiplied alpha、alpha presence 和 bitmap byte order；
- processor 不得假设所有输入都是 8-bit premultiplied BGRA；
- 后端转换如果改变精度、色域或 alpha 语义，必须在 plan/fingerprint 中表达；
- row alignment 与 pixel format 由后端和基准决定，不作为视觉等价的隐式细节。

## 7. Display readiness

`displayReadiness` 至少区分：

```text
encoded/lazy
fullyDecodedCPU
GPUBacked
platformPrepared
```

Display preparation 只在需要时发生。已经 fully decoded 的结果不重复准备；GPU-backed 或特殊 provider 走对应 adapter。readiness 是执行属性，只有在影响可复用结果和后端兼容时才进入 key。

## 8. Cache 与比较

- RenderedMemory 不能在颜色/dynamic-range policy 不兼容的 DisplayContext 间复用；
- 同一 ContentID 在 SDR/HDR、P3/sRGB 和 attachment policy 下可以产生不同 DecodeKey/RenderKey；
- snapshot/quality 测试必须在受控显示/色彩环境进行；
- 比较 decoded megapixels 时同时记录实际 pixel format 和 bytes-per-pixel，避免只看像素数掩盖 16-bit/HDR 成本。

## 9. 测试矩阵

- **IMG-PT-001**: EXIF orientation 的 target-size decode 与全尺寸参考一致；
- **IMG-PT-002**: P3/sRGB 不错误共享 RenderKey；
- **IMG-PT-003**: profile 缺失使用稳定默认；
- **IMG-PT-004**: HDR→SDR tone-map policy 改变导致 RenderKey 改变；
- **IMG-PT-005**: gain map 请求与不请求产生不同 DecodeKey；
- **IMG-PT-006**: resize/downsample 不静默丢失颜色描述；
- **IMG-PT-007**: alpha/pixel format 转换结果与参考一致；
- **IMG-PT-008**: fully decoded 结果不重复 display preparation；
- **IMG-PT-009**: unsupported HDR/attachment 按 policy fallback 或拒绝；
- **IMG-PT-010**: 颜色与动态范围测试覆盖最低系统和当前设备；
- **IMG-PT-011**: 外部传入的 ImageProbe 必须与实际 bitstream 的尺寸、帧数和 orientation 一致；不一致时解码前拒绝。