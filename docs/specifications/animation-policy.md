# 动画图像解码与播放策略

> **状态：Proposed，Phase 2/Experimental 规格；不阻塞 Phase 0a。**

## 1. 目标

动画不是“多张静态图数组”。帧时序、loop、canvas、disposal/blend、增量解码、帧缓存和可见性共同决定正确性与资源成本。Fovea 不默认把所有帧完整解码进内存。

## 2. 动画表示

```text
AnimatedImageAsset
├── ContentID
├── canvas pixel size
├── frame count
├── loop count
├── frame timing table
├── disposal/blend metadata
├── decoder fingerprint
└── frame provider / decode window
```

动画对象与静态 `DecodedImage` 使用不同的缓存 value 类型和 cost model。第一帧可以作为静态 fallback，但不能冒充完整动画结果。

## 3. DecodeKey

动画 DecodeKey 至少加入：

```text
ContentID
+ target pixels
+ color/dynamic-range policy
+ animation policy version
+ timing normalization policy
+ frame decode strategy
+ decoder fingerprint
```

改变 frame timing clamp、静态化策略或 target pixels 必须自然 miss。

## 4. 帧策略

候选模式：

```text
firstFrameOnly
streamingWindow
boundedFrameCache
predecodeAll（仅小动画显式允许）
```

默认根据：

- canvas bytes；
- frame count；
- 帧依赖/disposal；
- 可见性；
- platform profile；
- 当前 memory pressure；

选择受控窗口。`predecodeAll` 必须通过总 decoded bytes 与单对象 hard cap。

## 5. 时序正确性

- 优先使用格式的 unclamped delay（可获得时）并保留 loop semantics；
- 0、负值、NaN 或极端短 delay 使用版本化的安全 normalization policy；
- normalization 不能作为无版本“经验规则”隐藏在 decoder 中；
- 播放调度使用 monotonic clock；
- 丢帧时按 timeline 前进，不通过无限加速追帧；
- 后台恢复后默认从合理时间点继续或重启，策略显式。

## 6. 生命周期

- offscreen 默认暂停播放并释放非必要预解码帧；
- view 消失取消 UI subscriber，但 OriginalEncoded 是否保留由普通缓存策略决定；
- App background 默认暂停动画 decode/display；
- memory pressure 下缩小 frame window，critical 时退化第一帧或停止；
- Reduce Motion 的默认行为由 App policy 决定，但 Fovea 提供 `.firstFrame`/`.playOnce`/`.normal` 明确选项；
- 多个 view 显示同一动画可以共享 encoded/container metadata，但 playback clock 默认独立，除非显式同步。

## 7. 缓存

- OriginalEncoded 按普通规则缓存；
- container metadata 可进入 MetadataMemory；
- 解码帧使用独立 `AnimationFrameMemory` 预算，不与静态 RenderedMemory 混成一个对象 cost；
- frame cache key 包含 frame index、target/representation policy 和 decoder fingerprint；
- 不把播放当前位置、view clock 或 dropped-frame 状态持久化；
- DerivedEncoded 默认不为每帧生成独立文件。

## 8. 安全限制

除通用 DecodeLimits 外，还限制：

```text
maximumCanvasPixels
maximumFrameCount
maximumTotalDecodedFrameBytes estimate
maximumLoopWork for preview/testing
maximumMetadataPerFrame
```

畸形 disposal、越界 frame rect、递归附件或异常 timing 返回结构化 decode/security error。

## 9. 可观测性

记录：

```text
frame strategy
frame cache bytes/hit rate
frames decoded/displayed/dropped
average decode lead time
pause/resume reason
memory-pressure degradation
```

不记录资源稳定摘要或私有 URL。

## 10. 测试

1. GIF/APNG 的 timing、loop、disposal 与参考实现一致；
2. 大动画不执行无界 all-frame decode；
3. offscreen/background 停止帧工作；
4. memory pressure 缩小窗口且不崩溃；
5. 第一帧 fallback 不污染完整动画 DecodeKey；
6. 多 view 独立 clock 不互相改变进度；
7. timing policy 变化使缓存自然失效；
8. cancel/seek/finish 竞态不 double-complete；
9. malformed frame rect/timing 被安全拒绝；
10. frame cache cost 与真实 bytes 基本一致。
