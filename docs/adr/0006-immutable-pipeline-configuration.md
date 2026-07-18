# ADR-0006：不可变 Pipeline 配置与无全局注册表

- **状态：Proposed**
- **日期：2026-07-18**

## 背景

Fovea 需要简单的 `Fovea.shared` API，也需要多账户、测试、实验模块和不同 codec/transport 配置。如果通过全局可变 registry 或运行时替换默认 decoder 实现，进行中的请求会遇到 key 与实际行为不一致、测试互相污染以及导入模块改变全局语义的问题。

## 决策

1. Pipeline 在构造完成后持有不可变 `PipelineConfiguration` 快照。
2. codec、processor、source loader、transport、clock、store 和 diagnostics 在构造期注入并冻结。
3. 修改配置创建新的 pipeline/configuration generation，不原地改变旧请求。
4. `Fovea.shared` 只是默认 pipeline 的只读 façade；不提供全局 `register`/`setDefault` API。
5. 导入可选模块不得通过静态初始化自动改变默认行为。
6. 影响字节或像素的配置必须进入相应 key/fingerprint；纯诊断配置不进入结果身份。
7. 多 pipeline 的 store/transport 共享必须显式且通过 schema/security 兼容检查。

## 后果

- composition root 稍多，但请求行为可复现；
- 测试不需要重置全局单例；
- 多账户和实验 pipeline 可以隔离；
- 旧任务不会因新注册 decoder/processor 改变结果；
- 动态插件需要创建新 pipeline，不能热修改生产实例。

## 验证

见 `../specifications/pipeline-configuration.md` 的 property tests。
