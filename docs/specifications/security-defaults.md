# 安全与隐私默认拒绝矩阵

> **状态：Proposed；Gate 列区分 Phase 0a、Phase 0b、Core v1、Phase 2 与 Experimental。**  
> 除非调用者通过明确、受限的策略覆盖，否则使用以下默认行为。

| ID | Gate | 输入或事件 | 默认行为 | 原因 |
|---|---|---|---|---|
| SEC-CASE-001 | 0a | encoded bytes 超过上限 | 在继续累计前终止 | 防止响应体耗尽内存/磁盘 |
| SEC-CASE-002 | 0a | width、height 或 pixel count 超限 | 解码前拒绝 | 防止解压炸弹 |
| SEC-CASE-003 | Phase 2 | 动画 frame count 超限 | 拒绝或按显式策略静态化 | 防止帧缓存和 CPU 爆炸 |
| SEC-CASE-004 | 0b | metadata/ICC/EXIF/XMP 超限 | 拒绝异常 metadata，必要时拒绝资源 | 防止解析器和内存攻击 |
| SEC-CASE-005 | 0a | MIME 为 `text/html` 等非图像 | 拒绝 | 防止错误页被当作图片缓存 |
| SEC-CASE-006 | 0a | MIME、UTType 与 magic 不一致 | 以安全探测结果为准并记录异常；无法确认则拒绝 | 避免扩展名欺骗 |
| SEC-CASE-007 | Experimental | SVG script、external entity/resource | 禁止 | 防止脚本、SSRF 和递归资源 |
| SEC-CASE-008 | Experimental | SVG 递归/嵌套超限 | 拒绝 | 防止资源消耗攻击 |
| SEC-CASE-009 | Phase 2 | progressive preview 未通过 MIME/magic/尺寸/帧数最小安全探测 | 不向 UI 交付像素 | 防止渐进路径绕过最终安全检查 |
| SEC-CASE-010 | Phase 2 | progressive scan 数量超限 | 停止增量更新或拒绝 | 防止重复解码放大 |
| SEC-CASE-011 | 0a | 截断/畸形 bitstream | 返回结构化 decode error，不缓存派生结果 | 保持缓存一致性 |
| SEC-CASE-012 | 0a | `Cache-Control: no-store` | 仅同一 in-flight task cohort 可共享；task terminal 后不满足新请求，当前 view token 可继续显示已交付像素 | 遵守 HTTP 与隐私语义 |
| SEC-CASE-013 | Core v1 | `Cache-Control: no-transform` | 禁止写入任何经过 resize/crop/format/color 等变换的 DerivedEncoded；显示所需的瞬态解码不受影响 | 遵守表示变换约束 |
| SEC-CASE-014 | 0a | 认证响应 | 仅写入专属 security namespace | 防止串号 |
| SEC-CASE-015 | 0a | 跨 namespace ContentID 相同 | 默认不共享 blob/metadata | 防止侧信道和生命周期耦合 |
| SEC-CASE-016 | 0a | 登出/namespace revoke | 立即提升 generation、取消任务并阻止旧任务 commit；物理清理可异步 | 防止清理后数据复活 |
| SEC-CASE-017 | 0a | 重定向至不同 origin | 不继承 Authorization，除非显式安全策略允许 | 防止凭证泄漏 |
| SEC-CASE-018 | 0a | 日志事件 | URL 脱敏；不记录 token、cookie、私有 query、ContentID、PhysicalBlobID 或稳定账户标识 | 防止日志泄漏与内容指纹侧信道 |
| SEC-CASE-019 | 0b | cache 目录 | 默认排除系统备份并使用平台适当文件保护；物理文件名使用随机不透明 ID | 防止缓存进入备份、锁屏后暴露或通过文件名探测已知内容 |
| SEC-CASE-020 | Experimental | 第三方 C/C++ codec | 版本钉定、fuzz、ASan/UBSan、输入限制 | 降低解析漏洞风险 |
| SEC-CASE-021 | 0b | 未知 codec/attachment | 不加载；保留原 blob 需符合缓存策略 | 避免未审计解析 |
| SEC-CASE-022 | 0b | 未知未来磁盘 schema | 不读取为有效条目、不写回；切换安全 generation | 防止降级/升级破坏 |
| SEC-CASE-023 | Core v1 | namespace/store quota 超限 | 拒绝或先回收，不突破 hard limit | 防止单一主体耗尽磁盘 |
| SEC-CASE-024 | Core v1 | diagnostics sink 阻塞/失败 | 有界丢弃并记录聚合 degradation，不影响图片结果 | 防止可观测性反向形成拒绝服务 |
| SEC-CASE-025 | Experimental | 模型文件 | 不隐式下载；要求 hash/version，可选签名 | 模型供应链安全 |
| SEC-CASE-026 | Experimental | Analysis/模型结果 | 继承 source namespace/no-store/TTL，模型 fingerprint 变化失效 | 防止语义泄漏和陈旧结果 |
| SEC-CASE-027 | Experimental | 重建型增强 | 默认关闭、显式 opt-in，并标记 reconstructed | 防止内容语义混淆 |
| SEC-CASE-028 | Experimental | Trust 验证不可用 | 默认 `.unavailable`，不伪造可信状态 | 防止错误安全承诺 |

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
