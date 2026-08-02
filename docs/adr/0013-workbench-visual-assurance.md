# ADR-0013：Workbench 视觉保证、生成工程与统一运行时宿主

- **状态**：Accepted
- **日期**：2026-07-28
- **范围**：`Examples/FoveaWorkbenchApp`、`scripts/audit-workbench-visuals.py`、`scripts/verify-ios-example.py`

## 背景

Workbench 同时承担产品示例、协议实验和可复查证据三种职责。仅靠“能编译”“元素存在”或单台设备截图，无法证明以下事实：

1. 新增 Swift 源文件确实进入 Xcode target，而不是只存在于磁盘；
2. 正常入口、专题直达入口和场景工坊直达入口使用同一条已初始化图片管线；
3. iPhone 与 iPad 的关键界面不存在缩字补丁、双重图片比例、低于 44 pt 的按钮、未声明的水平逃逸或大面积图片重叠；
4. 截图、Accessibility 树与几何数据来自同一冻结代码树，而非人工挑选的成功画面。

本次改进实际发现了两个反例：DesignSystem 源文件已被页面引用，但陈旧 `project.pbxproj` 未把它们编入 target；DEBUG 直达路由绕过了唯一位于 `WorkbenchRootView` 的 `model.start()`。这说明生成工程与 App 生命周期必须成为正式证明对象。

## 决策

### 1. App 根部拥有运行时生命周期

`WorkbenchAppHost` 位于所有路由之上，统一负责：

- 启动 `WorkbenchAppModel`；
- 传播 `scenePhase`；
- 呈现运行错误与重试操作；
- 发布稳定的 `runtime.state` Accessibility 值。

`WorkbenchRootView` 只负责标签页与页面组合，不再拥有重复的启动或错误副作用。UI 测试快捷路由可以绕过导航，但不得绕过运行时。

### 2. `project.yml` 是 Xcode 工程权威来源

固定 XcodeGen 版本生成以下三类受检文件：

- `project.pbxproj`；
- 共享 scheme；
- workspace 内容文件。

验证器在生成前后比较全部文件摘要，并拒绝：

- 非 canonical 的 `Fovea -> ../..` package 路径；
- 缺失 DesignSystem 或视觉测试源文件；
- 已删除的蓝色/橙色占位素材；
- 含临时 sandbox 名称的工程引用。

不得手工拼接 PBX 条目修复漂移。

### 3. 视觉证据是三联件

每个设备族固定七个检查点，同时导出：

- 屏幕截图；
- Accessibility 树；
- 几何 JSON。

完整矩阵为 iPhone 与 iPad 各七项，共 14 份截图、14 份几何和 14 份 Accessibility 树。Python oracle 读取附件，而不是只信任 XCTest 成功状态。

oracle `1.2.0` 自动检查用户可见英文、低信息素材、图片比例冲突、缩字、offset/overlay 补丁、触控尺寸、未声明的水平逃逸和图片重叠。纵向滚动内容不因位于首屏下方被判错；以稳定 `ecology.featured.*` 身份声明的横向轨道项目及其同框子图也不被误判，但普通水平逃逸仍失败。

### 4. 警告不冒充通过或失败

当前两张 960 px 宽的本地素材保留为分辨率警告。现有捕获容器没有证明像素不足，因此不升级为错误；若后续用于更大的高倍率 Hero，必须替换素材或收窄容器契约。报告必须保留警告，不能用“零问题”概括。

### 5. 发布验证默认包含视觉门

`verify-ios-example.py` 在未指定 `--skip-ui` 或 `--skip-visual` 时执行严格视觉矩阵。跳过视觉只允许形成明确降级的本地验证，不得作为完整视觉发布证据。

### 6. 行为测试按交互契约分配设备

视觉矩阵在 iPhone 与 iPad 各采集七个相同检查点；行为矩阵不机械地让每项测试在每台设备重复执行：

- 15 项 compact-width 行为按源码顺序分成三个五测试 iPhone 分片；
- 4 项原生 iPad 行为分成两个两测试分片；
- `DEMO-PT-024` 验证五张公共导航卡及其目的页，使用独立 regular-width iPad 分片；
- 分片间 shutdown/boot 对应设备，单个基础设施故障只重跑所属分片；
- 发布报告仍只形成 `ui-tests=15` 与 `ipad-ui-tests=5` 两个 phase，分片不改变或跳过契约。
- iPad Feed 分片必须等待本地化的“脚本 快速反向 已完成”与“内存占用 +”状态，再切换 UIKit host 并到达动态计算的最后一个 cell；旧英文 `footprint +` 不属于当前产品契约。

这一分配来自可复现的 oracle 缺陷：单列 iPhone 上，通用滚动辅助函数从“系统地图”返回后向错误方向搜索前一张“概念索引”卡，引发数百秒 Accessibility 查询风暴；同一导航契约在 iPad 多列牌组中 54 秒通过。门禁因此把证明放到契约对应的布局，不放宽目的页断言，也不删除测试。

Simulator 的 `kAXErrorIPCTimeout`、`kAXErrorServerNotFound`、事件合成超时、active-application 查询失败、设备准备失败，以及设备族采集在 600 秒内未封口，均归类为基础设施故障。只有这些情况允许一次重试，并且重试前必须 shutdown/boot 受影响设备；普通 XCTest 断言失败不得借此重试或降级。设备族 watchdog 防止 testmanagerd 停在 `wait_for_debugger` 时占满整套 90 分钟聚合预算。

## 测试与追踪 ID

- **AIQA-GATE-015**：iOS 示例验证必须以固定 XcodeGen 版本重现 PBX、scheme 与 workspace，拒绝缺失源文件、过时素材和临时路径，并默认执行严格双设备视觉门。
- **DEMO-PT-035**：正常入口、专题直达入口和场景工坊直达入口共享 App 根部运行时宿主；直达页面在执行维护动作前必须报告 `runtime.state=ready`。
- **DEMO-PT-036**：iPad Feed 必须以当前中文 accessibility 状态证明快速脚本完成和内存指标发布，然后验证 UIKit collection 与最后一个动态 cell。
- **VISUAL-PT-001**：iPhone/iPad 各七个检查点必须同时导出截图、几何和 Accessibility 树，并由版本化独立 oracle 审查。

## 被否决的方案

- **只检查源码目录**：无法证明文件进入 Xcode target。
- **只运行 UI 元素存在断言**：无法证明布局、触控尺寸或副作用结果。
- **把每个 DEBUG 路由自行调用 `start()`**：重复副作用，未来新增入口仍可能漏掉。
- **把所有首屏外元素视为越界**：会误报正常纵向页面和横向轨道。
- **人工编辑 PBX**：不可重现，容易写入隔离目录名或遗漏测试 target。

## 后果与边界

优点是生命周期、生成工程和视觉矩阵成为可重复的项目原生证据；代价是完整本地验证耗时增加，需要可用的 iPhone/iPad Simulator。该证据仍是本地 simulator 证据，不代表真机能耗、稳定系统版本、真实公网、企业代理或第三方服务可用性。
