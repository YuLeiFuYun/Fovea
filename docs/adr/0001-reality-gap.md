# ADR-0001：现有 ImageCraft / Akashic 与目标架构的现实差距

- **状态：Accepted as assessment**
- **日期：2026-07-18**
- **范围：审查时当前可访问源码树的结构审查**

## 背景

Fovea 架构将 ImageCraft 定义为纯图像引擎，将 Akashic 定义为不知道图片、URL、HTTP 和 UI 的通用缓存。审查时可访问的现有原型尚未实现这一边界，因此不能在设计文档中用“已有仓库”暗示目标模块已经可直接组合。

## 已验证现状

### Akashic

当前源码中存在：

- `ElysiumImageSerializer.swift` 直接 `import UIKit` 并序列化 `UIImage`；
- `Mnemosyne.swift` 直接 `import UIKit`，为 `UIImage` 实现成本计算；
- `AkashicWrapper.swift` 为 `UIImage`、`UIImageView` 提供 wrapper；
- `Elysium.swift` 依赖 `UIKit.UIApplication`；
- 内存和磁盘缓存、图片适配与平台生命周期位于同一 product；
- 当前仓库根目录未发现 `Package.swift`，产品边界尚未通过 SwiftPM manifest 表达。

结论：Akashic 是有用的缓存原型，但当前不是目标架构所说的“平台中立、图片无关的通用缓存核心”。

### ImageCraft

当前源码主要包括：

- `UIImage` 圆角、resize 和 downsample 扩展；
- `UIImageView` 动画和显示扩展；
- 基于 UIKit 的动画模型；
- ImageIO 目标尺寸缩略解码方法；
- SVG 代码中存在对未公开 selector/符号的动态调用与 `unsafeBitCast`；
- 编解码、处理、UI 和实验 SVG 路径位于同一 product；
- 当前仓库根目录未发现 `Package.swift`。

结论：ImageCraft 已具备有价值的 downsample 与处理原型，但还不是目标中的 codec registry、DecodePlan、TransformPlan、增量解码和多平台核心。

## 决策

1. 现有代码不作为 Fovea 公共协议的兼容约束。
2. Phase 0a 可以复用经过测试的局部算法，但目标边界优先于源码兼容。
3. Akashic 需先把 UIKit 图片适配迁出 Core，再讨论缓存策略升级。
4. ImageCraft 需先拆出 Core/ImageIO/Processing/UI 边界，并移除依赖私有 API 的 SVG 主路径。
5. Fovea 在边界稳定前使用 workspace/path dependency 联调，不立即形成三仓库独立发布矩阵。
6. 每次决定“复用还是重写”必须有测试、基准或维护性依据，不因已有代码量产生沉没成本偏见。

## Phase 0a 迁移清单

### Akashic

- [ ] 建立 SwiftPM manifest 和最小平台矩阵；
- [ ] Core 不 import UIKit/AppKit；
- [ ] UIImage/NSImage serializer 迁为独立 adapter；
- [ ] 平台内存压力监听放入条件模块；
- [ ] cost 改为插入参数或 `CostEstimator`；
- [ ] 建立线程安全与崩溃恢复测试；
- [ ] 输出访问 trace，支持策略离线回放。

### ImageCraft

- [ ] 建立 SwiftPM manifest；
- [ ] `DecodedImage`/`DecodePlan`/`TransformPlan` 值模型；
- [ ] ImageIO target-size 解码进入独立 product；
- [ ] UIKit/AppKit 显示适配与图像核心分离；
- [ ] SVG 私有 API 路径移除或隔离为明确实验插件；
- [ ] DecodeLimits 与恶意输入 corpus；
- [ ] downsample 的颜色、orientation、scale 和 HDR 正确性测试；
- [ ] 动画帧调度与静态解码分离。

## 后果

短期会增加重构量，但避免 Fovea 被现有原型的 UIKit 耦合和 API 形态绑死。AI 加速可降低迁移实现成本，因此更应选择正确边界，而不是为保留少量原型代码妥协架构。
