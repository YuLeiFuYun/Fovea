# Fovea 与独立图像 codec 并行推进路线图

> **状态：Active roadmap，2026-07-27。** 本路线图按证据门而非日历承诺推进。codec 的内部格式和算法尚未冻结，因此所有时间只能在工作包估算后给出，不能用虚假日期替代未知量。

## 1. 目标状态

最终系统由两个可独立发布、可独立回滚的工程组成：

```text
Fovea host
  fetch / auth / cache / admission / identity / diagnostics / UI / persistence
        │
        └── public ImageCraftCore codec contract
                │
                ├── independent ImageCraftImageIO product (current default)
                └── AxiomRaster / third-party codec product (explicit injection)

independent codec repository
  parser / decode / encode / progressive / animation / HDR / SIMD
        │
        └── technology-neutral conformance kit + fixture manifest
                      parser / decode / encode / progressive / animation / HDR / SIMD
```

关键约束：

- Fovea 不等待 codec 才继续改进；
- codec 不依赖 Fovea 网络、缓存或 UI 才能验证；
- 集成通过 contract、corpus 和 benchmark，而不是共享内部类型；
- 任一后端都可以按 descriptor fingerprint 独立缓存、canary 和回滚；
- 在新 codec 达到 default gate 前，ImageIO 保持参考后端。

## 2. 已完成基线

### F0：host contract 基线 — 已完成

- 有限 capability request/descriptor；
- format、delivery、track、metadata、range、output、cancellation；
- strict progressive generation 与 checked frame timing；
- conservative resource join；
- backend/version/contract fingerprint；
- ImageIO conservative adapter；
- pipeline 分配前协商与 prepared cleanup；
- Swift conformance tests 与 Python model checker。

### C0：codec 项目接口输入 — 可立即采用

独立 codec 项目先实现稳定的 bounded probe、resource facts 和 reference decode，并只依赖独立 `ImageCraftCore` 产品。共享 conformance kit 用 fixture manifest 与行为 oracle 验证这些事实；尚未完成的能力在公开 descriptor 中明确声明为不支持，而不是阻塞任一项目。

## 3. 双轨里程碑

| 阶段 | Fovea lane | Codec lane | 共享验收物 |
|---|---|---|---|
| 1 | F1 提取可复用 conformance kit | C1 有界 parser/probe | descriptor + probe corpus + format consistency |
| 2 | F2 明确 backend registry/opt-in policy | C2 静态主帧 reference decode | still-image differential suite |
| 3 | F3 shadow decode 与对照 telemetry | C3 resource/cancellation/lifecycle | resource oracle + leak/cancel suite |
| 4 | F4 progressive delivery pipeline | C4 progressive bitstream/decode | generation stream conformance |
| 5 | F5 animation scheduler/window cache | C5 animated tracks/timing/disposal | animation timeline corpus |
| 6 | F6 HDR/output surface integration | C6 color/HDR/pixel-buffer/planar | color and output representation suite |
| 7 | F7 canary/default/rollback governance | C7 optimization, SIMD, hardware | preregistered comparative evidence |

阶段可以交错，但共享验收物必须按顺序成熟。例如 codec 可以提前研究 SIMD，Fovea 不能因此跳过 C1/C2/C3 的 correctness 与 lifecycle gate。

## 4. Fovea lane

### F1：把 conformance kit 变成跨仓库资产

交付：

- 独立 Swift package、语言中立 manifest，或可 vendor 的测试 target；
- 由独立 `ImageCraftCore` 产品承载的 capability/failure schema 文档；
- backend factory / command-line harness；
- capability finite-domain oracle；
- probe/decode identity、resource、cancellation、prepared cleanup 测试；
- fixture manifest：格式、预期尺寸、帧、颜色、orientation、错误类别、资源上限；
- compatibility policy：host 支持哪些 contract version。

完成门：ImageIO adapter 与一个故意缺能力的 fake backend 都运行同一套 kit；独立 codec 仓库只导入 `ImageCraftCore` 即可运行相同 fixture/oracle。

### F2：backend registry 与显式选择

只在第二个 backend 通过 F1 后引入。建议最小 API：

```text
registered descriptor set
+ request capability requirement
+ explicit preferred backend / host policy
→ selected backend or stable unsupported failure
```

首版不得做“智能最优选择”。选择顺序必须确定、可观察、可测试；不得因机器负载或 hash map 顺序随机变化。

完成门：

- 同 request 在同配置下选择确定；
- capability 缺口不 fallback 到语义更弱后端；
- selected fingerprint 进入 DecodeKey/RenderKey；
- registry 变化不会读取旧 backend 像素；
- policy 可被禁用并回退到 ImageIO-only。

### F3：shadow decode

在不影响用户输出的采样请求上同时运行 reference 与 candidate：

- candidate 输出不进入用户 cache；
- 独立 budget，不能挤占 foreground decode；
- 记录成功、错误分类、尺寸、metadata、像素摘要、质量差异、CPU、wall time、peak RSS；
- 私有/授权图片默认不 shadow，除非明确合规；
- payload 不上传，结果日志脱敏。

完成门：无用户可见语义变化；shadow 可在运行时整体关闭；所有额外资源有硬上限。

### F4：progressive delivery

需要新 pipeline contract，而不是复用静态 `image(for:)` 返回值：

- encoded stream 累计字节预算；
- generation strictly increasing；
- preview cadence/coalescing；
- 同一 content/backend/request identity；
- subscriber priority 与最后订阅者取消；
- preview 不进入 final cache；
- final promotion 只有一次；
- malformed final、取消和 generation rollback 的确定行为；
- UI 只在 identity 未变化时接收后续 generation。

完成门：W4 workload、分块 metamorphic tests、慢网/取消/重订阅、峰值内存、真机 UI trace。

### F5：animation

独立于 progressive：

- track 选择；
- timestamp/duration/loop/disposal/blend；
- bounded decode window；
- frame cache budget；
- visibility/background/Reduce Motion；
- dropped-frame 和 clock policy；
- static poster fallback。

完成门：W5 workload、不同 disposal/loop corpus、后台前台、内存警告和低性能设备。

### F6：HDR 与输出表示

- source primaries/transfer/matrix；
- orientation 与 crop 顺序；
- SDR/HDR identity；
- tone-map policy；
- CGImage/pixel buffer/planar ownership；
- stride/alignment/lifetime；
- CPU/GPU synchronization；
- EDR 真机显示验证。

“零拷贝”只能在 instrumented trace 证明具体路径没有复制时使用，不能由类型名称推断。

### F7：candidate rollout

顺序：

1. developer opt-in；
2. test-only backend；
3. shadow sample；
4. internal canary；
5. format-scoped opt-in；
6. small percentage default；
7. broader default；
8. ImageIO fallback/rollback 保留至少一个稳定发布周期。

任何阶段都必须能通过配置关闭 candidate，而不迁移或删除原始 encoded data。

## 5. Codec lane

### C1：有界 parser/probe

必须先于优化 decode：

- 所有 offset/length/stride 使用 checked arithmetic；
- width/height/pixels/frame/metadata/nesting/scan/attachment 有硬上限；
- incomplete、unsupported、malformed、resource-limit 分离；
- chunked input 的状态机可重复；
- probe 不分配全尺寸像素；
- parser fuzz、seed corpus、历史漏洞 corpus、coverage gate；
- API 不暴露悬空 pointer 或不明 ownership。

### C2：静态主帧 reference decode

先建立 correctness，再做 SIMD：

- reference/scalar path；
- orientation、alpha、color profile；
- deterministic output 条件；
- exact/lossless 与 tolerance/lossy oracle 分离；
- 对 ImageIO、libjpeg-turbo、libjxl、libavif 等适用 reference differential；
- malformed input 不产生部分“成功”像素。

### C3：资源与生命周期

- 峰值 working-set 估计定义；
- estimate 对参数单调或明确反例；
- decode 前可计算的上界与 decode 中动态增长策略；
- operation-boundary/interruptible cancellation 的真实声明；
- reset/close/discard 幂等性；
- 并发 instance、共享 table、thread-local scratch 的所有权；
- leak、double free、use-after-free、race sanitizer。

### C4：progressive

- generation 定义必须由 bitstream/decoder 状态决定；
- 同 frame generation 严格增加；
- partial bytes 不可无限保留；
- 分块方式不改变 final output；
- preview 质量/成本曲线；
- final full-detail 与一次性完整 decode 对齐；
- abort 后状态是否可复用必须写入 contract。

### C5：animation

- track/frame metadata；
- timestamp/duration/loop；
- disposal/blend/reference frame；
- random access 与顺序 decode 能力；
- bounded frame window；
- 恶意 frame count/duration；
- 静态 poster 与 animated track 的选择规则。

### C6：HDR/颜色/输出

- ICC/CICP/EXIF 等来源优先级；
- bit depth、float/integer、premultiplication；
- gamut/transfer conversion；
- metadata preservation；
- planar/interleaved、stride/alignment；
- host-owned 与 codec-owned buffer；
- GPU surface 生命周期。

### C7：优化

优化顺序建议：

1. profile 真实 corpus；
2. 消除算法级冗余；
3. scratch reuse 与 cache locality；
4. vectorization/SIMD；
5. threading；
6. hardware acceleration；
7. learned/generative experimental lane。

每项优化必须保留 scalar/reference oracle 和 sanitizer/fuzz lane。性能提升不能通过放宽输入验证、忽略 metadata 或改变默认质量参数获得。

## 6. 共享 conformance kit

### 6.1 必测接口

- `codecDescriptor`；
- bounded `probe`；
- `resourceEstimate`；
- still decode；
- prepared state create/consume/discard；
- future progressive/track interfaces only when implemented。

### 6.2 corpus 分层

| 层 | 内容 | 是否进入公开仓库 |
|---|---|---|
| A | 小型规范正常样本 | 是 |
| B | 边界尺寸/metadata/frame/scan | 是 |
| C | 历史漏洞与恶意生成 | 许可允许时；否则 manifest/hash |
| D | 大型真实摄影/插画/透明/HDR | manifest + 下载脚本或 LFS 策略 |
| E | held-out evaluator corpus | 否，独立保管 |
| F | 用户真实私有数据 | 默认禁止 |

### 6.3 oracle

- parser facts：规范/reference；
- lossless pixels：exact；
- lossy pixels：明确 tolerance + quality metrics；
- color/HDR：reference transform 与真机 visual/instrument evidence；
- performance：同设备、固定 build、warmup、交错重复、分布与置信区间；
- resource：peak RSS + allocator/VM trace，不能只看平均内存；
- cancellation：最大观察延迟和资源回收时限。

## 7. 成为默认后端前的证据门

新 codec 只可在满足全部适用条件后成为某格式默认：

1. contract/conformance 全绿，descriptor 无夸大；
2. 规范正常 corpus 与 held-out corpus 无未知错误；
3. malformed corpus、fuzz、sanitizer 达到预注册时长/coverage，零未处置 crash；
4. probe、decode、metadata、orientation、color 的 differential 差异均分类；
5. 无 cache identity collision；
6. 资源估计不低于已观测峰值加安全余量，host hard limit 可阻断；
7. 取消和 preparation/resource cleanup 有确定性测试；
8. 同设备性能实验给出 median、tail、peak RSS、CPU/energy，而不是单次最好值；
9. lossy codec 给出 rate-distortion/perceptual 指标与参数，不使用不可比默认值；
10. W1-W3 不回归；新增能力还需 W4/W5/W9 等对应 workload；
11. canary 无新增 crash、OOM、错误像素或持久 cache 污染；
12. rollback 演练通过，ImageIO reference path 仍可启用；
13. accountable human review 与独立 evaluator 完成。

“比 ImageIO/libjpeg-turbo 更强”必须写成逐维、逐格式、逐设备的有界结论。例如：

> 在设备 D、版本 V、JPEG corpus C、quality 参数 Q 上，candidate 的 p50 decode latency 低 X%，同时 peak RSS 不高于 Y、质量指标不劣于阈值 Z。

不得从某一维结果推出整体世界最佳。

## 8. 回滚与迁移

- original encoded data 永远不绑定 decoder；
- decoded/rendered cache 绑定 backend fingerprint；
- candidate 关闭后旧 candidate pixels 自然失配或按 namespace 清理；
- fallback 只允许在 final commit 前发生，不能在已经发布 candidate pixels 后静默切换 identity；
- schema/contract 不兼容时拒绝加载，而不是猜测；
- rollback 不删除研究 corpus、失败证据或版本差异；
- 若 candidate 产生错误像素，先全局关闭，再按 fingerprint 清理派生结果，不重下载可复用 original bytes。

## 9. 并行执行建议

### 当前立即可做

Fovea：

- 把 conformance tests 抽出为可复用 kit；
- 维护公共 descriptor、prepared lifecycle、diagnostics 和 test traceability；
- 继续 W1-W3、资源、网络、UI、持久化改进；
- 为 F2 设计最小 registry，但不实现自动策略。

Codec：

- 先实现 C1 bounded probe 与 C2 scalar/reference still decode；
- 从第一天接入 fuzz/sanitizer/corpus manifest；
- 直接实现 `ImageCodec` capability descriptor 与 resource estimate；
- 建立与现有 reference 的 differential harness。

共享：

- 固定 contract version；
- 定义 fixture manifest 与 failure taxonomy；
- 每次 contract 变更同时跑 ImageIO 与 candidate conformance。

### 暂不做

- Fovea 自动选择“最快”后端；
- 未经 conformance 的 candidate 直接进入 production pipeline；
- 把 learned model、LoRA 或生成式细节写入 Fovea public API；
- 为未知 codec 内部结构继续增加 host 抽象层；
- 因 enum 已存在而关闭 progressive/animation/HDR gap。

## 10. 决策触发点

只有出现以下证据才新增 ADR：

- 第二个 backend 通过 F1 且出现同一 pipeline 多后端需求，触发 registry/selection ADR；
- candidate progressive 通过 C4，触发 progressive stream ADR；
- animation corpus 与 C5 通过，触发 animation scheduler ADR；
- HDR 真机 surface/identity 证据形成，触发 color/HDR ADR；
- resource estimate 无法由单一峰值表达，触发分阶段 budget ADR；
- benchmark 证明 ImageIO 不应再是某格式 default，触发 rollout ADR。

这使架构跟随证据演进，而不是围绕尚未完成的 codec 进行猜测性设计。
