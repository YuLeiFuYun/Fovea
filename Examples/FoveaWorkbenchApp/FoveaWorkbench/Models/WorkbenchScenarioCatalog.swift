import Foundation

/// 以稳定 ID 注册确定性协议场景和真实网络场景。
/// 场景描述用户可观察行为；底层类型名不得成为导航或证据身份。
enum WorkbenchScenarioCatalog {
    static let fallback = WorkbenchScenario(
        id: "invalid-lab-configuration",
        title: "实验室配置错误",
        summary: "场景目录缺失。该回退仅用于避免测试 App 因配置数据损坏而崩溃。",
        category: .fundamentals,
        behavior: .cacheable,
        expectedOutcome: .failure(reasonCode: "invalid-lab-configuration"),
        supportsVisualPreview: false,
        tags: ["configuration", "fail-visible"]
    )

    static let all: [WorkbenchScenario] = [
        WorkbenchScenario(
            id: "cacheable-image",
            title: "目标像素加载",
            summary: "标准 PNG、响应式目标尺寸、正确长宽比、内存与磁盘复用。",
            category: .fundamentals,
            behavior: .cacheable,
            expectedOutcome: .success,
            supportsVisualPreview: true,
            tags: ["target-pixel", "aspect-ratio", "memory", "disk"]
        ),
        WorkbenchScenario(
            id: "slow-placeholder",
            title: "慢响应与占位延迟",
            summary: "延迟首字节，用于观察 placeholder、取消、重试和身份替换。",
            category: .fundamentals,
            behavior: .slow,
            expectedOutcome: .success,
            supportsVisualPreview: true,
            tags: ["slow", "placeholder", "retry", "cancel"]
        ),
        WorkbenchScenario(
            id: "no-store",
            title: "Cache-Control: no-store",
            summary: "每次重新请求，不允许建立跨请求可复用缓存。",
            category: .cache,
            behavior: .noStore,
            expectedOutcome: .success,
            supportsVisualPreview: true,
            tags: ["no-store", "privacy"]
        ),
        WorkbenchScenario(
            id: "etag-revalidation",
            title: "ETag 与 304",
            summary: "先缓存，再通过条件请求验证 304 元数据合并。",
            category: .cache,
            behavior: .revalidation,
            expectedOutcome: .success,
            supportsVisualPreview: true,
            tags: ["etag", "304", "revalidate"]
        ),
        WorkbenchScenario(
            id: "vary-language",
            title: "Vary: Accept-Language",
            summary: "中英文请求形成不同表征，并验证候选选择。",
            category: .cache,
            behavior: .vary,
            expectedOutcome: .success,
            supportsVisualPreview: true,
            tags: ["vary", "identity"]
        ),
        WorkbenchScenario(
            id: "vary-wildcard",
            title: "Vary: * 不可复用",
            summary: "响应可以显示，但每次视图重建都必须重新访问 origin。",
            category: .cache,
            behavior: .varyWildcard,
            expectedOutcome: .success,
            supportsVisualPreview: true,
            tags: ["vary-star", "no-reuse"]
        ),
        WorkbenchScenario(
            id: "single-flight-burst",
            title: "并发 Single-Flight",
            summary: "并发提交多个完全相同的请求，观察 fetch/decode joined 与逐项完成进度。",
            category: .lifecycle,
            behavior: .slow,
            expectedOutcome: .success,
            supportsVisualPreview: true,
            tags: ["concurrency", "join", "progress"]
        ),
        WorkbenchScenario(
            id: "scrolling-feed-lab",
            title: "多 Cell 滚动实验室",
            summary: "列表/网格、快速滚动、离屏取消、重复资产复用、内存清理与请求身份重建。",
            category: .stress,
            behavior: .cacheable,
            expectedOutcome: .success,
            supportsVisualPreview: false,
            tags: ["feed", "cell-reuse", "scroll", "cancellation", "memory"],
            presentation: .feed(initialLayout: .list)
        ),
        WorkbenchScenario(
            id: "chunked-body",
            title: "分块响应",
            summary: "将同一图片拆成多个数据块，验证流式 transport 累积路径。",
            category: .transport,
            behavior: .chunked,
            expectedOutcome: .success,
            supportsVisualPreview: true,
            tags: ["chunks", "streaming"]
        ),
        WorkbenchScenario(
            id: "missing-content-type",
            title: "缺失 Content-Type",
            summary: "图片字节仍可安全探测，但必须产生 missing-content-type anomaly。",
            category: .transport,
            behavior: .missingContentType,
            expectedOutcome: .success,
            supportsVisualPreview: true,
            tags: ["anomaly", "content-type", "probe"]
        ),
        WorkbenchScenario(
            id: "same-origin-redirect",
            title: "同源重定向",
            summary: "验证 URLSession redirect、事务计数、目的地策略与最终图片显示。",
            category: .transport,
            behavior: .sameOriginRedirect,
            expectedOutcome: .success,
            supportsVisualPreview: true,
            tags: ["redirect", "metrics", "allowlist"]
        ),
        WorkbenchScenario(
            id: "http-404",
            title: "HTTP 404",
            summary: "验证结构化 HTTP 失败和不可重试处置。",
            category: .transport,
            behavior: .status(404),
            expectedOutcome: .failure(reasonCode: "unsupported-http-status"),
            supportsVisualPreview: false,
            tags: ["404", "failure"]
        ),
        WorkbenchScenario(
            id: "http-500",
            title: "HTTP 500",
            summary: "验证服务端失败、有限重试和最终 retryable 处置。",
            category: .transport,
            behavior: .status(500),
            expectedOutcome: .failure(reasonCode: "unsupported-http-status"),
            supportsVisualPreview: true,
            tags: ["500", "retry"]
        ),
        WorkbenchScenario(
            id: "authenticated-private",
            title: "私有认证图片",
            summary: "显式 namespace、authorization context、凭证代际和敏感 Header。",
            category: .security,
            behavior: .authenticated,
            expectedOutcome: .success,
            supportsVisualPreview: true,
            tags: ["authorization", "namespace", "credential-generation"]
        ),
        WorkbenchScenario(
            id: "authenticated-invalid",
            title: "错误凭证",
            summary: "同一私有资源使用错误 token，必须返回结构化 401 失败且不得复用账户 A 的像素。",
            category: .security,
            behavior: .authenticatedInvalid,
            expectedOutcome: .failure(reasonCode: "unsupported-http-status"),
            supportsVisualPreview: true,
            tags: ["authorization", "401", "no-cross-account-reuse"]
        ),
        WorkbenchScenario(
            id: "authenticated-account-b",
            title: "账户 B 私有图片",
            summary: "同一 URL 使用独立 namespace、authorization context 与凭证，必须得到账户 B 的独立表征。",
            category: .security,
            behavior: .authenticatedAccountB,
            expectedOutcome: .success,
            supportsVisualPreview: true,
            tags: ["account-b", "namespace", "isolation"]
        ),
        WorkbenchScenario(
            id: "destination-denied",
            title: "目的地 ACL 拒绝",
            summary: "在缓存与网络之前拒绝未进入 allowlist 的 HTTPS origin。",
            category: .security,
            behavior: .deniedDestination,
            expectedOutcome: .failure(reasonCode: "profile-access-denied"),
            supportsVisualPreview: false,
            tags: ["acl", "origin", "fail-closed"]
        ),
        WorkbenchScenario(
            id: "wrong-mime",
            title: "错误 MIME",
            summary: "HTML body 冒充图片，必须在响应验证阶段拒绝。",
            category: .security,
            behavior: .wrongMIME,
            expectedOutcome: .failure(reasonCode: "non-image-response"),
            supportsVisualPreview: false,
            tags: ["mime", "content-type"]
        ),
        WorkbenchScenario(
            id: "corrupt-image",
            title: "损坏图片字节",
            summary: "声明为 image/png 的损坏内容必须在 probe 阶段失败，且不可进入可复用缓存。",
            category: .security,
            behavior: .corruptImage,
            expectedOutcome: .failure(reasonCode: "unsupported-image-format"),
            supportsVisualPreview: false,
            tags: ["corrupt", "probe", "fail-closed"]
        ),
        WorkbenchScenario(
            id: "cache-only-miss",
            title: "仅缓存未命中",
            summary: "不允许发网，稳定返回 only-if-cached-miss。",
            category: .resource,
            behavior: .onlyIfCachedMiss,
            expectedOutcome: .failure(reasonCode: "only-if-cached-miss"),
            supportsVisualPreview: false,
            tags: ["offline", "cache-only"]
        ),
        WorkbenchScenario(
            id: "oversized-body",
            title: "响应体超限",
            summary: "超过 transport hard limit，必须在解码前终止。",
            category: .resource,
            behavior: .oversized,
            expectedOutcome: .failure(reasonCode: "encoded-body-limit-exceeded"),
            supportsVisualPreview: false,
            tags: ["bytes", "limit", "dos"]
        ),
        WorkbenchScenario(
            id: "incomplete-body",
            title: "响应体不完整",
            summary: "Content-Length 大于实际数据，验证完整性检查与重试。",
            category: .resource,
            behavior: .incompleteBody,
            expectedOutcome: .failure(reasonCode: "incomplete-response-body"),
            supportsVisualPreview: false,
            tags: ["content-length", "integrity"]
        ),
        WorkbenchScenario(
            id: "empty-image-body",
            title: "空图片响应体",
            summary: "200 image/png 但 body 为空，必须在 probe 阶段失败。",
            category: .resource,
            behavior: .emptyImage,
            expectedOutcome: .failure(reasonCode: "unsupported-image-format"),
            supportsVisualPreview: false,
            tags: ["empty", "probe", "boundary"]
        ),
        WorkbenchScenario(
            id: "live-httpbin-png",
            title: "HTTPBin PNG 服务探针",
            summary: "第三方服务健康与网络路径实验；HTTPBin 可能限流或返回 5xx，不作为确定性正确性基线。",
            category: .live,
            behavior: .livePreset("https://httpbin.org/image/png"),
            expectedOutcome: .environmentDependent,
            supportsVisualPreview: true,
            tags: ["external", "png", "service-health"]
        ),
        WorkbenchScenario(
            id: "live-picsum-redirect",
            title: "Picsum 重定向 JPEG",
            summary: "真实跨 origin 重定向与 CDN 响应；结果受第三方服务可用性影响。",
            category: .live,
            behavior: .livePreset("https://picsum.photos/seed/fovea-workbench/800/600"),
            expectedOutcome: .environmentDependent,
            supportsVisualPreview: true,
            tags: ["external", "redirect", "jpeg"]
        ),
        WorkbenchScenario(
            id: "live-github-swift-png",
            title: "GitHub Raw PNG",
            summary: "真实 GitHub CDN 静态资源、连接复用和响应缓存语义。",
            category: .live,
            behavior: .livePreset(
                "https://raw.githubusercontent.com/github/explore/main/topics/swift/swift.png"
            ),
            expectedOutcome: .environmentDependent,
            supportsVisualPreview: true,
            tags: ["external", "cdn", "png"]
        ),
        WorkbenchScenario(
            id: "live-gstatic-jpeg",
            title: "Google Static JPEG",
            summary: "独立公网 origin 的基线 JPEG，用于避免单一服务商偏差。",
            category: .live,
            behavior: .livePreset("https://www.gstatic.com/webp/gallery/1.jpg"),
            expectedOutcome: .environmentDependent,
            supportsVisualPreview: true,
            tags: ["external", "multi-origin", "jpeg"]
        ),
        WorkbenchScenario(
            id: "live-custom",
            title: "自定义 HTTPS URL",
            summary: "直接使用设置页提供的 HTTPS 图片地址；状态码、MIME 与服务可用性由目标站点决定。",
            category: .live,
            behavior: .liveCustom,
            expectedOutcome: .environmentDependent,
            supportsVisualPreview: true,
            tags: ["external", "custom", "untrusted-input"]
        ),
    ]

    static var livePresetURLs: [URL] {
        all.compactMap { scenario in
            guard case .livePreset(let rawURL) = scenario.behavior else { return nil }
            return URL(string: rawURL)
        }
    }

    static let additionalLiveRedirectOrigins: [URL] = [
        "https://fastly.picsum.photos"
    ].compactMap(URL.init(string:))

    static func scenarios(in category: WorkbenchScenarioCategory) -> [WorkbenchScenario] {
        all.filter { $0.category == category }
    }

    static func scenario(id: String) -> WorkbenchScenario? {
        all.first { $0.id == id }
    }
}
