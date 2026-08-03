# Fovea Comparative Lab

该目录承载 Phase 0b 的同方法竞品实验，不属于 Fovea 生产依赖图。它只允许生成有限作用域技术证书，不生成无边界“世界最好”营销句。

## 比较治理

本 Lab 受以下机器工件共同约束：

- `../../docs/research/comparison-ontology.json`：对象类别、能力与语义维度；
- `../../docs/research/comparator-registry.json`：直接对手、Challenge 来源与研究对象资格；
- `../claim-policy.json`：L1–L4 证书、取向化 loss、TOST/非劣/优越与 scoped claim；
- `../statistical-claim-families.json`：六个预注册声明族和主 endpoint；
- `../../docs/research/negative-results.json`：必须保留的反例与拒绝结论；
- `experiment-plan.json`：workload、平衡交错、重复次数、thermal/稳态规则和 metric margin。

性能排名前必须通过 `scripts/check-comparison-governance.py`。语义不等价输出 `not-comparable`，能力缺失输出 `capability-gap`，证据不足输出 `inconclusive`；三者都不能折算为零分或并列。没有绑定 claim-family digest 的旧工件只作描述。

## 当前对象与资产

A 级统一矩阵：Apple URLSession + URLCache + ImageIO、Apple AsyncImage、Nuke 13.0.6、Kingfisher 8.11.0、SDWebImage 5.21.7、PINRemoteImage `releases/p14.31` 与 Fovea。AlamofireImage 4.4.0 仅为 B 级补充，不能满足 A 级槽位。

- `ComparativeLabCore`：统一 request/target/cancel/result、Git/platform 双身份与脱敏工件模型；
- 六个 headless adapter/App：Apple Native、Fovea、Nuke、Kingfisher、SDWebImage、PINRemoteImage；
- W2 headless 六实现与 SwiftUI 配对 surface 共用同一 `NWListener` 真实 loopback HTTP origin；Apple Native 由 URL Loading System 自动执行 `URLCache` 协议缓存，adapter 不手工读写缓存；
- W1/W3/W7 保留确定性 `URLProtocol` 夹具，以支持精确取消字节、离线切换、redirect 与安全故障注入；
- 一个配对 SwiftUI surface：Apple AsyncImage 与 FoveaResponsiveImage 使用相同 loopback origin、trace 与采样器；
- 一个 B 级保留 App：AlamofireImage；
- `challenge-suite.json`：来自 Swift、Android 与缓存项目的可追踪 Challenge，不替代原生测试；
- `device-profiles/iphone-16e-ios27-beta.json`：已脱敏的当前 beta 真机档案；
- 128 项内容寻址数据集及真实 EXIF/sRGB/target-pixel W2 probe；
- schema 3 envelope：绑定 source tree、实验计划、声明族，并记录 thermal 状态。

## 执行

```sh
python3 scripts/verify-comparative-lab.py
RUN_COMPARATOR_ADAPTERS=1 RUN_COMPARATOR_IOS=1 \
  python3 scripts/verify-comparative-lab.py
python3 scripts/run-upstream-image-loader-tests.py --allow-failures
python3 scripts/run-comparative-simulator-lab.py --initialize-simulator-only
python3 scripts/run-comparative-simulator-lab.py --build-only
python3 scripts/run-comparative-simulator-lab.py --install-only
python3 scripts/run-comparative-simulator-lab.py --skip-build --skip-prepare
python3 scripts/run-asyncimage-simulator-lab.py --build-only
python3 scripts/run-asyncimage-simulator-lab.py --install-only
python3 scripts/run-asyncimage-simulator-lab.py --skip-build
python3 scripts/run-w7-concurrency-lab.py                 # W7 V8 六项 A 级 headless
python3 scripts/run-comparative-device-lab.py --mode calibration
```

Simulator runner 使用独立设备 `Fovea Comparative iPhone 17e R26`，并把设备绑定到已验证的 iOS 26.4.1 build `23E254a` 的精确 runtime bundle path，而不是有歧义的 `com.apple.CoreSimulator.SimRuntime.iOS-26-4` identifier。绑定记录写入 `.artifacts/comparative-simulator-device.json`；即使同 identifier 的其他 build 已挂载，也以专用设备的 live 进程路径验证实际 build，错误 build 会自动关机并拒绝继续。首次启动允许最多 900 秒完成系统数据迁移，但仍是有界操作。

构建、初始化、安装和测量必须分离。`--initialize-simulator-only` 只完成精确 runtime 解析与首次启动，`--install-only` 只安装现有 Release app；二者都不生成测量。 三个 Simulator 构建入口统一使用 `-disableAutomaticPackageResolution`、`-onlyUsePackageVersionsFromResolvedFile` 与 `-skipPackageUpdates`，已锁定的比较构建不得在重放时联网更新依赖。新建设备或执行未完成的首次启动前，runner 会写入 `.artifacts/comparative-initialization-host-preflight.json`，并要求连续三个样本 CPU idle 均不低于 65%、聚合磁盘吞吐均不高于 12 MB/s、没有其他 `xcodebuild`、Swift 编译或竞争性 `simctl` 操作。该门失败时不会调用 `simctl create` 或 `simctl boot`。headless 测量只接受 `--skip-build --skip-prepare`，SwiftUI 配对测量只接受 `--skip-build`；测量前使用独立的 `.artifacts/comparative-host-preflight.json` 执行相同静默门。

当前专用模拟器的首次启动未完成，已按策略标记为不可复用；本地设备标识仅写入被忽略的 `.artifacts`，不得进入仓库或证据摘要。创建替代设备仍受初始化宿主静默门约束；在主机达到阈值前不会创建设备，也不会生成性能结果。

SwiftUI surface 的预构建 app 不直接从 DerivedData 安装。两方都复制到 `.artifacts/asyncimage-lab/InstallStaging`，递归清理扩展属性，在资源复制完成后统一执行 ad-hoc 重签名，并通过 `codesign --verify --deep --strict` 后才交给 `simctl install`；staging manifest 记录源/目标 executable SHA-256 与字节数。

Simulator 结果始终 provisional，只验证合同、运行时和探针。物理 formal block 必须：

- 从 nominal thermal state 开始；
- 一个 workload/cache/repetition 的六项 A 级 headless 顺序构成原子 block；SwiftUI surface 使用独立配对 block；
- 任一 App 在运行中离开 nominal，整块删除、冷却并从第一个 comparator 重跑；
- 固定最大 warmup，禁止看到结果后无限丢弃“未稳态”样本；
- beta OS、单设备或 dirty tree 均不得生成 release claim。

## 已观察到的语义差距

当前 Simulator calibration 中，W1/W2 可以进入后续同语义研究；W3 硬门揭示外部库并非都具备 Fovea 的 private-cache/revoke/redirect 合同：

- Nuke、SDWebImage：no-store 可复用写、revoke race 残留、跨 origin Authorization 三项不满足；
- Kingfisher、AlamofireImage：历史五实现校准中跨 origin Authorization 剥离不满足。

Apple Native 与 PINRemoteImage 的最终 W1-W3 语义结果尚待当前源码摘要下的完整重跑；旧结果不能外推给新增对象。Apple AsyncImage 不暴露 W3 headers、namespace、selective revoke 或 W7 headless subscriber 合同，因此明确输出 `not-comparable`，不按零分处理。

这些结果按 `capability-gap` / `not-comparable` 处理，不通过加权总分抵消，也不据此把所有其他 workload 自动判输。

## 尚未完成

- clean source 与 claim-family digest 绑定的正式真机重复实验；
- iPhone 16e 签名/provisioning；
- 同机稳定公开 iOS 复跑；
- 第二台较低性能物理设备；
- held-out trace、独立复现与最终毕业报告。

### CoreSimulator 恢复与健康门

实际实验 runner 在调用 `simctl` 前检查全局 `simdiskimaged`/CoreSimulatorService、注册设备的 `launchd_sim`，以及 SpringBoard、backboardd、runningboardd、lsd 四个安装/启动关键服务；这些关键进程处于 `U`/`Us` 状态时会被拒绝，并写入 `.artifacts/comparative-coresimulator-health.json`。目标设备的非关键 daemon 异常与其他设备异常分别记录为 target-noncritical 和 unrelated count，不会在容器与 SpringBoard 探针仍可用时制造假阻断。独立 `check-comparative-coresimulator-health.py` 仍执行全局检查。首次启动超时会写入设备注册表；该半初始化设备不得复用，必须归档后以精确 `23E254a` bundle 重新创建。

管理员恢复命令已封装为：

```sh
scripts/recover-comparative-simulator.sh
```

该脚本重启 system `simdiskimaged`、用户 CoreSimulatorService，验证 `simctl` 响应并执行独立健康检查。若健康检查仍发现不可中断进程，必须重启主机。恢复后不得直接复用标记为 `incomplete-first-boot` 的设备。
