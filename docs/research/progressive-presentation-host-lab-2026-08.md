# Progressive presentation host lab（2026-08）

## 问题

ImageCraft 已实现有界 JPEG progressive session，但 Fovea 的生产 `URLSessionTransport` 仍在完整 staging、长度与摘要验证后才交付正文。需要先证明宿主能够正确消费真实 URLSession 分块，并在 view identity 变化时先关闭像素发布权限，再等待 codec cancellation。

## 实验边界

`Tests/FoveaTests/ProgressivePresentationHostTests.swift` 在 iOS Simulator 测试宿主中建立：

```text
test-only URLProtocol
→ URLSessionDataDelegate chunks
→ ImageCraft ImageProgressiveDecodeSession
→ Fovea ProgressiveImageLoading events
→ FoveaImageView / ImageDisplaySession identity gate
→ UIImageView
→ CADisplayLink observation
```

公共领域 USDA progressive JPEG 固定在 `Sources/FoveaTesting/Fixtures`，manifest 绑定字节数、尺寸、SHA-256 与来源。

`UI-PT-029` 要求 CADisplayLink 至少观察到一个 preview CGImage identity，随后再观察 final identity。多个 codec generation 可以合法地在帧之间合并。

`UI-PT-030` 使用测试 barrier 把一个已生成 generation 暂停在发布判定前；随后替换 `FoveaImageView` identity。旧 stream 必须先关闭 publication fence，释放 barrier 后旧像素只能被抑制，不能进入新 identity。

## 不支持的结论

- CADisplayLink callback 不是 Core Animation commit、GPU present 或物理屏幕 scanout 时间；
- test-only loader 绕过生产 transport 的 staging、hash、ContentID、namespace 和持久提交边界；
- Simulator 不提供真机能耗、热状态或跨设备性能保证；
- 该实验不证明生产 progressive path 已完成。

## 运行

```sh
python3 scripts/run-progressive-presentation-simulator-lab.py --iterations 3
```

脚本保留 `.xcresult`、xcodebuild 日志、Simulator/Xcode/Swift 身份、Fovea commit/tree、工作树状态以及 ImageCraft/Akashic 精确 revision。正式证据必须从 clean commit 捕获。
