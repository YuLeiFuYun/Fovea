# Phase 0b 收口与 Phase 1 入口

> **状态：Active。** 本文是阶段转换的权威入口。机器状态位于 `phase0b-status.json`；阶段准备可以先行，但只有全部毕业条件具备可信证据后，才能把项目状态改为 Phase 1。

## 1. 当前裁决

```text
current stage: Phase 0b closeout
Phase 1 preparation: allowed
Phase 1 declaration: blocked
```

当前实现已经覆盖原路线图中多数“确定性生产核心”能力，但这不能替代 Phase 0b 的存在性裁决。阶段转换取决于外部语料、同方法竞品适配器、真机复现、可信 CI、独立验证和毕业报告，不取决于代码量或本地测试总数。

## 2. Phase 1 的重新定义

Phase 1 与 **Core v1 Candidate Hardening** 等价，不再重复建设已经存在的 URL 管线、目标像素解码、缓存、single-flight 和三套 UI 适配器。其目标是把已证明的内部实现收缩为可发布候选：

1. 收缩公共 API，将普通集成面、Advanced 逃生口和内部实现面明确分离；
2. 实现并验证 File/Data/Asset source 的身份、失效、权限和持久化边界；
3. 冻结版本化 Private Image Cache Profile v1 Candidate；
4. 建立至少一个真实宿主 App 的兼容周期；
5. 固化错误、取消、默认值、配置、磁盘 generation 与迁移政策；
6. 建立 API diff、编译器矩阵、二进制体积、启动成本、SBOM 与发布 provenance；
7. 在 Phase 1 内仍允许破坏 API，Stable Core 继续为空，直到兼容周期和 Accepted ADR 完成。

Phase 1 不包含 progressive、animation、JPEG AI、生成式增强或学习型默认缓存策略；这些继续留在 Phase 2 / FoveaLab。

## 3. Phase 0b 毕业条件

以下条件全部满足后，才能把 `phase1DeclarationAllowed` 改为 `true`：

- G0 schema/generation、身份 golden vectors、priority/revoke、外部 HTTP required corpus 全部通过；
- W3 的跨账户像素、metadata/blob coupling、no-store reusable write、logout residue、跨 origin Authorization 泄漏和 revoke race residue全部为零；
- A 级七项比较矩阵完成：Apple Native、Fovea、Nuke、Kingfisher、SDWebImage 与 PINRemoteImage 使用 headless 合同，Apple AsyncImage 与 Fovea 使用配对 SwiftUI surface；AlamofireImage 只作 B 级补充；
- W1/W2 至少各有一个统一方法可比较指标；
- 一台当前主流/中档物理设备和一台较低性能物理设备均完成复现；
- 选择并通过 Performance Path 或 Correctness Path；
- 所有 raw trace、不可比指标、coverage gap、竞品配置和失败项公开；
- 最终 clean commit 获得 protected trusted CI、双架构 identity 证据和当前 tree Evidence Bundle；
- held-out evaluator 与 accountable human comprehension attestation 完成；
- 生成绑定最终提交的 Phase 0b graduation report。

模拟器不能代替物理设备。单设备结果可以推进适配器和实验设计，但不能完成双设备毕业条件。

## 4. 当前可用设备策略

当前唯一物理设备是 iPhone 16e，A18、4 核 GPU、2532×1170 显示屏，运行 iOS 27 beta。它的角色固定为：

```text
primary-current-mid
```

它不是“最低性能档”。当前允许在该设备上完成：

- workload 与 adapter 功能等价性；
- target-pixel/output correctness；
- 取消、缓存状态和运行顺序校验；
- 同一设备、同一系统、同一数据集下的探索性比较；
- Instruments 模板、采样稳定性和噪声分析；
- provisional W1/W2/W3 原始 trace。

Beta OS 结果必须标记 `provisional`，不得支持 release 性能声明。正式毕业前必须：

1. 在该设备的稳定公开 iOS build 上复跑；
2. 再取得一台较低性能物理设备复跑。

第二台设备可以来自借用、设备实验室或受控远程真机服务，但必须保留型号、OS build、热状态、供电、网络和运行清单；不得保存 UDID、序列号、用户设备名或账户信息。

## 5. 比较实验结构

`Benchmarks/ComparativeLab` 是独立于生产依赖图的比较实验根：

- `ComparativeLabCore` 定义统一 request、取消句柄、目标像素、缓存来源、粗粒度失败分类和脱敏结果工件；
- Apple Native、Fovea、Nuke、Kingfisher、SDWebImage、PINRemoteImage 与 B 级 AlamofireImage 各自位于隔离 adapter/App；Apple AsyncImage 和 Fovea SwiftUI 使用两个独立 target 运行同一 surface trace；
- 上游源码由 `docs/research/comparator-lock.json` 固定完整 40 位 commit；
- `scripts/prepare-comparator-sources.py` 将源码放入 `.artifacts`，不会修改 Fovea 的生产 SwiftPM 依赖；
- `scripts/verify-comparative-lab.py` 验证核心契约；设置 `RUN_COMPARATOR_ADAPTERS=1` 时额外准备和编译适配器；
- 原始 URL、设备唯一标识和自由文本错误不得进入运行结果工件。公开数据集选择清单可以保存 Commons 来源 URL、许可和文件名，但不能混入凭证或签名参数。
- `experiment-plan.json` 在正式结果前固定重复次数、比较顺序、主指标和统计方法；`dataset-selection.json` 固定 128 项 W1 素材选择。远端字节捕获和本地 origin runner 尚未完成。

当前锁定与平台基线：

| Comparator | Version / Identity | Commit / Binding | Tier |
|---|---|---|---|
| Apple URLSession + URLCache + ImageIO | platform build | Xcode build + OS build + device profile | A |
| Apple AsyncImage | platform build | Xcode build + OS build + device profile | A |
| Nuke | 13.0.6 | `63a8fcbd6621340a2410bc3e9575ac97058615f4` | A |
| Kingfisher | 8.11.0 | `410984bf301f4fa224fe56277b3f8672cc465c79` | A |
| SDWebImage | 5.21.7 | `2de3a496eaf6df9a1312862adcfd54acd73c39c0` | A |
| PINRemoteImage | `releases/p14.31` | `c0d5cfa1947f2456ddb321a85b347b3d60d83254` | A |
| Fovea | current worktree | HEAD + tree digest + dirty state | A |
| AlamofireImage | 4.4.0 | `4cf73d601c482b7d77bae47de3ef1b8bcf328ec1` | B |


## 6. 设备接入

连接 iPhone 后执行：

```sh
DEVELOPER_DIR=$(scripts/select-xcode.sh)
export DEVELOPER_DIR
python3 scripts/capture-ios-device-profile.py
```

捕获器只输出：

- marketing model；
- product type；
- OS version/build/channel；
- benchmark role；
- 非唯一硬件描述。

它不会输出设备名、UDID、序列号、主机名或账户信息。当前设备未连接时，声明档案保持 `declared-not-captured`，不能伪装为已运行证据。

## 7. 执行顺序

1. 保持主线功能冻结，先完成比较 App 与统一 workload runner；
2. 在 iPhone 16e beta 环境完成 provisional runs，修正实验方法和 adapter 等价性；
3. 清理工作树并获得最终提交的 protected CI；
4. 在稳定 iOS 上复跑 iPhone 16e；
5. 获取第二台较低性能设备复跑；
6. 选择 Performance 或 Correctness Path；
7. 生成毕业报告；
8. 修改机器状态并正式进入 Phase 1。

任何步骤都不得通过降低门槛、把 beta 当 stable、把模拟器当真机或把 smoke 当正式 benchmark 来“完成”。
