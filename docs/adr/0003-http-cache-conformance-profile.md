# ADR-0003：Fovea HTTP 缓存 Profile 与外部一致性测试

- **状态：Proposed**
- **日期：2026-07-18**

## 背景

Fovea 选择默认关闭独立 `URLCache` 持久化，以获得可解释的 `Vary`、认证 namespace、`no-store`、304 和退出登录语义。但“自行实现完整 RFC 9111”会把一个通用 HTTP 缓存实现的全部复杂度带入图片库，范围过大，也容易在边界组合中出错。

## 决策

### 1. 不宣称实现通用 HTTP cache

Fovea 定义一个版本化的 **Private Image Cache Profile**。HTTP 缓存本身是可选机制；对 profile 未支持的 method、status 或 directive，默认选择“不持久化/回源”，而不是猜测行为。

Phase 0b/Core v1 的 profile 聚焦：

- GET 图片表示；
- 200、条件 GET 的 304；
- 显式 freshness（`max-age`/`Expires`）、`Age`；
- `ETag`/`Last-Modified`；
- `Vary`；
- `no-cache`、`no-store`、`private`、`must-revalidate`、`no-transform`；
- 认证 private namespace；
- 206/If-Range 作为独立、可后置的 profile capability。

v1 默认不做：POST/unsafe method 缓存、负响应缓存、通用 redirect cache、启发式 freshness、共享代理缓存语义。以后新增必须升级 profile version 和测试矩阵。

### 2. 外部语料进入 Phase 0b

自写 property tests 不是唯一依据。测试来源至少包括：

- RFC 9111/9110 对应的规范示例与边界；
- `cache-tests.fyi` 中适用于 private client cache 的测试；
- Web Platform Tests `fetch/http-cache` 中适用的 server/request/response 序列；
- 已成熟实现的公开回归用例，用作差分启发，不作为规范替代。

WPT 明确是“从 Fetch 视角”测试缓存，因此不得直接宣称全部适用；`cache-tests.fyi` 也明确标注为 work in progress，其公开结果不能作为唯一能力判断。外部套件提供场景与回归线索，规范期望仍以 RFC section、Fovea profile 和独立 review 为准。每个移植用例必须记录 upstream commit、license、原测试 ID、对应 RFC section、适用性判断和 Fovea 期望结果。

### 3. Conformance manifest

CI 维护机器可读 manifest：

```text
source
upstream commit
test id
RFC section
profile capability
classification: required / optional / not-applicable / stricter-security
expected result
local adaptation notes
```

`not-applicable` 必须有理由，不能用来隐藏失败。

### 4. Clock 与 header 安全

HTTP age/freshness 使用可注入 wall clock 和 monotonic clock，采用饱和算术；检测到时钟回拨或无法可信计算时，保守视为 stale。

Fovea 是专用图片缓存，不重放任意 HTTP 响应。`RepresentationRecord` 只持久化缓存选择、验证和图像表示所需的字段；`Set-Cookie`、认证信息、hop-by-hop 和代理专属字段不得持久化或回放。

## 后果

Fovea 可以对自己支持的图片缓存语义作严格承诺，而不承担通用代理缓存的无限范围。外部语料会增加测试维护成本，但能显著降低“自写测试只覆盖已想到情况”的风险。

## 验证门禁

- Profile manifest 中 required 用例 100% 通过；
- W3 自有安全用例 100% 通过；
- external corpus 版本固定且可复现；
- profile 范围、未支持项和 stricter behavior 均公开；
- 任何 profile 扩展必须先增加测试再实现。
