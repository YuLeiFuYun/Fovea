# Fovea 示例与真实网络实验

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

命令行真实网络实验。默认拒绝联网，只有显式传入 `--live` 才运行：

```sh
scripts/run-live-network-lab.py --timeout 240
```

可指定一个或多个公开图片 URL：

```sh
scripts/run-live-network-lab.py \
  --url https://httpbin.org/image/png \
  --url https://picsum.photos/seed/fovea/800/600
```

默认实验使用三个独立 Picsum seed；可通过 `--url` 覆盖为其他公开图片源。实验使用临时缓存并默认清理；子进程受超时和进程组终止约束。报告验证并发 single-flight、目标像素上限与脱敏 URLSession 事务摘要。外部网站、DNS、代理和网络状态会波动，因此该实验不作为确定性合并门，也不能替代本地 origin、HTTP corpus 或真机 Instruments。
## 确定性 loopback 网络实验

`run-loopback-network-lab.py` 使用 Python 标准库在 `127.0.0.1` 启动临时 HTTP origin，并通过正式 `FoveaNetworkLab`/`URLSessionTransport` 覆盖：

- ETag 条件请求与 304；
- `Cache-Control: no-store` 重取；
- HTTP 重定向和多 transaction metrics；
- 慢响应下并发订阅 single-flight；
- loopback 不经系统代理。

```sh
scripts/run-loopback-network-lab.py
```

该门禁不访问公网，不注册账号，不写长期缓存。远程明文 HTTP 仍被 `ImageRequest` 默认拒绝；HTTP 例外只限精确 loopback host。
