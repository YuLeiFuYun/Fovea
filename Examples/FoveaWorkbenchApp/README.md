# Fovea Workbench — 生态超载世界图谱与图片管线工程证据 App

Fovea Workbench 是 iOS / iPadOS 15.0+ 的完整集成宿主。普通启动不是随机图库，也不是内部调试菜单，而是一部面向大众的生态超载世界图谱；同一组页面同时承担真实图片的加载、复用、取消、裁切、离线、清内存恢复和辅助功能验证。

内容只接受当前 schema 2。`ecological-atlas.json` 维护 8 卷、32 个专题、28 份来源、6 类证据性质、160 个唯一媒体身份，以及每个专题的因果机制、分配后果、争议结构、综合判断、指标、讨论问题和图片负载契约。旧九章清单和兼容模型已经删除。

## 信息架构

Workbench 固定为四个一级入口：

1. **理解**：生态图谱首页、专题库、八卷结构、案例集、系统地图、概念索引、方法与来源；
2. **验证**：按用户问题组织的图片、缓存、鉴权、并发、失败和真实网络实验；
3. **证据**：运行记录、预期/实际、缓存来源、共享指标、结构化诊断和 JSON 导出；
4. **设置**：常用体验选项与独立开发者参数页。

理解层不是三十二张同构卡片。详情页包含八种媒体表面：

- `editorial`：宽幅主图、正文插图和多目标尺寸；
- `mosaic`：主图与密集拼贴；
- `timeline`：横向惰性加载和时间节点；
- `comparison`：fit/fill、双栏和窗口宽度变化；
- `atlas`：自适应网格和快速反向滚动；
- `dossier`：档案封面、列表缩略图和复用；
- `fieldNotes`：本地/网络混合、交替布局和长宽比差异；
- `immersive`：连续大图、渐进滚动和清内存恢复。

UI 自动化独立进入八种表面，并通过测试专用直接路由逐一启动全部 32 个专题；同时验证首页、专题库、案例、系统地图、概念索引、方法页、搜索、fit/fill、重建全部图片、清内存后重载和图片契约展开。

## 八卷内容结构

1. **地球系统不是背景**：温升缺口、地球系统边界、生物多样性、水循环/冰冻圈/海洋化学；
2. **社会代谢**：物质吞吐、效率反弹、塑料与化学污染、能源转型矿物；
3. **食物、动物与健康**：土地制度、动物伦理、One Health、土壤与授粉者；
4. **不平等的地理**：历史责任、生态不平等交换、殖民开采、适应债务；
5. **战争与安全**：军事生命周期、冲突污染遗产、能源安全、气候/迁徙/边境；
6. **日常系统**：快时尚、城市出行、住房与制冷、AI 与数据中心；
7. **转型争论**：绿色增长、去增长、生态社会主义、自然权利；
8. **治理与行动**：转型性变革、公正转型、公共供给和多尺度行动。

应用不把生态超载压成一个分数。每个专题分别回答“机制如何发生”“收益和损害如何分配”“最强主张是什么”“最强质疑是什么”“在现有证据下能得出什么有限结论”。评估共识、观测综合、模型情景、理论镜头、规范性立场和证据争议在 UI 中分开标记。

## 内容与媒体伦理

许可、普通图库准入和公共教育情境审查是三道不同的门。教育叙事可以讨论肉食与动物利用、未成年人、战争、疾病、伤害、贫困与迁徙，但必须逐项检查教育必要性、可信来源、许可、主体尊严、隐私、年龄适宜性、非猎奇呈现、准确替代文本和避免污名化。

题材本身不自动通过，也不自动拒绝。以痛苦制造点击、羞辱或物化主体、无法核实来源、与论证无关的刺激性展示，以及把具体群体当作抽象灾难背景，始终禁止。

## 真实媒体规模

当前提交的静态清单包含：

- **419 张真实网络图片**；
- **29 张真实本地图片**；
- **448 个独立素材条目**；
- 自然、植物、建筑、友善动物影像、植物性食物、艺术、天文、交通、物品和公有领域成人肖像 10 类内容。

清单位于：

```text
FoveaWorkbench/Resources/workbench-media-catalog.json
```

本地文件位于：

```text
FoveaWorkbench/Resources/LocalMedia/
```

所有网络条目对应不同的 Wikimedia Commons 文件，不使用同一图片改尺寸冒充数百张素材。生成器会在写入前删除 JPEG EXIF/XMP/IPTC/COM、PNG 文本/EXIF 和 WebP EXIF/XMP；目录校验与全仓敏感材料门会再次拒绝元数据回归。首页只构造首批 48 项，随后按 48 项增量加载；即将出现的网络内容采用有界预取，避免把 448 个资源同时送入视图树或网络调度器。

## 许可、默认准入与情境伦理是三层治理

许可允许使用，不代表内容适合作为示例。生成器只接收明确 CC0 或公有领域、HTTPS、可解析尺寸和 MIME 的 Commons 文件。普通图库采用严格默认准入，以下类别默认拒绝：

- 肉类、乳蛋、蜂蜜、海鲜和其他动物性食物；
- 狩猎、捕鱼、屠宰、尸体、皮革、羊毛和水产养殖；
- 动物圈养、动物表演、繁殖展示和实验动物；
- 武器、战争、色情、医疗创伤和可识别未成年人肖像；
- 与目标类别语义不符的搜索漂移结果。

植物性食物采用正向准入，不以搜索词中出现 `vegan` 或 `food` 作为充分证据。本地素材进一步使用人工策展 allowlist，当前覆盖雾林、瀑布、花卉、桥梁、城市景观、蝴蝶、猫、抽象艺术、陶瓷、星云、月球、公共交通、打字机、主板、历史成人肖像、蔬果和明确植物性食物。

教育叙事不把关键词拒绝表当作普遍伦理定律。肉食与动物利用、未成年人、战争与军事、疾病、伤害或死亡可以进入逐项情境审查，但必须同时满足：教育必要性、可信来源与许可、主体尊严和隐私、年龄适宜性与必要提示、非猎奇呈现、准确替代文本。题材本身不自动决定去留；以痛苦制造点击、羞辱或物化主体、无法核实来源、与论证无关的刺激性展示始终禁止。当前图谱不以视觉冲击证明议题严重性；困难图像仍需逐项审查，不能借“正向价值观”获得宽免。

生成与校验：

```sh
python3 scripts/generate-workbench-media-catalog.py --generate --validate
python3 scripts/generate-workbench-media-catalog.py --validate
```

生成器具备 API 缓存、有限并发、429/`Retry-After` 退避、稳定 ID、类别正向准入、伦理拒绝词、本地人工 allowlist、图片元数据剥离和半成品拒绝。生成后必须重新执行 `scripts/generate-ios-example.sh`，使 Xcode 资源清单与本地文件一致。

## 真实网络与确定性网络

Workbench 使用两条互不冒充的证据通道：

| 通道 | 默认位置 | 能证明什么 | 不能证明什么 |
|---|---|---|---|
| 真实 HTTPS | 普通交互、真实目录、产品模式、场景工坊、Feed | DNS、TLS、重定向、CDN、真实几何和正式组合根 | 第三方瞬时故障不能自动归因于 Fovea；结果不完全确定 |
| `fovea-demo.test` | `--ui-testing`、单元/集成测试、普通合并门 | 304、`no-store`、`Vary`、认证、取消、错误 MIME、超限和失败分类 | 不能替代真实 DNS、TLS、CDN、代理或公网重定向 |

`WorkbenchConfiguration.defaults` 默认允许真实网络；`deterministicDefaults` 明确关闭公网。所有网络图片仍经过官方 `FoveaSystemPipeline`、正式 `URLSessionTransport`、精确 destination policy、Profile ACL、持久 StoreGeneration、single-flight、工作集预算和 ImageIO 目标像素解码。

本地素材由宿主直接读取并使用独立、有界的 `NSCache`，不冒充网络管线证据。网络与本地来源在界面中明确标识。

## 11 类真实产品场景

“真实场景工坊”不是同一个网格换标题。每类场景拥有不同信息层级和布局：

1. 社交时间线：头像、正文主图、多图内容和重复资源；
2. 聊天与附件：消息方向、小头像、图片附件和回屏复用；
3. 商品目录与详情：高密度网格、详情图和双击/捏合缩放；
4. 新闻与长文章：Hero、正文内嵌图和阅读顺序；
5. Stories 与轮播：横向入口、分页内容和下一项预取；
6. 照片库与瀑布流：高密度缩略图、不同长宽比和快速滚动；
7. 图片搜索结果：查询列表、缩略图、来源和增量显示；
8. 旅行与地点卡片：目的地 Hero、城市卡片和离线标记；
9. 个人主页与作品墙：封面、头像和多目标尺寸作品；
10. 通知与活动列表：头像、微型预览和重复资源；
11. 离线优先混合源：本地内容立即显示，网络内容随后补齐。

用户可以调整：

- 网络、本地或混合来源；
- 8–200 张可见图片；
- 1–4 列；
- fit / fill；
- 预取开关；
- 重建视图、清内存、主动预取和清空证据。

页面同时解释“首次加载 → 预取 → 滚动回屏 → 清内存 → 磁盘恢复 → 必要时回源”的过程，而不是只给按钮和内部术语。

## 回屏不再反复闪 loading

回屏体验由三层共同保证：

1. `FoveaImagePhaseContent` 的初始 `.empty` 状态保持透明，只有占位延迟到期并真正进入 `.loading` 后才显示骨架；
2. 远程逻辑身份只包含稳定资源 ID 和目标宽度桶，不包含视图刷新 UUID；
3. 新鲜 `RepresentationRecord` 可由持久 `ContentID` 直接构造 `RenderKey`，先查 rendered-memory，未命中才读取原编码磁盘文件。

因此：

- 近同步内存命中不会先画一次 spinner；
- 已成功的可见图片滚出再滚回时应直接复用；
- 清内存后可从原编码磁盘恢复；
- 只有缓存缺失、失效、`no-store` 或显式网络实验才再次回源。

Feed 默认保留成功图片直到替换，真实模式支持首批预取；测试模式可显式注入慢首字节以观察占位。

## 高压 Feed 与用户控制

Feed 支持：

- 40–2,000 个 Cell；
- 最多 300 个唯一真实网络资源；
- SwiftUI Lazy 容器与 UIKit `UICollectionView`；
- 列表/网格切换；
- 有界预取；
- 离屏取消；
- 慢速/快速脚本滚动；
- 清内存、重建身份、清证据；
- frame interval、hitch proxy 和 physical footprint 代理。

页面公开当前 workload 数量，UI 自动化从页面状态推导最后一个 Cell，不再把 `119` 等旧默认写死在测试中。

## 验证页

- **单图与几何**：来源、类别、具体图片、fit/fill、替换保留、慢响应、分块和缺失 MIME；
- **缓存与身份**：重置、首次打开、再次打开、304、`no-store`、`Vary` 与 cache-only；
- **账户隔离**：账户 A/B、错误凭证、credential generation 和 revoke；
- **Single-Flight**：多个订阅者、一次网络获取、共享结果和独立取消；
- **失败矩阵**：按网络服务、内容安全、离线权限分类；
- **真实网络**：Commons、HTTPBin、Picsum、GitHub Raw、Google Static 和当前网络路径。

## 证据与隐私边界

直接运行可以记录：

- request/completed 数与 wall-clock duration；
- origin 请求数；
- fetch/decode join；
- rendered-memory / encoded-disk hit；
- HTTP 状态；
- cancellation；
- cache-write degradation、稳定原因码和 target pixels；
- Feed 的 frame samples、hitch proxy 和 physical footprint 差分。

Evidence Bundle schema 3 不导出 simulator UDID、原始自定义 URL、凭证、ContentID、namespace 明文、诊断 key digest、locale、时区、精确设备型号、运行/性能 UUID 或精确开始/结束时间。持久 generation 只形成每次导出重新加盐的短期令牌，导出时间降到小时粒度；场景、持续时间、性能数值、配置指纹和 source tree 仍保留。自定义 URL 只存在于当前进程。普通日志使用有限、脱敏字段；用户界面先展示可理解结果，原始 kind/reason/stage 位于二级证据层。

## 构建与验证

```sh
scripts/generate-ios-example.sh
open Examples/FoveaWorkbenchApp/FoveaWorkbench.xcodeproj
```

确定性验证：

```sh
scripts/verify-ios-example.py --skip-live-network
```

完整验证会显式授权 Live XCTest，并拒绝任何被跳过的公网测试：

```sh
scripts/verify-ios-example.py
```

测试层包含：

- 448 项清单规模、唯一 ID、许可、伦理、类别、HTTPS 和本地文件可读性；
- 稳定资源身份与宽度桶；
- 本地素材不得进入网络工厂；
- 600 Cell / 300 唯一资源 Feed 模型；
- 同运行时回屏不回源、重启后从持久磁盘恢复；
- `.empty` 不构造 placeholder、慢加载才进入 `.loading`；
- iPhone/iPad 真实 UI、场景工坊控制和 SwiftUI/UIKit Feed；
- Commons 与多 origin Live XCTest；
- XcodeGen 可复现性、Release 二进制去测试路由、App 根 Privacy Manifest 和绑定当前 tree 的验证工件。

## 仍未证明的结论

Workbench 仍不能单独证明：

- 真机 120 Hz 长时间滚动、jetsam、能耗和 thermal；
- MetricKit / Instruments 级主线程和 GPU 证据；
- 企业代理、VPN、Private Relay、切网和后台 URLSession 长期矩阵；
- 真实 OAuth/Cookie 服务；
- 与 Nuke、Kingfisher、SDWebImage 的同设备预注册 non-inferiority；
- 生产流量下的长期稳定性。

这些结论需要独立真机工件、对照适配器和外部环境证据，不能从模拟器、单次公网成功或视觉截图推导。
