# Fovea 示例与真实网络实验

## FoveaWorkbench

iOS / iPadOS 15.0+ 完整示例与集成工作台。普通启动使用 419 张独立 Commons 网络图片与 29 张随包真实图片，提供搜索、来源/类别筛选、48 项增量目录和有界预取。许可与内容伦理分别校验，默认拒绝动物性食物、动物利用、暴力、色情、医疗创伤、未成年人可识别肖像和类别搜索漂移。

Workbench 包含 11 类真实产品场景、单图几何与缩放、缓存/304/`no-store`/`Vary`、账户隔离、single-flight、失败矩阵、真实网络、SwiftUI/UIKit Feed 和证据导出。场景工坊允许选择网络/本地/混合来源、8–200 张图片、1–4 列、fit/fill 与预取；Feed 支持 40–2,000 Cell 和最多 300 个唯一网络资源。SwiftUI 初始空状态不显示占位，稳定资源身份与刷新 token 解耦，回屏优先复用内存，清内存后从原编码磁盘恢复。

工程由固定 XcodeGen 版本生成，同时提交 `project.yml` 与生成后的 Xcode project：

```sh
scripts/generate-ios-example.sh
open Examples/FoveaWorkbenchApp/FoveaWorkbench.xcodeproj
scripts/verify-ios-example.py --skip-live-network
```

Workbench 普通交互运行时默认展示经过许可登记的真实 HTTPS 图片；体验首页、产品模式与 Feed 会明确显示联网状态和素材来源。`--ui-testing`、生产管线集成测试和仓库合并门仍使用确定性 origin，并显式跳过公网 Live XCTest；该 deterministic profile 全部通过时报告 `status: passed`，在 `skippedPhases` 中记录 live-network-tests。计划任务、完整验证或人工排障通过 `RUN_LIVE_NETWORK=1` 执行公网证据。两类证据互补，但第三方服务可用性不能成为确定性代码门禁。

## FoveaGalleryDemo

macOS 12+ SwiftUI 示例，覆盖：

- `FoveaSystemPipeline` 安全组合根；
- 响应式 target-pixel 请求；
- 显式无障碍语义；
- `ProfileAccessPolicy`；
- 交互/节流网络权限；
- 内存缓存清理与 namespace revoke；
- 结构化失败和重试。

运行：

```sh
swift run FoveaGalleryDemo
```

示例访问公开 HTTPS 图片。它不是性能基准，也不自动注册第三方账号。

## FoveaNetworkLab

命令行真实网络实验。仓库确定性验证默认不运行它；计划任务、Phase 0b 完成验证或人工排障时显式执行。直接调用底层 executable 仍要求 `--live`，用于避免误执行：

```sh
scripts/run-live-network-lab.py --timeout 240
```

覆盖默认矩阵时必须提供至少四个独立 origin 的预期成功图片 URL：

```sh
scripts/run-live-network-lab.py \
  --url https://httpbin.org/image/png \
  --url https://picsum.photos/seed/fovea/800/600 \
  --url https://raw.githubusercontent.com/github/explore/main/topics/swift/swift.png \
  --url https://www.gstatic.com/webp/gallery/1.jpg
```

默认矩阵访问 HTTPBin、Picsum、GitHub Raw 与 Google Static 四个独立 origin；覆盖 PNG/JPEG、真实重定向、CDN、HTTP/2、系统代理 metrics、并发 single-flight 和目标像素约束。允许一次受控重试；最终失败会使本次外部实验失败，但不会污染确定性合并门。实验使用临时缓存并默认清理；子进程受超时和进程组终止约束。
## 确定性 loopback 网络实验

`run-loopback-network-lab.py` 使用 Python 标准库在 `127.0.0.1` 启动临时 HTTP origin，并通过正式 `FoveaNetworkLab`/`URLSessionTransport` 覆盖：

- ETag 条件请求与 304；
- `Cache-Control: no-store` 重取；
- HTTP 重定向和多 transaction metrics；
- 慢响应下并发订阅 single-flight；
- 缺失 `Content-Type` 的 anomaly；
- 错误 MIME、响应体超限、401 和远程明文 redirect 的预期结构化失败；
- loopback transaction 未被 URLSession 标记为代理。

```sh
scripts/run-loopback-network-lab.py
```

该门禁不访问公网，不注册账号，不写长期缓存。远程明文 HTTP 仍被 `ImageRequest` 默认拒绝；HTTP 例外只限精确 loopback host。

### NetworkLab privacy and egress boundary

Custom URLs are identified only by `custom-NNN` plus a per-run randomized origin correlation. Reports never store the raw URL, host, query, or a stable URL digest. Initial destinations are exact-allowlisted; cross-origin redirects require an explicit `--allow-origin` entry. The default matrix adds only the known Picsum Fastly redirect origin, and one run is capped at 64 cases.
