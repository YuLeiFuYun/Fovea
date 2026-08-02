# 比较本体与能力分类

> **状态：Active。** 本规格定义 Fovea 比较研究中的对象类别、能力语言和声明状态。机器源为 `docs/research/comparison-ontology.json`。

## 1. 目的

比较数量不是目标。目标是覆盖不同技术原型，同时阻止把运行环境、功能语义或可靠性等级不同的系统塞入同一排行榜。任何新库、论文实现或原生基线必须先分类，再决定它能贡献端到端数值、组件数值、challenge，还是只提供设计参考。

## 2. 七类对象

| 类别 | 示例 | 可否进入 iOS 端到端排名 |
|---|---|---|
| `platform-baseline` | URLSession + ImageIO、AsyncImage | 可以，但绑定 OS、Xcode 与设备 |
| `client-pipeline` | Fovea、Nuke、Kingfisher、SDWebImage | 可以，且必须使用统一 adapter 和语义剖面 |
| `portable-mechanism` | single-flight、准入、调度器 | 不直接进入端到端排名 |
| `cache-system` | PINCache、Caffeine、Moka | 只在缓存 Lab 的同语义分层中比较 |
| `codec-engine` | ImageIO、libvips、image-rs | 只在相同像素质量契约下比较 |
| `algorithm-simulator` | libCacheSim、离线 oracle | 只报告 trace 和 regret |
| `adjacent-system` | CDN、浏览器、数据库 | 只贡献设计、故障与 challenge |

## 3. 能力不是项目标签

能力以可观察契约定义，例如 request coalescing、target decode、durable disk cache、progressive、animated、resume 和 lifecycle。一个项目可以覆盖多个能力；同一能力也可以由多个不同类别的系统贡献证据。

`capability-gap` 必须保留在矩阵中。未实现不能通过删除 workload、指标或竞品来消失。

## 4. 声明状态

正式汇总只允许输出：

```text
proven-in-finite-model
empirically-superior
empirically-equivalent
empirically-noninferior
inconclusive
inferior
not-comparable
capability-gap
invalid-evidence
```

“支持”“很快”“表现不错”不能代替上述状态。有限模型结论不能冒充无限输入或真机经验结论。

## 5. 跨语言规则

跨语言默认比较架构、状态机、算法、trace 和 challenge。只有当代码运行在同一设备、使用相同 ABI 输入输出、满足相同质量与资源契约时，组件绝对性能才可直接比较。跨平台 FPS、端到端毫秒和能耗不得构造全球总榜。
