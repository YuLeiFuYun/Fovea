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

脚本保留 `.xcresult`、xcodebuild 日志、Simulator/Xcode/Swift 身份、Fovea commit/tree、工作树状态以及 ImageCraft/Akashic 精确 revision。v2 还从每次 XCTest 执行解析 Base64 JSON 时间线，保存 URLSession 累计字节、generation/sourceByteCount、preview/final 发布、CADisplayLink 观察、publication fence 与 suppression 顺序。trace 在单次测试内强持有参与关联的 CGImage，防止 allocator 复用指针地址造成 preview/final 假碰撞；进程内指针只作为存活期关联 token，写入报告前会映射为 `preview(generation)`、`final` 或 `other`，不会被当作跨运行身份。runner 对每份样本独立重算不变量和统计。正式证据必须从 clean commit 捕获。

## Clean formal Simulator evidence

版本化证据位于 `docs/research/progressive-presentation-simulator-evidence-2026-08.json`，绑定 clean Fovea commit `3c82fdc3b2633e77acfcd204c264cca5ed1a4fd1`、tree `96fd9cbc03ef9951f4bf830d960ef98b4954046f`、ImageCraft `bc93b8df0337d7a57779b53106dd744ad97b095e` 与 Akashic `2715f23d50b5a17b7328be41608eaf1b1c99b0d6`。iPhone 17 Pro / iOS 27.0 Simulator 上每个测试重启进程执行五轮，共 10/10 通过并嵌入 10 份结构化样本。

完整场景五轮均收到 23 个 chunk，产生 generation `[1,2,3,4]`，对应 source byte count `[32768,65536,81920,163840]`。从测试 trace 起点计，CADisplayLink 首次观察 preview 的 median 为 129,144,833 ns，观察 final 的 median 为 812,619,167 ns；两者的 median 可见窗口按逐样本差值重算为 683,474,334 ns。首 preview 生成到 CADisplayLink 观察的 median 为 3,213,625 ns，final 发布到观察的 median 为 8,890,417 ns。

身份替换五轮均在第一个 32 KiB chunk 后触发；publication fence 到旧 preview suppression 的 median 为 138,125 ns，最大为 252,292 ns，替换后观察到旧 preview 的次数为 0。上述数值是 Simulator 调度与该固定 test-only pacing 下的描述性证据，不是生产网络、Core Animation/GPU 或物理屏幕性能声明。

```sh
python3 scripts/validate-progressive-presentation-evidence.py \
  docs/research/progressive-presentation-simulator-evidence-2026-08.json
```
