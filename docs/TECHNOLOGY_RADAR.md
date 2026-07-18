# Fovea Technology Radar

> 本文跟踪前沿技术，不构成稳定 API 或版本承诺。技术可在 AI 辅助下立即并行原型化，但只有通过架构文档中的毕业条件才进入生产模块。Capability Slot 是正交的架构接缝，不属于任何雷达环。

## Adopt / Accepted Stable Core

当前为空。Phase 0b 尚未完成，任何技术都没有取得 Stable/Accepted 兼容承诺。

## Trial

### Core v1 Candidate

- ImageIO target-size decode；
- Fovea Private Image Cache Profile（RFC 9111 适用子集 + 外部 conformance corpus）；
- content-addressed OriginalEncoded；
- stable canonical key encoding 与 StoreGeneration；
- security namespace + revoke/commit fence；
- bounded streaming and spill-to-disk；
- DecodeLimits；
- fixed-stage single-flight + subscriber-driven priority；
- trace-based benchmark；

### Experimental Modules

- DerivedEncoded 强准入；
- S3-FIFO、SIEVE、size-aware TinyLFU 的真实图片 trace 对比；
- progressive preview；
- HDR gain map 和 lazy auxiliary attachments；
- representation candidate/srcset；
- ThumbHash/BlurHash extras；
- C2PA/JPEG Trust observe 插件；
- Vision crop proposal；
- 可复用像素缓冲池；
- 动画 decode window / frame cache policy；
- HDR/gain-map 表示正确性矩阵。

## Assess / FoveaLab Research

- JPEG AI（ISO/IEC 6048-1:2025）和移动端实现；
- JPEG AI file format/profile/reference software 演进；
- 学习型压缩与 conventional codec sandwich；
- no-reference image quality advisor；
- 端侧 faithful/reconstructive enhancement；
- 学习增强缓存与预取；
- compressed-domain machine representation；
- 空间图、深度和更多辅助平面；
- 更细粒度 GPU/ANE/energy governor。

## Hold / Rejected or Deferred

- 生成式图片创作进入 Fovea Core；
- 无真实 trace 的在线学习缓存默认策略；
- 默认 require-valid trust；
- 所有图片默认未压缩磁盘存储；
- 通用动态 DAG/算子运行时；
- 为尚不存在的模型冻结公共张量 API；
- 宣称“完整通用 RFC 9111 cache”而没有 profile 边界；
- 使用 Swift `hashValue`/`Hasher` 生成持久缓存键。

## 主要信号来源

- JPEG AI：https://jpeg.org/jpegai/
- JPEG Trust：https://jpeg.org/jpegtrust/
- C2PA：https://spec.c2pa.org/
- RFC 9111：https://www.rfc-editor.org/rfc/rfc9111.html
- WPT HTTP cache：https://github.com/web-platform-tests/wpt/tree/master/fetch/http-cache
- HTTP cache tests：https://cache-tests.fyi/
- S3-FIFO：https://s3fifo.com/
- SIEVE：https://cachemon.github.io/SIEVE-website/
- Nuke：https://github.com/kean/Nuke
- Kingfisher：https://github.com/onevcat/Kingfisher
- SDWebImage：https://github.com/SDWebImage/SDWebImage
