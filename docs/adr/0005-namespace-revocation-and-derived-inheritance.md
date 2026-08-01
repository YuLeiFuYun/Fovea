# ADR-0005：Namespace 撤销栅栏与派生缓存权限继承

- **状态：Accepted**
- **接受日期：2026-07-20**
- **日期：2026-07-18**

- **接受依据：** namespace generation、commit 栅栏、撤销清理和派生权限继承已进入生产路径并覆盖竞态测试。

## 背景

仅在登出时删除当前缓存并不足够。登出前启动的下载、解码或 Analysis 任务可能在清理后完成并重新提交数据，造成“已删除数据复活”。此外，DerivedEncoded 与 Analysis 若不继承来源的 `no-store`、namespace 和隐私等级，会绕过原始响应限制。

## 决策

1. 每个安全 namespace 具有单调递增的 `NamespaceGeneration`。
2. 每个任务、record 和事务捕获创建时 generation。
3. 登出/撤销先原子标记 generation revoked，再异步取消和物理清理。
4. Commit 必须在最后一刻验证 generation 仍 active；旧 generation 的结果不得写入任何缓存层。
5. UI 对私有 namespace 的逻辑清理立即生效，物理文件删除可以延迟。
6. OriginalEncoded、DerivedEncoded、Analysis、Raster 和 memory 结果均继承来源的 namespace 与持久化上限。
7. `no-store` 禁止一切持久派生；`no-transform` 禁止持久格式转换/有损派生，但不妨碍为显示进行临时解码。

## 后果

每次 Commit 多一次廉价 generation 检查，换取登出和权限撤销的确定性。后台任务不会在清理后重新污染缓存。

## 验证门禁

- logout 与下载/解码/Analysis Commit 的所有竞态下残留为零；
- revoke 后旧任务不再向 UI 交付私有结果；
- Derived/Analysis 永不扩大 source 的缓存权限；
- 物理删除失败不改变逻辑不可达性。
