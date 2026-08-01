import Foundation

/// 把面向用户的实验室入口映射到一个或多个可执行场景及其能力声明。
struct WorkbenchLab: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
    let category: WorkbenchLabCategory
    let symbol: String
    let scenarioIDs: [String]
    let presentation: WorkbenchLabPresentation
    let capabilities: [String]

    var scenarios: [WorkbenchScenario] {
        scenarioIDs.compactMap(WorkbenchScenarioCatalog.scenario(id:))
    }
}

enum WorkbenchLabCategory: String, CaseIterable, Identifiable {
    case product
    case correctness
    case lifecycle
    case resilience
    case environment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .product: "实际界面"
        case .correctness: "数据正确性"
        case .lifecycle: "滚动与并发"
        case .resilience: "异常与资源"
        case .environment: "真实网络"
        }
    }

    var symbol: String {
        switch self {
        case .product: "apps.iphone"
        case .correctness: "checkmark.shield"
        case .lifecycle: "arrow.triangle.2.circlepath"
        case .resilience: "waveform.path.ecg.rectangle"
        case .environment: "globe"
        }
    }
}

enum WorkbenchLabPresentation: String, Hashable {
    case productPatterns
    case singleImage
    case cacheIdentity
    case authentication
    case concurrency
    case feed
    case failureMatrix
    case liveNetwork
}

enum WorkbenchLabCatalog {
    static let all: [WorkbenchLab] = [
        WorkbenchLab(
            id: "product-patterns",
            title: "常见 App 图片模式",
            summary: "头像、详情 Hero、聊天缩略图、商品网格和同源多目标尺寸，验证真实布局中的裁切、复用与身份。",
            category: .product,
            symbol: "rectangle.3.group",
            scenarioIDs: ["cacheable-image", "slow-placeholder"],
            presentation: .productPatterns,
            capabilities: ["avatar", "hero", "chat", "grid", "multi-target"]
        ),
        WorkbenchLab(
            id: "single-image",
            title: "单图与几何实验室",
            summary: "在一页内切换快速、慢首字节、分块与缺失 MIME；直接观察占位、目标像素、fit/fill 和重试。",
            category: .product,
            symbol: "photo.on.rectangle.angled",
            scenarioIDs: [
                "cacheable-image",
                "slow-placeholder",
                "chunked-body",
                "missing-content-type",
                "same-origin-redirect",
            ],
            presentation: .singleImage,
            capabilities: ["responsive", "placeholder", "fit-fill", "target-pixels"]
        ),
        WorkbenchLab(
            id: "cache-identity",
            title: "缓存与身份剧本",
            summary: "用明确步骤执行冷载、复用、304、Vary 分流和不可复用响应；每步显示 Expected / Actual。",
            category: .correctness,
            symbol: "externaldrive.badge.checkmark",
            scenarioIDs: ["no-store", "etag-revalidation", "vary-language", "vary-wildcard"],
            presentation: .cacheIdentity,
            capabilities: ["no-store", "304", "vary", "origin-count"]
        ),
        WorkbenchLab(
            id: "authentication-isolation",
            title: "账户隔离与撤销",
            summary: "同一 URL 下执行有效凭证、错误凭证、私有 namespace 撤销和重新认证，突出显示跨账户像素泄漏风险。",
            category: .correctness,
            symbol: "person.2.badge.key",
            scenarioIDs: [
                "authenticated-private", "authenticated-invalid", "authenticated-account-b",
            ],
            presentation: .authentication,
            capabilities: ["acl", "credential-generation", "revoke", "account-isolation"]
        ),
        WorkbenchLab(
            id: "single-flight",
            title: "并发 Single-Flight 仪表盘",
            summary: "并发提交相同请求，直接显示 origin、fetch started/joined/completed、取消和缓存降级证据。",
            category: .lifecycle,
            symbol: "point.3.connected.trianglepath.dotted",
            scenarioIDs: ["single-flight-burst"],
            presentation: .concurrency,
            capabilities: ["join", "cancel", "burst", "evidence"]
        ),
        WorkbenchLab(
            id: "host-feed",
            title: "列表、网格与复用",
            summary: "稳定数据集、脚本化滚动、重复资产、离屏取消、内存清理和 SwiftUI / UIKit 宿主对照。",
            category: .lifecycle,
            symbol: "rectangle.stack.badge.play",
            scenarioIDs: ["scrolling-feed-lab"],
            presentation: .feed,
            capabilities: ["scroll", "reuse", "cancellation", "memory", "uikit"]
        ),
        WorkbenchLab(
            id: "failure-matrix",
            title: "失败与边界矩阵",
            summary: "404、500、错误 MIME、损坏、空响应、超限、不完整 body、cache-only miss 与 ACL 拒绝集中验证。",
            category: .resilience,
            symbol: "tablecells.badge.ellipsis",
            scenarioIDs: [
                "http-404",
                "http-500",
                "wrong-mime",
                "corrupt-image",
                "empty-image-body",
                "oversized-body",
                "incomplete-body",
                "cache-only-miss",
                "destination-denied",
            ],
            presentation: .failureMatrix,
            capabilities: ["reason-code", "stage", "disposition", "retryability"]
        ),
        WorkbenchLab(
            id: "live-network",
            title: "外部网络隔离区",
            summary: "真实 CDN、重定向、TLS、代理和自定义 HTTPS URL；结果始终标记为环境相关，不冒充确定性回归。",
            category: .environment,
            symbol: "network.badge.shield.half.filled",
            scenarioIDs: [
                "live-httpbin-png",
                "live-picsum-redirect",
                "live-github-swift-png",
                "live-gstatic-jpeg",
                "live-custom",
            ],
            presentation: .liveNetwork,
            capabilities: ["cdn", "redirect", "proxy", "tls", "environment"]
        ),
    ]

    static func labs(in category: WorkbenchLabCategory) -> [WorkbenchLab] {
        all.filter { $0.category == category }
    }

    static func lab(id: String) -> WorkbenchLab? {
        all.first { $0.id == id }
    }
}
