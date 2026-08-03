# Public API 预算复核：合格组合边界（2026-08-03）

> **状态：Accepted current-tree ceiling，不是 1.0 稳定性声明。** 本复核只批准已经实现、测试并进入 `FoveaAdvanced` product 的 codec 与持久化组合边界；预算仍是无余量 ceiling，不是未来增长额度。

## 1. 结论

P6 的两个组合缺口已经以受限方式关闭：

- 新的生产 codec 入口要求完整 `ImageCodec`；只有显式 `legacyDecoder:` 才接受旧 `ImageDecoding`；
- 持久化替换只在 `FoveaAdvancedSystem` 暴露，provider 必须一次返回 descriptor、generation、encoded store、representation record store、namespace-generation persistence 与 lifetime；
- 默认 `Fovea` product 不包含 `FoveaAdvancedSystem`，继续固定使用 ImageIO + Akashic 安全组合；
- `FoveaSystem` 只消费 package 内部不可变 bundle，不接受三个裸 store hook，也不把默认全局 registry 暴露为扩展点；
- provider 声明与返回 bundle descriptor 不一致时，在 namespace registry 与 transport 组合前失败；pipeline 保留整个 bundle lifetime。

## 2. 精确预算变化

DocC 双平台 symbol graph 的当前计数为：

```text
FoveaAdvancedSystem       13   (+13，新增高级模块)
FoveaAppKit               13   (不变)
FoveaCore                427   (+2，qualified codec 与 explicit legacy 构造标签)
FoveaHTTP                171   (不变)
FoveaObservability        17   (不变)
FoveaPersistence           9   (不变)
FoveaStorage              26   (不变)
FoveaSwiftUI              45   (不变)
FoveaSystem                8   (+3，qualified codec overload 与 provider fingerprint)
FoveaUIKit                12   (不变)
------------------------------------------------
total                     741   (+18)
```

因此 `docs/public-api-budget.json` 的新 ceiling 精确设为 741，不保留额外余量。

## 3. 为什么新增 18 个符号是必要的

### FoveaAdvancedSystem：13

该模块承担此前不存在的、但已由第二类真实 provider 需求驱动的持久化扩展边界：

- provider descriptor；
- namespace-generation persistence 的有界闭包值；
- 不可拆分 qualified bundle；
- provider protocol；
- `FoveaSystemPipeline.open(... persistentStoreProvider:)` 高级入口。

它不是默认产品的一部分，且不能直接打开 `FoveaPersistentStores`、访问 `PersistentStoreRegistry`，或把 `encodedStore:` / `recordStore:` 作为独立入口。

### FoveaCore：+2

新增符号用于在类型系统中区分：

- `codec: any ImageCodec` 的合格生产路径；
- `legacyDecoder: any ImageDecoding` 的明确兼容路径。

这避免把缺少 descriptor、capability 与 resource contract 的旧 decoder 静默提升为生产插件。

### FoveaSystem：+3

系统门面新增：

- qualified codec 系统入口；
- 显式 legacy compatibility 系统入口；
- 只读 `persistentStoreProviderFingerprint`，用于证据和组合身份核验。

持久化 bundle 的具体协议与构造器没有进入默认 `FoveaSystem` 模块。

## 4. 被拒绝的更大 API 方案

第一版草案把 provider descriptor、open request、provider protocol、qualified bundle 和 namespace persistence protocol 全部公开在 `FoveaPersistence` / `FoveaStorage`。DocC 测量显示：

```text
FoveaPersistence  9 -> 37
FoveaStorage     26 -> 29
FoveaSystem       5 -> 8
FoveaCore       425 -> 427
Total           723 -> 759
```

该方案被拒绝，原因是：

- 默认安全产品承担了只属于高级逃生口的 API 成本；
- 底层 namespace persistence 机制被不必要地公开；
- open request 只是参数搬运，不形成独立领域概念；
- 用户可能误以为可以分别替换 store，而忽略 generation、writer lifetime 和跨 store 事务义务。

最终实现把这些机制降回 package 边界，只在 `FoveaAdvancedSystem` 保留最小可用表面。

## 5. 机器约束与证据

以下门禁共同约束该预算：

- `scripts/check-architecture-boundaries.py`：高级模块只属于 `FoveaAdvanced`，禁止默认 registry 和裸 store hook；
- `scripts/check-structural-quality.py`：登记精确模块依赖并防止依赖环；
- `CACHE-PT-044`：系统使用 provider bundle，并由 pipeline 保留其 lifetime；
- `CACHE-PT-045`：descriptor substitution 失败关闭；
- `CODEC-PT-010...012`：qualified codec 与 legacy compatibility 路径分离；
- macOS/iOS 双平台 DocC：114/114 公共类型有文档，404/741 公共符号有文档，总覆盖率 54.52%；
- `docs/public-api-budget.json`：逐模块与总量都绑定当前精确计数。

本复核不证明第三方 provider 已满足全部 crash consistency、writer exclusivity、namespace monotonicity 或物理设备资源资格。跨仓、版本化 conformance kit 仍是 `P6-CROSS-REPOSITORY-CONFORMANCE-001` 的后续义务。
