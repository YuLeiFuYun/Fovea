# Source 身份、变体与失效规范

> **状态：Proposed，Core v1 Candidate 规格。**  
> 本规范定义 URL 之外的 File/Data/Asset/Photos/Custom source 如何形成稳定身份、检测变化并参与缓存。

## 1. 通用模型

每个 Source 解析为：

```text
LogicalSourceID      调用者认为同一资产的稳定身份
SourceVariant        会影响返回表示的环境/trait
RevisionHint         可快速检测变化的非权威提示
ResolvedLocator      本次读取位置或句柄
```

最终字节仍以 ContentID 为准。RevisionHint 只能用于提前 miss/重探测，不能替代内容摘要。

无法提供可靠身份或失效信号的 CustomSource 默认：

- 仅当前请求复用；
- 不进入跨请求持久缓存；
- 调用者必须显式提供 cache key 与 invalidation contract 才能扩大复用。

## 2. URLSource

- LogicalSourceID 使用调用者业务 asset ID 或规范化稳定 URL；
- 临时签名/凭证不进入稳定身份；
- 完整 resolved request 只进入 FetchExecutionKey；
- HTTP freshness/validator/Vary 由 RepresentationRecord 管理。

## 3. DataSource

- 对不可变 Data 可立即计算 ContentID；
- 默认 LogicalSourceID 可由 ContentID 派生；
- caller-provided ID 只用于业务关联，不允许让不同字节错误共享；
- Data 已在内存时无需再复制为网络 staging；大对象仍受 maximumEncodedBytes 限制；
- 是否写 OriginalEncoded 由显式 cache policy 决定。

## 4. FileSource

路径字符串不是可靠内容身份。优先使用：

```text
volume identifier
file resource identifier / inode equivalent
size
modification timestamp
caller revision（可选）
```

规则：

- 读取前后验证 revision hint 未变化，防止读取过程中被替换；
- 最终 ContentID 对实际读取字节求摘要；
- 无可靠 file resource ID 时，路径只能作为 LogicalSourceID，修改时间/大小触发重新 hash；
- security-scoped URL 的访问 lease 只覆盖读取过程，不持久化 token/bookmark secret；
- 原文件变更后旧 Decode/Render 条目因新 ContentID 自然失效；
- 文件协调、原子替换和符号链接策略由 SourceLoader 明确，不静默跟随不受信链接。

## 5. AssetSource

Asset Catalog 同一名称可因 trait 返回不同表示。SourceVariant 至少考虑实际影响选择的：

```text
bundle identifier + bundle version
asset name
scale
appearance（light/dark/high-contrast，若资源提供）
display gamut
idiom / platform
localization（若资源本地化）
```

不影响实际 asset 选择的 UI 状态不能进入 key。应用升级导致 bundle version/asset 内容变化时，不复用旧持久条目。

## 6. PhotosSource

- LogicalSourceID 使用 Photos local identifier；
- RevisionHint 使用可获得的 resource version/change signal；
- Photos 权限撤销后立即取消读取并撤销相关 namespace 可达性；
- iCloud 下载、原图/调整后版本、HDR/辅助资源是不同 SourceVariant；
- 不把安全作用域 URL 或临时 file locator 作为持久身份；
- 编辑后的资源必须产生新 ContentID。

PhotosSource 为可选产品，不阻塞 Phase 0a。

## 7. CustomSource

CustomSource 必须声明：

```text
identity stability
variant fields
revision/invalidation mechanism
security namespace
whether bytes are immutable during one load
```

Fovea 对不完整声明采取保守策略：不跨请求 single-flight、不持久化或要求每次重新求 ContentID。

## 8. Property tests

- **SOURCE-PT-001**: 同一路径文件原子替换后不命中旧 ContentID；
- **SOURCE-PT-002**: 文件读取中途修改不会提交混合字节；
- **SOURCE-PT-003**: 相同 Data 得到相同 ContentID，不同 Data 不因 caller ID 相同而共享；
- **SOURCE-PT-004**: Asset appearance/gamut 真正改变表示时 key 改变；无关 UI 参数不改变；
- **SOURCE-PT-005**: bundle version 变化使旧 Asset record 不可选；
- **SOURCE-PT-006**: Photos 编辑/权限撤销后旧任务不提交；
- **SOURCE-PT-007**: 无 identity contract 的 CustomSource 不进入持久缓存；
- **SOURCE-PT-008**: 所有 Source 最终共享仍以 ContentID/DecodeKey/RenderKey 为准。