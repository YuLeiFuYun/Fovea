# ADR-0001：Phase 0a 模块边界与原型兼容策略

- **状态：Accepted**
- **日期：2026-07-18**
- **范围：ImageCraft、Akashic 与 Fovea 的 Phase 0a 产品边界**

## 背景

Fovea 的早期原型曾把 UIKit 图片类型、缓存、显示适配和平台生命周期混在一起。该形态不作为当前实现的兼容约束，也不再保留旧架构副本。当前仓库以 SwiftPM manifest、源码依赖和自动化边界检查作为唯一事实来源。

## 决策

1. **ImageCraft** 只负责图像探测、解码及图像值模型；平台 ImageIO 实现位于独立 product。
2. **Akashic** 是图片无关的缓存基础设施：
   - `AkashicMemory` 提供 `MemoryCache<Key, Value>`；
   - 值成本由调用者显式传入；
   - 不依赖 `ImageCraftCore`、`DecodedImage`、URL、HTTP 或 UI。
3. **FoveaCore** 只通过 `ImageDecoding`、`HTTPTransporting`、`OriginalEncodedStoring` 与 `RepresentationRecordStoring` 协议组合具体实现。
4. Phase 0a 使用固定职责 stage：
   - `FetchStage`：精确 fetch identity、single-flight、传输与 fetch permit；
   - `DecodeStage`：安全 probe、目标尺寸 decode 与 decode permit；
   - `PipelineCache`：record/blob/RenderedMemory 事务与撤销回滚；
   - `FoveaPipeline`：状态机编排，不提供动态 DAG 或 interceptor graph。
5. 旧原型 API、旧磁盘格式和旧架构文件不提供兼容承诺；Git 历史承担追溯责任，活动树只保留当前事实。

## 已验证结果

- SwiftPM product 边界已建立；
- `AkashicMemory` 不依赖图像模块；
- `FoveaCore` 不依赖具体 ImageIO decoder；
- UIKit/AppKit 类型未进入 ImageCraftCore/AkashicCore；
- 生产代码无未经审计的 `@unchecked Sendable`；
- `scripts/check-phase0a-surface.py` 对允许模块和关键边界执行机器检查；
- macOS/iOS 测试、sanitizer、mutation 与 rollback gate 对这些边界提供回归证据。

## 后果

- Phase 0a 不为旧原型保留适配层或弃用别名；
- 新能力必须进入正确 product，不能为了减少文件数跨越职责边界；
- DecodeKey 级共享、完整资源 governor、平台压力监听和多进程 store 属于后续阶段，不通过预建空抽象进入 0a。
