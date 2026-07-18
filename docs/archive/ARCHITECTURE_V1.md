# Fovea 图片加载库群 · 架构设计文档

> 一套模块化的 Swift 图片加载系统,目标是在架构、加载速度、内存占用、可验证性上确立相对
> Kingfisher / SDWebImage / Nuke / YYWebImage / PINRemoteImage / AlamofireImage 的代际优势。
>
> **状态**:设计定稿,尚未开工。本文件是唯一的权威设计来源(single source of truth)。
> **平台**:iOS/iPadOS 15 · macOS 12 · watchOS 8 · tvOS 15 · visionOS 1。
> **语言**:Swift(async/await + 严格并发),Apple 平台专属。

---

## 目录

1. [核心理念](#1-核心理念)
2. [仓库拆分:确定方案](#2-仓库拆分确定方案)
3. [依赖规则(铁律)](#3-依赖规则铁律)
4. [四层身份模型](#4-四层身份模型)
5. [缓存分层](#5-缓存分层)
6. [下载:哑传输 vs 智能调度](#6-下载哑传输-vs-智能调度)
7. [主执行路径](#7-主执行路径)
8. [并发模型](#8-并发模型)
9. [图像引擎(ImageCraft)](#9-图像引擎-imagecraft)
10. [缓存引擎(Akashic)](#10-缓存引擎-akashic)
11. [智能层(Oneiros / FoveaIntelligence)](#11-智能层-oneiros--foveaintelligence)
12. [解压位图存储:结论](#12-解压位图存储结论)
13. [命名](#13-命名)
14. [平台与最低版本](#14-平台与最低版本)
15. [“更好”的可证伪定义](#15-更好的可证伪定义)
16. [落地路线图](#16-落地路线图)
17. [关键决策记录(含被否决的方案)](#17-关键决策记录含被否决的方案)
18. [参考来源](#18-参考来源)

---

## 1. 核心理念

这个项目群的代际优势**不来自"模块拆得多"**。模块化本身已不再是竞争优势——Nuke 拆了 4 个 product,Coil 把网络/GIF/SVG/视频/Compose 都拆成独立模块。把优雅误解成包的数量,是设计陷阱。

真正的优势来自五个被明确设为一等公民的东西:

1. **内容身份(Content Identity)** —— URL 是定位符,不是内容身份。正确的缓存键来自分层身份(见 §4),这直接支撑"同 URL 不同处理"的阶段级共享,也是 HTTP 验证器 / 认证隔离的基础。
2. **目标像素优先(Target-Pixel-First)** —— 第一性能原则是"不产生不需要的像素"。永远优先目标尺寸解码,而非全尺寸解码后再 resize。
3. **阶段共享(Stage-Level Sharing)** —— 加载不是线性流水线,而是阶段 DAG。同 URL 不同圆角的两个请求共享下载、分叉处理。
4. **资源预算(Resource Budgets)** —— 网络/磁盘/解码/处理各有独立并发预算,随内存压力、thermal、低电量动态收缩。
5. **可验证性能(Verifiable Performance)** —— 每一条性能声明都对应固定工作负载 + 公开指标 + 可复现实验(见 §15)。

设计基准:一个新库要"超过现有库",必须在**这五个维度**上做到明显更好,而不是再堆几个链式 API。

---

## 2. 仓库拆分:确定方案

**拆成独立仓库的唯一标准**:这个边界是否需要成为「可独立演进、可被外部替换、有独立生命周期」的长期契约。职责不同不是拆仓库的理由(那只是拆文件/类型的理由)。

按此标准,**确定为三个生产仓库**,内部用 SwiftPM Products 细分:

```
仓库 1  ImageCraft ── 面向显示、尺寸感知的 Apple 图像引擎(已有仓库)
  Products:
    ImageCraftCore         协议 + DecodedImage + 格式探测
    ImageCraftImageIO      ImageIO 解码/编码/目标尺寸/增量
    ImageCraftProcessing   TransformPlan 规划与融合、后端选择
    ImageCraftAnimation    动图容器、帧调度
    ImageCraftTesting      测试替身
  受众:只想要解码/处理库、不要加载器的人。

仓库 2  Akashic ──── 通用字节感知缓存引擎(已有仓库)
  Product:
    Akashic                Mnemosyne(内存)+ Elysium(磁盘)+ 可替换策略协议
  受众:要一个通用缓存(缓存任何 CostCalculable 字节)的人。
  它不知道图像、URL、UI 的存在。

仓库 3  Fovea ────── 加载器主仓 · 伞名(新建)
  核心 Products:
    FoveaCore              管线引擎 + 四层身份 + 阶段 DAG + 智能调度
    FoveaTransport         哑传输协议 + URLSession 默认实现
    FoveaUI                UIKit / AppKit 集成
    FoveaSwiftUI           FoveaImage
    FoveaDiagnostics       os_signpost 可观测性
    FoveaTesting           故障注入 + 竞品 benchmark 适配器
    Fovea                  默认聚合产品
  可选 Products(同仓 Target,非独立仓库):
    FoveaIntelligence      智能层:神经超分 / 内容感知裁剪 / ThumbHash 占位
    FoveaWebP / FoveaAVIF / FoveaJXL / FoveaSVG   格式插件(低版本兜底)
    FoveaVideo / FoveaPhotos                      视频帧 / Photos 集成
    FoveaRasterStoreExperimental                  未压缩位图缓存实验
  依赖:ImageCraft + Akashic。
  受众:要完整图片加载系统的人。
```

### 为什么是三个,不是二 / 四 / 八

- **不合并成两个**(缓存并进加载器):会毁掉 Akashic 作为通用缓存库的独立复用价值,也丢掉已有仓库认知。
- **不拆成四个**(传输独立成仓库):哑传输太薄,没有独立用户群会单独引它;独立成仓库只增加一个版本兼容矩阵,零收益。作为 `FoveaTransport` Product 即可。
- **不拆成八个**(早期版本曾设想):过度切割性能关键路径,徒增跨仓库兼容矩阵成本,把优雅误解成包数量。
- **三个是稳定点**:每个都满足「有独立用户群 + 可独立工作 + 值得独立发版」。

### 第四个仓库的“毕业标准”

Fovea 内某个 Target 只有**同时**满足以下条件,才值得升级为独立仓库:

1. 有独立用户群(有人只要它,不要 Fovea);
2. 有独立发布周期;
3. 有特殊许可证或 C/C++ 构建依赖(如 `FoveaJXL` 拖了 GPL 的 C 库,会污染主库许可证);
4. 主库不用它也能完整工作;
5. 跨仓库兼容矩阵不会频繁变化。

最可能第一个毕业的是带 C/C++ 依赖的格式插件(`FoveaJXL`/`FoveaAVIF`),符合第 3 条。**但 v1 不做。**

---

## 3. 依赖规则(铁律)

单向依赖,严禁下列耦合:

- ❌ ImageCraft 依赖 Fovea 或 Akashic
- ❌ Akashic 知道 `UIImage` / `NSImage` / `URL` / `HTTP`
- ❌ FoveaTransport 直接操作磁盘缓存
- ❌ UI 层自己发起网络任务
- ❌ decoder 自己决定缓存键
- ❌ processor 用任意字符串临时拼接身份

```
App
 ├── FoveaSwiftUI / FoveaUI
 │        │
 │     FoveaCore ──── FoveaTransport
 │        │  │
 │        │  └── Akashic
 │        └───── ImageCraft
 │
 └── 可选:FoveaIntelligence / 格式插件
```

---

## 4. 四层身份模型

缓存正确性与阶段共享的基石。**URL 只是定位符,不是内容身份。**

```
RequestIdentity   一次资源请求
  = 规范化 URL + HTTP method + 影响响应的 headers
    + 认证用户/租户 namespace + Vary 相关字段 + 自定义资源版本

ResourceIdentity  实际内容版本
  = RequestIdentity + ETag / Last-Modified  或稳定内容摘要

DecodeIdentity    解码后的像素表示
  = ResourceIdentity + 目标像素尺寸 + scale + orientation
    + 色彩空间 + SDR/HDR + 动静态策略 + decoder 及其版本

RenderIdentity    最终显示结果
  = DecodeIdentity + 规范化处理图(crop/fit/fill + 圆角/模糊/色彩变换)
    + 处理算法版本
```

**阶段级 single-flight(而非 URL 级合并):** 两个请求「同 URL、不同显示尺寸、相同裁剪、不同圆角」应当:

- 共享网络下载(相同 ResourceIdentity)
- 可能共享元数据探测
- **不**共享目标尺寸解码(不同 DecodeIdentity)
- **不**共享最终圆角处理(不同 RenderIdentity)

**认证隔离(安全,非优化):** 认证资源必须按用户/租户 namespace 隔离,退出登录时可完整清除。否则相同 URL 会造成跨账户数据泄漏。这是 Kingfisher 等库的真实缺口,是本库的真差异点。

**Processor 身份必须结构化、版本化**,不能只是字符串:

```
processor type + algorithm version + normalized parameters
+ input/output color model + implementation backend
```

否则算法升级后,旧缓存结果会被错误复用。

---

## 5. 缓存分层

```
L0  Rendered 内存缓存    解压、目标尺寸、处理完成的显示结果
                        S3-FIFO + 字节/成本感知准入(见下)
L2  目标尺寸压缩衍生缓存  48MP 原图 → 目标尺寸 HEIF/WebP/JPEG 存盘
                        默认通用优化:二次读盘字节和解码像素都大减
L1  可选 RasterStore     未压缩位图,mmap slab 按尺寸+像素格式分类
                        v1 后实验 / 默认关闭 / 仅固定尺寸热点图(见 §12)
L3  原始压缩响应缓存      + HTTP validator(ETag/Last-Modified/Vary)
                        + 认证隔离 + checksum + schema version
额外  Metadata 内存缓存   尺寸/格式/颜色/动画帧等轻量元数据
```

**内存层默认只做两层:Rendered + Metadata。** Encoded(编码数据)内存缓存**不默认做大**——它常与磁盘缓存、OS page cache、网络缓冲重复占用内存,应作为小容量可选层,由实际基准决定。

### 淘汰与准入(修正了“直接套 S3-FIFO”的盲点)

图片缓存与普通对象缓存的关键区别:**对象大小相差可达几千倍**(60×60 头像 ≈ 14KB 解码 vs 48MP ≈ 数十 MB)。不能按"条目数"算,必须**字节 + 成本感知**。

Akashic 拆出可替换策略(见 §10):
- **EvictionPolicy**:默认 S3-FIFO(小 10% / 主 90% / 幽灵队列,2-bit 计数器,命中只 +1 不移动 → 读路径近乎无锁、抗扫描)。备选 SIEVE(单 FIFO + visited 位,更简单,原型对比)、LRU(基线)、W-TinyLFU(opt-in 极致命中率)。
- **AdmissionPolicy**:准入评分综合 `访问频率 + 对象字节数 + 解码成本 + 处理成本 + 重下载成本 + 过期风险`。
- **默认策略由真实 App trace 选定**,不因某论文平均命中率最高就拍板(S3-FIFO/W-TinyLFU 论文多假设等尺寸对象)。

### 磁盘层设计

```
content-addressed blob store(大图 file-per-entry,哈希名 + 2 字符前缀分片,256 桶)
+ SQLite WAL 元数据(尺寸/访问时间/TTL;小图 <20KB 内联,YYCache 式混合)
+ 原子临时文件 rename
+ checksum + schema version
+ 批量/惰性 access-time 更新(避免每次读更新 atime 造成写放大,损 flash 寿命)
+ namespace quota(按用户/租户隔离,登录态资源可完整清除)
```

区分四类磁盘内容:原始 HTTP 响应 / 目标尺寸压缩衍生物 / 可选未压缩 Raster / 元数据与验证器。写回暂存(staging)+ 异步 IO 队列(并发读 / barrier 写)+ 解码离主线程。**mmap 不用于通用磁盘缓存**(page fault 同步会阻塞线程),仅保留给 L1 固定尺寸热点。

---

## 6. 下载:哑传输 vs 智能调度

下载内部是两种性质完全不同的东西,分清才能正确决定"拆还是合"。

**A. 哑传输(FoveaTransport,独立 Product):**
- 职责:字节从网络搬到内存。`URLSession.bytes(for:)` 进,`AsyncStream<Data>` 出 + 取消 + 进度 + Range 续传。
- 对外**零依赖**,是叶子。可被非图片项目复用。
- 是可替换协议(`Transport`)+ URLSession 默认实现。想换 HTTP 栈 / mock 测试 / 非 HTTP 源,实现协议即可。

**B. 智能调度(FoveaCore,不可拆出):**
- 职责:请求合并/去重、订阅者引用计数、取消传播、优先级提升降级、预取、限流(令牌桶)、网络与解码间的背压、渐进式解码节流。
- **必须与缓存查询、解码调度原子演进**,原因:
  - 去重键要在"知道是否缓存命中之前"就算出来 → 去重发生在缓存查询这一步。
  - 取消是跨"缓存订阅 + 网络订阅"引用计数的 → 最后一个订阅者离开才真正取消上游。
  - 优先级是 UI → 解码 → 下载一条链传导的。

**结论:哑传输独立成 Product 可复用;智能调度绝不单独拆成库/仓库,否则招致双重去重、跨边界取消错乱、优先级反转。** 所有参考库(Nuke/Kingfisher/SDWebImage)都保留可替换的传输**协议**,但把智能调度留在管线内——这是它们共同选择"不切"的关节。

---

## 7. 主执行路径

```
Request 规范化(生成四层身份)
        ↓
Render 内存缓存(L0)命中 → 交付
        ↓ miss
可选 RasterStore(L1)
        ↓ miss
目标尺寸压缩衍生缓存(L2)
        ↓ miss
原始响应缓存 / HTTP Validator(L3)—— 命中则条件 GET 重验(ETag/If-None-Match)
        ↓ miss
FoveaTransport 流式获取(阶段级 single-flight 合并)
        ↓
格式与尺寸探测(ImageProbe)
        ↓
目标尺寸解码 / 增量解码(渐进式按新增字节+scan+可见性+队列压力节流)
        ↓
变换规划与融合(TransformPlan → 1~2 次像素写入)
        ↓
[可选]智能重建(Oneiros:神经超分)
        ↓
后台显示准备(prepareForDisplay,字节对齐)
        ↓
分层提交缓存(L0/L2/L3 各按身份)
        ↓
UI 交付
```

每阶段可被拦截器短路/改写(鉴权、CDN URL 重写、Mock、日志),无需改核心。

---

## 8. 并发模型

**不使用单一全局 actor 包整个管线**——那会把缓存命中、取消、网络事件、进度、解码提交全部串行化。

```
actor 只保护:任务注册表 + 订阅关系
隔离区外执行:网络 / 磁盘 / 解码 / 处理
每个共享阶段:维护订阅者引用计数
             最后一个订阅者取消时才取消上游
             新的高优先级订阅者可提升共享任务优先级
并发预算:   网络 / 磁盘 / 解码 / 处理 各自独立
动态收缩:   内存压力 / thermal state / 低电量 触发预算缩减
```

**锁的选择(受 iOS 15 底线约束):**
- iOS 16+:`OSAllocatedUnfairLock<State>`(安全 Swift 包装,`withLock { }`)。
- iOS 15:裸 `os_unfair_lock`(稳定指针;Akashic 现有实现即此)。
- **不可用** `Mutex`(Synchronization 框架需 iOS 18)。三者底层同为 `os_unfair_lock`,性能一致。
- 独立计数器(频率、命中统计)用 `Atomic`(需 iOS 16;15 用原子包装或锁)。

**不预设"actor 一定比锁好"或"os_unfair_lock 一定最快"** —— 由争用模型和 benchmark 决定。内存缓存的同步 get/put 热路径**用锁不用 actor**(actor 的 await 传染 + executor 跳转 + 非重入不适合热路径);actor 仅用于粗粒度异步组件(磁盘 IO 协调、管线任务注册表)。

---

## 9. 图像引擎(ImageCraft)

**定位:面向显示、尺寸感知、安全、可增量的 Apple 平台图像引擎**(不是"图片滤镜大全")。

### 稳定协议

```swift
protocol ImageProbe              // 格式/尺寸/颜色/HDR 探测
protocol ImageDecoder            // 目标尺寸解码
protocol IncrementalImageDecoder // 渐进式解码
protocol ImageEncoder            // 编码(用于 L2 衍生物)
protocol ImageProcessor          // 提交 TransformPlan
protocol ImageTransformPlan      // 变换意图,供 planner 融合
protocol ImageFormatDetector     // 魔数签名嗅探
```

### 像素表示:不造跨平台 PixelBuffer

仅 Apple 平台,`CGImage` + ImageIO + Core Graphics + vImage 已是天然基础设施。**不为"跨平台纯洁性"再造像素抽象层**(除非未来要支持 Linux/Windows/服务端)。用不可变包装:

```swift
struct DecodedImage {
    let cgImage: CGImage
    let scale: CGFloat
    let orientation: CGImagePropertyOrientation
    let colorProfile: ColorProfile
    let dynamicRange: DynamicRange
}
```

平台适配层再生成 `UIImage` / `NSImage`。

### 处理器提交“意图”,不立即执行

resize / crop / 圆角 / 色彩转换 / premultiply 先形成 `TransformPlan`,由 planner 判断能否融合成一两次像素写入。libvips 的启示是**需求驱动、区域化计算、避免中间全尺寸位图**,而非把 libvips 搬到 iOS。

### 后端选择:Metal 不是默认

默认按尺寸和处理链比较后端:`ImageIO / vImage / Core Graphics / Core Image / Metal`。小图的纹理创建 + 命令提交 + CPU/GPU 同步可能超过实际计算成本,不强制 GPU。

### 格式(iOS 15 底线下的策略)

- 原生 ImageIO:JPEG / PNG / GIF / HEIC / WebP(iOS 14+)。
- **AVIF 解码需 iOS 16+** → iOS 15 用户靠 `FoveaAVIF`(libavif)插件兜底。
- **JPEG XL** iOS 15 运行时无原生 → `FoveaJXL` 插件必需。
- 开工前用 `CGImageSourceCopyTypeIdentifiers()` 在每个目标 OS 版本**实测**确认。
- **字节对齐**(`bytesPerRow` 64 字节对齐)是解码层默认行为——免费,让 Core Animation 免拷贝直用 CGImage。

---

## 10. 缓存引擎(Akashic)

**定位:通用字节感知缓存,不知道图像/URL/UI。** 缓存任意 `CostCalculable` 值。

### 可替换策略(全部协议化)

```swift
protocol AdmissionPolicy    // 是否准入(字节+成本感知)
protocol EvictionPolicy     // 淘汰谁(S3-FIFO 默认)
protocol CostModel          // 如何计成本(按字节/帧数)
protocol ExpirationPolicy   // TTL / 过期
protocol StorageBackend     // 内存 / 磁盘
protocol Serializer         // 编解码为可存储字节
```

### 内存(Mnemosyne)

- 现有 FIFO+LRU 混合 + `os_unfair_lock` + 内存压力监听 + `CostCalculable`(按帧计成本)是**合理原型**,但不是最终默认。
- 升级:EvictionPolicy 默认 S3-FIFO(§5);AdmissionPolicy 字节+成本感知;跨平台化(`NSImage` 的 `CostCalculable`、按平台条件编译内存压力源)。
- 两层:Rendered(显示结果)+ Metadata(轻量元数据)。

### 磁盘(Elysium)

见 §5 磁盘层设计。content-addressed blob + SQLite WAL + 原子写 + checksum + schema version + 惰性 atime + namespace quota。

---

## 11. 智能层(Oneiros / FoveaIntelligence)

**可选,通过协议插入,不进核心依赖链。** Theia/Fovea 默认不依赖它;`import FoveaIntelligence` 才激活。验收标准:**去掉它,整个库群零影响照常工作。**

- **ThumbHash 占位符**(投入产出比最高):~20 字节字符串重建模糊预览,加载前先显示,叠加渐进式解码,"秒开"成默认体验。
- **内容感知裁剪**:Vision 显著性(`VNGenerateAttentionBasedSaliencyImageRequest`)+ 人脸检测,裁头像裁到脸。Apple 端侧免费,全 Swift 生态空白,低成本差异化。
- **神经超分**:MetalFX / Core ML 轻量模型,低清传输端侧放大。最重,最可延后。

接入方式:实现 Aegis/ImageCraft 的 `AsyncImageProcessing` 协议(GPU/NPU 异步变体),插入 FoveaCore 管线的"智能重建"阶段。

前瞻接缝(留缝不焊死):`ResourceProvider` 逃生舱口承接生成式/多模态来源(prompt 生成图、空间照片取帧、视频抽帧),现在不实现,接口留好。

---

## 12. 解压位图存储:结论

用户记忆中的 Objective-C 项目是 **Path 的 FastImageCache**(2013):把固定尺寸、固定像素格式的未压缩图放进 image table,`mmap` + 固定偏移读取,跳过重复 JPEG/PNG 解码,直接把裸字节喂给 Core Animation。

**结论:思想对,做法要现代化,推迟到 v1 后,默认关闭。**

- ✅ "跳过解码"思想 2026 仍有效(解码是最耗时环节之一)。
- ❌ "全量裸位图存磁盘"已过时:位图 = `宽×高×4`,一张 50KB 压缩图解码后 2–8MB,全量存膨胀几十倍。
- ⚠️ 纠正旧误解:**mmap 不等于内存免费**。映射页仍进工作集和 page cache、产生 page fault;它省的是显式拷贝和定位,不消除物理内存和磁盘读取。

**正解——分层(见 §5):**
- L0 内存存解压 CGImage(最该发生解压的地方,快、生命周期短)。
- **L2 目标尺寸压缩衍生缓存 = 默认通用优化**:48MP 原图 → 目标尺寸 HEIF/WebP 存盘,第二次仍需解码但读盘字节和解码像素都大减。这比裸位图缓存更通用、成本更低。
- L1 未压缩 RasterStore = v1 后实验,默认关,仅在**全部/大部分**满足时准入:尺寸固定 + 像素格式固定 + 多次访问 + 解码/处理成本经测量较高 + 位图较小 + 未来复用概率高 + 非长动画/超大 HDR + 磁盘预算充足 + 数据保护策略明确。实现用按尺寸+像素格式分类的 slab/table(非一图一文件),且必须可完全清空后从压缩缓存重建。
- 字节对齐全程保留(解码层默认,免费)。

---

## 13. 命名

**母题**:希腊神话 + 记忆/视觉/知识(延续用户已有的 Akashic/Mnemosyne/Elysium)。

**命名核查标准**:GitHub 无同名 ≠ 名字安全。正式定名前必须全渠道核查(GitHub + Swift Package Index + 域名 + App/软件商标 + 主流搜索引擎)。

| 名称 | 角色 | 核查结论 |
|---|---|---|
| **Fovea** | 伞名 / 主仓库 / 品牌 | 中央凹(视网膜最高分辨率处)——精准编码"只为视野中需要的像素投入最高资源"的架构灵魂。Swift 与全生态近零冲突。**采用。** |
| **ImageCraft** | 图像引擎仓库 | 用户已有仓库,保留。 |
| **Akashic** | 缓存仓库 | 用户已有仓库,保留。 |
| **Mnemosyne** | 内存缓存 | 记忆女神,已有,保留。 |
| **Elysium** | 磁盘缓存 | 极乐净土,已有,保留。 |
| **Oneiros** | 智能层内部代号(对外 `FoveaIntelligence`) | 梦神,塑造图像/幻象。Swift+全生态零冲突。 |

**被否决的名称:**
- **Theia**(视觉之神):Swift 生态干净,但全生态有 21.6k★ 的 eclipse-theia 云 IDE → 伞名 SEO/认知冲突,致命。仅可做内部库名,不做伞名。
- **Hephaestus**(工匠之神):全生态有 1.2k★ Python 项目,且长、难拼、难读 → 弃用。
- **Aperture / Prism / Photon / Iris**:光学词高度拥挤,弃用。

---

## 14. 平台与最低版本

| 平台 | 最低版本 |
|---|---:|
| iOS / iPadOS | **15.0** |
| macOS | **12.0** |
| watchOS | **8.0** |
| tvOS | **15.0** |
| visionOS | **1.0** |

**理由(用户拍板:用户触达 > 最新 API):** iOS 18 会砍掉大量潜在用户;对一个要被广泛采用的开源基础库,覆盖面优先。iOS 15 是合理平衡点——现代图像 API 的分水岭其实在 iOS 15 而非 18。

**iOS 15 底线的连锁影响(开工须遵守):**
- ✅ 可用:async/await、`URLSession.bytes(for:)`(异步字节流)、`UIImage.prepareForDisplay`/`byPreparingThumbnail`(iOS 15 引入)、`CGImageSourceCreateThumbnailAtIndex`(目标尺寸解码)。
- ❌ 不可用:`Mutex`(Synchronization,iOS 18)→ 用 `OSAllocatedUnfairLock`(16+)/ `os_unfair_lock`(15);iOS 17 Observation;最新 SwiftUI ScrollView API。
- ⚠️ 格式:AVIF 解码需 iOS 16+、JXL 无原生 → 靠插件兜底 iOS 15。

**注意**:这与 CardCarousel 的 iOS 18 底线不同——它们是不同项目,触达目标不同。

---

## 15. “更好”的可证伪定义

**不说"全面超过所有项目"**(不可执行)。改成工作负载契约 + 公开指标。

**固定工作负载场景:**
1000 个小头像 · 社交 feed 快速滚动 · 1–4MP 普通网络图 · 48MP 照片生成缩略图 · 详情页原图与缩放 · Progressive JPEG · GIF/WebP/HEIF 动画 · Display P3 与 HDR · 登录态私有图片 · 弱网/断网/断点恢复 · cell 高频复用与取消 · 冷缓存/暖磁盘/暖内存。

**公开指标:**
first-pixel 与 final-image 延迟(p50/p95/p99)· 主线程 hitch · 峰值 physical footprint · dirty memory · page fault · CPU/energy · 网络与磁盘总字节 · 重复下载/解码次数 · 取消后浪费的 CPU 与字节 · object hit rate 与 **byte hit rate** · 二进制体积。

**可复现的竞争目标(而非"每项第一"):**
- feed 工作负载中**同时**降低内存峰值和滚动 hitch;
- 大图缩略场景**从不**产生无必要的全尺寸位图;
- 请求取消后**几乎不**继续执行昂贵处理;
- 私有资源缓存身份**严格正确**(无跨账户泄漏);
- 相同功能下核心模块依赖和二进制体积**更小**;
- 每项性能声明提供**可复现实验**。

---

## 16. 落地路线图

**指导原则:最高风险的假设最先验证。** 本项目的命门不是"某算法快不快",而是"四层身份 + 阶段 DAG + 三仓库协议解耦能否优雅组合"。故先冻结契约、建基准,再垂直切片。

### Phase 0 · 冻结契约 + 建基准(不做这步不开始大规模 API 设计)

冻结以下契约:
```
RequestIdentity / ResourceIdentity / DecodeIdentity / RenderIdentity
TargetGeometry / ImageSource / Transport / CacheStore
Decoder / ProcessorFingerprint / PipelineEvent
```
同时建立:竞品(Nuke/Kingfisher/SDWebImage)benchmark 适配器 + 真机基准工程 + §15 指标采集(os_signpost)。

### Phase 1 · 静态图垂直切片(验证组合成立)

每个库最朴素实现,端到端跑通「URL → 屏幕出图」:
- URLSession 传输(FoveaTransport)
- 原始响应磁盘缓存(Akashic/Elysium)
- 目标尺寸 ImageIO 解码(ImageCraft)
- Rendered 内存缓存(Akashic/Mnemosyne)
- UIKit/AppKit/SwiftUI 基础接口
- 取消 + 同阶段任务合并
- os_signpost 指标

验收:三行代码加载网络图;**同时**验证 FoveaTransport / Akashic 能脱离库群单独使用。

### Phase 2 · 正确性与调度

- HTTP validator(ETag/Last-Modified)+ `Vary`
- 用户/租户 namespace 隔离
- 动态优先级 + 预取
- 渐进式解码节流
- 内存 / thermal 压力响应
- 崩溃恢复
- fuzzing 与故障注入

### Phase 3 · 生态功能

- 动画播放调度
- WebP / AVIF / JXL / SVG 插件(低版本兜底)
- Photos 与视频帧
- HDR 与广色域专项测试
- **Oneiros 智能层**(先 ThumbHash 占位 → 内容感知裁剪 → 超分)

### Phase 4 · RasterStore 实验

仅在 benchmark 和示例 App 中启用。**只有在固定尺寸热点场景中持续证明总收益高于 L2,才发布为正式可选产品。**

### 关键路径

```
Phase 0 ──► Phase 1(🔑组合验证)──► Phase 2 ──► Phase 3 ──► Phase 4
                                                   │
                              Oneiros 可与 3/4 并行,可延后到 1.x
```

---

## 17. 关键决策记录(含被否决的方案)

| # | 决策 | 结论 | 备注 |
|---|---|---|---|
| 1 | 拆几个仓库 | **3 个**(ImageCraft/Akashic/Fovea) | 曾设想 8 个,被"别把优雅误解成包数量"否决 |
| 2 | 下载是否独立成库 | **否**:哑传输作 Product,智能调度留 FoveaCore | 独立会招致双重去重、优先级反转 |
| 3 | 缓存键 | **四层身份模型**,非扁平 URL 键 | URL 是定位符不是内容身份 |
| 4 | 合并粒度 | **阶段级 single-flight**,非 URL 级 | 同 URL 不同处理共享下载分叉处理 |
| 5 | 默认磁盘衍生缓存 | **L2 目标尺寸压缩**,非裸位图 | 修正了早期 FastImageCache 结论 |
| 6 | 解压位图缓存 | **v1 后实验,默认关** | mmap≠内存免费;仅固定尺寸热点 |
| 7 | 缓存淘汰 | S3-FIFO 默认 + **字节/成本感知准入** | 不直接套等尺寸对象论文 |
| 8 | 并发 | actor 只护注册表,热路径用锁 | 不预设 actor 优于锁 |
| 9 | 像素抽象 | **不造跨平台 PixelBuffer** | Apple-only,CGImage 是天然基础 |
| 10 | HTTP 验证器/认证隔离 | **进核心**(安全,非优化) | Kingfisher 真实缺口 → 真差异点 |
| 11 | 处理后端 | 按尺寸+链选,**Metal 非默认** | 小图 GPU 开销可能超过计算 |
| 12 | 智能层(Oneiros) | **保留**,可选 Target,协议插入 | 外部方案漏掉,依据前几轮批准保留 |
| 13 | 伞名 | **Fovea** | 否决 Theia(21.6k★ IDE 冲突)、Hephaestus |
| 14 | 最低版本 | **iOS 15** / macOS 12 / watchOS 8 / tvOS 15 / visionOS 1 | 用户拍板覆盖面优先;否决 iOS 18 |
| 15 | "更好"标准 | **工作负载契约 + 公开指标** | 否决"全面超越"式不可证伪声明 |

---

## 18. 参考来源

**Swift/OC 库:** Nuke (`github.com/kean/Nuke`, kean.blog 深度文章)、Kingfisher (`github.com/onevcat/Kingfisher`)、SDWebImage、YYWebImage/YYCache (ibireme,`blog.ibireme.com/2015/10/26/yycache/`,《iOS 保持界面流畅的技巧》)、PINRemoteImage、AlamofireImage、FastImageCache (`github.com/path/FastImageCache`)。

**跨语言:** Coil 3 (拦截器链、ComponentRegistry)、Glide (bitmap pool)、Fresco (ashmem/off-heap、producer/consumer 管线、Drawee)、Picasso、Flutter (ImageProvider/ImageCache 三态)、image-rs (Limits 解压炸弹防护)、Thumbor/imgix/Cloudflare (URL 驱动变换、内容感知裁剪、format=auto)。

**缓存算法:** S3-FIFO (SOSP'23, `jasony.me/publication/sosp23-s3fifo.pdf`)、SIEVE (NSDI'24)、W-TinyLFU/Caffeine (`github.com/ben-manes/caffeine/wiki`)、ARC (FAST'03)、2Q (VLDB'94)、LIRS (SIGMETRICS'02)、SQLite (`sqlite.org/fasterthanfs.html`, `intern-v-extern-blob.html`)。

**Apple 平台:** ImageIO (`CGImageSourceCreateThumbnailAtIndex`)、`UIImage.prepareForDisplay`/`byPreparingThumbnail`、`URLSession.bytes(for:)`、Vision 显著性/人脸、MetalFX、Core ML、`AppleJPEGXL.framework`(新 SDK 出货)、WWDC18 session 219《Image and Graphics Best Practices》、libvips (`libvips.org/API/current/how-it-works.html`)。

**并发:** SE-0433 Mutex、SE-0410 Atomics、`OSAllocatedUnfairLock`。

**占位符:** BlurHash (woltapp)、ThumbHash (evanw)。

> 注:部分文献引述待"Swift 六库架构深挖"研究代理的一手数据回填;不影响本文任何架构结论。
