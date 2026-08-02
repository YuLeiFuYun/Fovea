# 安全与隐私默认拒绝矩阵

> **状态：Proposed；Gate 列区分 Phase 0a、Phase 0b、Core v1、Phase 2 与 Experimental。**
> 除非调用者通过明确、受限的策略覆盖，否则使用以下默认行为。

| ID | Gate | 输入或事件 | 默认行为 | 原因 |
|---|---|---|---|---|
| SEC-CASE-001 | 0a | encoded bytes 超过上限 | 在继续累计前终止 | 防止响应体耗尽内存/磁盘 |
| SEC-CASE-002 | 0a | width、height 或 pixel count 超限 | 解码前拒绝 | 防止解压炸弹 |
| SEC-CASE-003 | 0a | 静态路径遇到多帧图像或 frame count 超限 | 0a 拒绝；动画能力启用后再按显式策略处理 | 防止静态解码路径隐式接受动画与帧放大 |
| SEC-CASE-004 | 0b | metadata/ICC/EXIF/XMP 超限，或 JPEG 通过 APP0–APP15/COM、多个 scan 间 marker 绕过预算 | 在进入 ImageIO 前完整扫描并拒绝；所有 APP/COM payload 统一计入 metadata 预算 | 防止解析器和内存攻击，以及渐进 JPEG 扫描间元数据绕过 |
| SEC-CASE-005 | 0a | MIME 为 `text/html` 等非图像 | 拒绝 | 防止错误页被当作图片缓存 |
| SEC-CASE-006 | 0a | MIME、UTType 与 magic 不一致 | 以安全探测结果为准并记录异常；无法确认则拒绝 | 避免扩展名欺骗 |
| SEC-CASE-007 | Experimental | SVG script、external entity/resource | 禁止 | 防止脚本、SSRF 和递归资源 |
| SEC-CASE-008 | Experimental | SVG 递归/嵌套超限 | 拒绝 | 防止资源消耗攻击 |
| SEC-CASE-009 | Phase 2 | progressive preview 未通过 MIME/magic/尺寸/帧数最小安全探测 | 不向 UI 交付像素 | 防止渐进路径绕过最终安全检查 |
| SEC-CASE-010 | Phase 2 | progressive scan 数量超限 | 停止增量更新或拒绝 | 防止重复解码放大 |
| SEC-CASE-011 | 0a | 截断/畸形 bitstream、JPEG 缺少 EOI、PNG 在 IEND 后携带尾随载荷 | 返回结构化 decode error，不缓存原编码可见 record 或派生结果 | 保持容器边界与缓存一致性 |
| SEC-CASE-012 | 0a | `Cache-Control: no-store` | 仅同一 in-flight task cohort 可共享；task terminal 后不满足新请求，当前 view token 可继续显示已交付像素 | 遵守 HTTP 与隐私语义 |
| SEC-CASE-013 | Core v1 | `Cache-Control: no-transform` | 禁止写入任何经过 resize/crop/format/color 等变换的 DerivedEncoded；显示所需的瞬态解码不受影响 | 遵守表示变换约束 |
| SEC-CASE-014 | 0a | 认证响应 | 仅写入专属 security namespace | 防止串号 |
| SEC-CASE-015 | 0a | 跨 namespace ContentID 相同 | 默认不共享 blob/metadata | 防止侧信道和生命周期耦合 |
| SEC-CASE-016 | 0a | 登出/namespace revoke | 立即提升 generation、取消任务并阻止旧任务 commit；物理清理可异步 | 防止清理后数据复活 |
| SEC-CASE-017 | 0a | 重定向至不同 origin | 剥离内置及调用者声明的 credential headers；不允许隐式继承 | 防止凭证泄漏 |
| SEC-CASE-018 | 0a | 日志事件 | URL 脱敏；不记录 token、cookie、私有 query、ContentID、PhysicalBlobID 或稳定账户标识 | 防止日志泄漏与内容指纹侧信道 |
| SEC-CASE-019 | 0b | cache 与 transport staging 目录 | 目录显式收紧为 `0700`、文件为 `0600`，默认排除系统备份并使用平台适当文件保护；物理 blob 文件名使用随机不透明 ID。iOS Simulator 只验证可观测的备份排除和非弱化保护值；真机必须精确验证 `completeUntilFirstUserAuthentication` | 防止缓存或认证响应暂存进入备份、被同机其他主体读取、锁屏后暴露或通过文件名探测已知内容 |
| SEC-CASE-020 | Experimental | 第三方 C/C++ codec | 版本钉定、fuzz、ASan/UBSan、输入限制 | 降低解析漏洞风险 |
| SEC-CASE-021 | 0b | 未知 codec/attachment | 不加载；保留原 blob 需符合缓存策略 | 避免未审计解析 |
| SEC-CASE-022 | 0b | 未知未来磁盘 schema | 不读取为有效条目、不写回；切换安全 generation | 防止降级/升级破坏 |
| SEC-CASE-023 | Core v1 | namespace/store quota 超限 | 拒绝或先回收，不突破 hard limit | 防止单一主体耗尽磁盘 |
| SEC-CASE-024 | Core v1 | diagnostics sink 阻塞/失败 | 有界丢弃并记录聚合 degradation，不影响图片结果 | 防止可观测性反向形成拒绝服务 |
| SEC-CASE-025 | Experimental | 模型文件 | 不隐式下载；要求 hash/version，可选签名 | 模型供应链安全 |
| SEC-CASE-026 | Experimental | Analysis/模型结果 | 继承 source namespace/no-store/TTL，模型 fingerprint 变化失效 | 防止语义泄漏和陈旧结果 |
| SEC-CASE-027 | Experimental | 重建型增强 | 默认关闭、显式 opt-in，并标记 reconstructed | 防止内容语义混淆 |
| SEC-CASE-028 | Experimental | Trust 验证不可用 | 默认 `.unavailable`，不伪造可信状态 | 防止错误安全承诺 |
| SEC-CASE-029 | 0a | 持久化 namespace metadata | 仅保存带域分离的 namespace fingerprint，不保存调用者账户/租户标识明文 | 防止 manifest/record 泄露稳定主体标识 |
| SEC-CASE-030 | 0b | 已知 schema 的 manifest 字段语义损坏 | 校验摘要、长度、键绑定、Vary 规范、物理 ID 唯一性与时间/状态范围；失败关闭且不得改写原文件 | 防止格式合法但语义矛盾的元数据绕过隔离、完整性或资源约束 |
| SEC-CASE-031 | 0b | 受管目录、manifest、blob 与锁文件的链接攻击 | 路径与已打开描述符都验证文件类型、属主和普通文件单链接约束；锁与 mtime 读取使用 `O_NOFOLLOW`，符号链接与硬链接均失败关闭，外部 inode 的时间戳不得影响 LRU/trim 顺序 | 防止路径重定向、共享 inode 和外部未来时间戳保护损坏条目 |
| SEC-CASE-032 | 0b | generation metadata、store manifest 与 blob 的超大文件 | 使用 `O_NOFOLLOW` 打开并在分配前通过 `fstat` 校验类型、属主、链接数和 `st_size`；超限 metadata 不改写，blob 长度不符按完整性损坏隔离 | 防止损坏或攻击性稀疏文件在 schema/摘要校验前触发无界内存分配 |
| SEC-CASE-033 | 0b | 远程明文 `http://` 图片 URL | 默认拒绝；仅允许 `localhost`、`127.0.0.1`、`::1` loopback 用于本地开发与确定性网络实验 | 防止公网凭证、查询参数和图片内容被明文传输，同时保留不依赖外网的真实 URLSession 测试路径 |
| SEC-CASE-034 | 0b | 调用者提供的 URLSession configuration 含 Cookie、credential storage、URLCache 或 session-wide header | 官方 transport 复制配置后清空这些环境状态；显式 request header 与 credential generation 才能影响执行 | 防止不可见凭证、header 与缓存状态绕过请求身份、Vary、ACL 和日志契约 |
| SEC-CASE-035 | 0b | 宿主要求拒绝系统代理、PAC、Private Relay 或受管代理路径 | 默认明确采用系统路由；严格模式仅在 task metrics 证明全部 transaction 未使用代理时接受结果，指标缺失或观测到代理均失败关闭 | 让代理信任假设可验证，同时不伪称事后 metrics 检查能提供连接前网络隔离 |
| SEC-CASE-036 | 0b | namespace generation 计数达到 `UInt64.max` | namespace 永久进入 exhausted 状态；后续 generation 哨兵仍不可激活，不允许无符号回绕 | 防止极端状态或损坏状态使最早代际重新获得提交资格 |
| SEC-CASE-037 | 0b | 插件、远端配置或不可信输入提供任意 HTTPS 图片 URL | 宿主可配置最多 256 个精确 origin；官方组合根在缓存前与 transport 中使用同一策略 | 防止只限制发网却仍从缓存返回越权资源，或只限制初始 URL 却允许 redirect 绕过 |
| SEC-CASE-038 | 0b | 允许 origin 返回跨域 redirect | 每次 redirect 重新执行 URL 安全策略与精确 origin allowlist，拒绝跨策略跳转 | 防止受信源通过 3xx 将请求路由到未授权网络目的地 |
| SEC-CASE-039 | 0b | NetworkLab 使用自定义 URL 或 public origin 发生跳转 | 自定义目的地只输出每次运行随机化的 origin correlation；transport 仅允许输入 origin 与显式 `--allow-origin`，内置 Picsum 只额外允许固定 Fastly origin | 防止工件泄露内网/签名 URL，并防止受信公网源将 CI 跳转到未授权 HTTPS 目的地 |
| SEC-CASE-040 | 0b | 仓库误纳入私钥、高置信 token、用户绝对路径、签名 URL、凭证文件或 Xcode 用户数据 | `check-sensitive-material.py` 只报告规则与位置、不回显匹配内容，并作为统一验证硬门 | 防止源代码、示例、文档和发布包携带开发者隐私或凭证 |
| SEC-CASE-041 | 0b | 引入远程 Swift package 或外部 GitHub Action | 依赖必须进入显式 allowlist；Action 必须固定完整 40 位提交 SHA；未登记或漂移即失败 | 防止 tag 漂移、依赖注入与未审计供应链扩张 |
| SEC-CASE-042 | 0b | 请求、响应、Vary 或持久 HTTP metadata 含 C0/C1 控制字符、DEL、超限字段，或同义 Vary 采用非规范表示 | 除 HTAB 外拒绝控制字符；字段和值有界；Vary 统一 canonicalize，非规范持久值失败关闭 | 防止 header 注入、日志终端控制、缓存身份分裂和 metadata DoS |
| SEC-CASE-043 | 0b | 可执行 App 或 SwiftPM target 使用 Required Reason API，但清单缺失、理由漂移或资源未打包 | 门禁从源码调用反推 API 类别，要求每个 target 精确声明经审查的理由；Release 产物再次检查 App 根清单 | 防止提交时清单看似存在、实际发布包缺失或声明与代码不一致 |
| SEC-CASE-044 | 0b | 随包图片或重新下载的素材保留 EXIF、XMP、IPTC、PNG 文本块或畸形容器 | 生成时剥离元数据，目录与全仓门禁再次扫描；图片身份、许可和视觉内容不依赖这些元数据 | 防止 GPS、相机型号、作者软件、版权描述或本机工作流信息进入发布包 |
| SEC-CASE-045 | 0b | UI 自动化启动参数、隐藏直达路由或测试插件进入 Release App | 测试路由只在 `DEBUG` 编译；Release 门扫描可执行文件与 dylib 字符串、拒绝 PlugIns 并验证根隐私清单 | 防止发布构建暴露隐藏导航、确定性测试模式或测试实现细节 |

## 插件与迟到回调的边界后置条件

- task route 缺失时 redirect 必须拒绝并取消，不得回退到 `.secureDefault` 或丢弃额外敏感 Header 名单；
- 公共 `TransportResponse` 的 digest 与字节数只能从实际 body 推导；内置流式 transport 可使用模块内不可伪造的 digest capability；
- `FetchStage` 必须在 probe/decode 前复核自定义 transport 的最终 body hard cap；
- transformer fingerprint 在进入 RenderKey 前固定长度哈希；transform 返回表面必须重新通过 dimension、pixel-count 与 working-set 校验；
- decoder/transformer 是宿主受信代码，返回值可验证，但库不声称能沙箱化插件内部 CPU、内存、线程或系统调用；
- 精确 URL origin allowlist 不等价于解析后 IP/CIDR、DNS rebinding 或企业 egress 隔离。

## DecodeLimits 最小字段

```text
maximumEncodedBytes
maximumDimension
maximumPixelCount
maximumFrameCount
maximumMetadataBytes
maximumAuxiliaryAttachments
maximumProgressiveScans
maximumNestingDepth
allowedFormats
```

限制必须在大内存分配前检查，并能由测试注入较小阈值验证边界。

## Namespace revocation

每个请求和缓存事务携带 `NamespaceGeneration`。登出或权限域撤销时：

1. 原子撤销旧 generation；
2. UI 立即清理私有图；
3. 取消相关 subscriber 和 task；
4. 所有 Commit 再次校验 generation；
5. 旧任务完成也不能写 memory/disk/analysis；
6. 后台物理删除失败不影响逻辑不可达性；
7. 不承诺闪存“安全擦除”；高敏应用应使用独立加密/密钥撤销策略。

W3 必须包含 logout 与并发 Commit 的竞态测试。鉴权与 Cookie 集成契约见 `auth-context-integration.md`。

## 错误分类

```text
source
transport
http
securityLimit
namespaceRevoked
schemaIncompatible
cacheRead
cacheWrite
probe
decode
processing
unsupportedCapability
cancelled
```

每个错误明确：是否可重试、是否允许 stale fallback、是否允许其他 decoder、是否应向 UI 暴露。完整错误、重试和回退契约见 `error-recovery.md`；诊断隐私与事件 schema 见 `diagnostics-contract.md`。

## 持久 namespace 指纹隐私

`StorageNamespaceFingerprint` 是确定性分区键，不是匿名化或加密。它阻止原始 namespace 字符串直接出现在 manifest 中，但低熵账户/profile ID 仍可能被离线枚举，相同值也可跨缓存根关联。生产日志、诊断、benchmark 证据和 network-lab 工件不得导出该指纹。未来若引入 generation-local keyed fingerprint，必须通过 encoded store 与 representation store 共享的显式迁移 ADR，禁止原地替换哈希算法。

## 插件后置条件与暂存数据生命周期

安全边界不以“官方实现会遵守”为前提。Fovea 在每个可插拔返回点重新建立不变量：transport body/URL/header、representation namespace/generation、decoder probe、transform surface、storage result 和 GC live reference。非法插件结果只能失败关闭或退化为 miss，不能进入跨请求复用状态。

URLSession spill 不再共享一个无所有权目录。每个 transport 使用独占 session 目录；同进程活动集合防止 POSIX 进程级 record-lock 重入误判，owner lock 防止跨进程误清理。失主 session 和旧版根目录 `stage-*` 文件仅在类型、属主和链接检查通过后删除。维护锁采用可取消的非阻塞轮询并有 5 秒默认上限；其他进程异常长期持锁不得使首次请求无限阻塞。

仓库敏感材料门禁拒绝 symlink，避免扫描器跟随仓库外目标；对 16 MiB 内任意文件执行字节级私钥和高置信 token 签名扫描，不依赖扩展名。文本规则继续拒绝用户绝对路径、credential-bearing URL、环境文件和 Xcode 用户数据；JPEG/PNG/WebP 还会解析并拒绝 EXIF、XMP、IPTC、文本元数据或畸形容器。
