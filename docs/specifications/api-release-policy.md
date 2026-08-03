# 公共 API、发布与依赖治理

> **状态：Active pre-adoption policy。当前无外部用户，只维护最新源码、API、配置与磁盘 schema。**

## 1. 目标

Fovea、ImageCraft 和 Akashic 当前均处于无外部用户的 pre-adoption 阶段。实现、API、配置和磁盘格式发生破坏性变化时，直接更新唯一当前版本并删除旧分支；安全与行为变化仍必须记录并重新绑定证据。

## Phase 1 与发布阶段的关系

Phase 1 等同于 Core v1 Candidate Hardening，不等同于 1.0 Stable。它允许 breaking API 变化，主要工作是公共面收缩、Source 补全、真实宿主采用、Profile v1 Candidate 和发布证据。首次真实采用前不建立旧版本兼容承诺。

## 2. 发布阶段

```text
0.x Pre-adoption
  只维护最新 API、行为和 schema；不保留 deprecated shim 或迁移读取器

首次真实采用后的稳定阶段
  另行 Accepted ADR 定义 SemVer、行为和存储兼容承诺

独立 Experimental products
  不因 umbrella import 自动暴露；版本可与 Core 分离
```

只有满足以下条件才发布 1.0：

- Phase 0b/Core v1 门禁通过；
- 公开 API surface review 完成；
- 至少一个真实应用采用周期；
- API/ABI/行为/磁盘格式稳定政策有 Accepted ADR；
- 依赖、license、二进制体积和安全基线公开；
- AIQA release gate、SBOM、签名/provenance 和 R3 独立审查证据完整。

## 3. SemVer 与行为变化

以下通常属于 breaking change，即使 Swift 签名未变：

- cache key 或 identity 语义改变并可能返回不同资源；
- 默认安全/隐私边界变宽；
- cancellation、retry、stale、transition 的可观察行为改变；
- 错误 category/reason code 改义；
- processor/decoder fingerprint 语义改变却不自然失效；
- 删除平台或提高最低系统版本。

收紧安全策略可以在必要时作为补丁发布，但必须：

- fail closed；
- 发布安全说明；
- 明确可能导致新的 miss/rejection；
- 不复用旧的不安全缓存结果。

## 4. Swift API 设计

- 优先 concrete value types 与小型 capability protocol；
- 避免公开协议承载频繁演进的所有内部阶段；给公开 protocol 新增 requirement 视为 breaking；
- 公开 enum 新 case 的演进策略必须明确；跨模块调用者不应被迫穷举未来实验能力；
- SPI、underscored attribute 和私有 runtime hook 不属于稳定 API；
- Experimental 类型不从稳定 umbrella product re-export；
- 默认参数的行为属于兼容承诺，不能无记录地改变。

## 5. SwiftPM 与二进制分发

- 每个正式仓库根目录提供 `Package.swift`；
- release tag 使用完整 SemVer；
- package products 与模块职责一一对应，避免一个 import 拉入所有 codec/AI 依赖；
- source package 默认不启用 library evolution；只有独立分发 binary framework 时从首个 binary release 起评估并测试 library evolution/module stability；
- Swift tools version 和支持的 compiler matrix 在 CI 中明确；
- 如需要多工具链 manifest，只在 manifest API 确有差异时使用版本专用 manifest。

## 6. 依赖政策

Stable Core 默认只依赖 Apple 系统框架和明确审查的基础包。重型 codec、模型和 C/C++ 依赖放入独立 optional product。

每个外部依赖记录：

```text
purpose
version range / tested versions
license and notices
source/binary provenance
checksum（binary artifact）
platform support
known security process
binary size contribution
removal/fallback plan
```

规则：

- 不隐藏传递依赖；
- library package 不能依赖自身 `Package.resolved` 为下游固定版本，CI/benchmark app 使用独立锁定环境；
- binary artifact 必须有 checksum、来源和更新流程；
- 优先 source build 与可审计实现；
- license 不兼容、无人维护或无法 fuzz 的 codec 不进入 Stable Core；
- 维护 SBOM/第三方 notices，并对安全更新建立响应流程。

## 7. 体积与启动成本

每个 product 单独报告：

```text
compressed/uncompressed binary size
link-time contribution
static initializers
first-use latency
resident memory after import/first request
```

导入 Fovea Core 不得初始化实验 codec、模型、Metal pipeline 或全局 registry。Optional product 的成本由使用者显式承担。

## 8. 当前删除政策

- 当前无外部用户，不建立 deprecated API、旧配置、旧磁盘 schema 或旧 package product 的兼容层；
- 破坏性变更直接修改当前实现、文档、样例、测试、API baseline 和 conformance contract；
- 删除后必须通过 clean-copy、当前 consumer、当前持久层和源码绑定门禁；
- 首次真实采用后再以 Accepted ADR 建立弃用与迁移政策。

## 9. CI 门禁

- public API diff；
- minimum deployment target build；
- Swift compiler matrix；
- dependency/license/SBOM check；
- per-product binary size regression；
- sample app compile；
- current-schema fixture：当前缓存、配置和常见调用代码必须可由 clean consumer 重现；
- PR Evidence Bundle schema、AIQA gates、critical mutants 与 human comprehension attestation；
- protected CI 生成 SBOM、签名和 SLSA-compatible provenance，release runner 不执行未审查 PR 代码并携带秘密。
