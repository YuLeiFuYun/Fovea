import Foundation

/// 可复现的测试场景描述；身份、预期结果和呈现方式均由稳定字符串标识。
struct WorkbenchScenario: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
    let category: WorkbenchScenarioCategory
    let behavior: WorkbenchScenarioBehavior
    let expectedOutcome: WorkbenchExpectedOutcome
    let supportsVisualPreview: Bool
    let tags: [String]
    let presentation: WorkbenchScenarioPresentation

    init(
        id: String,
        title: String,
        summary: String,
        category: WorkbenchScenarioCategory,
        behavior: WorkbenchScenarioBehavior,
        expectedOutcome: WorkbenchExpectedOutcome,
        supportsVisualPreview: Bool,
        tags: [String],
        presentation: WorkbenchScenarioPresentation = .standard
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.category = category
        self.behavior = behavior
        self.expectedOutcome = expectedOutcome
        self.supportsVisualPreview = supportsVisualPreview
        self.tags = tags
        self.presentation = presentation
    }
}

enum WorkbenchScenarioCategory: String, CaseIterable, Identifiable {
    case fundamentals
    case cache
    case lifecycle
    case stress
    case transport
    case security
    case resource
    case live

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fundamentals: "基础显示"
        case .cache: "缓存与身份"
        case .lifecycle: "生命周期与并发"
        case .stress: "滚动与压力"
        case .transport: "网络与 HTTP"
        case .security: "认证与安全"
        case .resource: "资源边界"
        case .live: "外部网络实验"
        }
    }

    var symbol: String {
        switch self {
        case .fundamentals: "photo"
        case .cache: "externaldrive"
        case .lifecycle: "arrow.triangle.2.circlepath"
        case .stress: "rectangle.stack"
        case .transport: "network"
        case .security: "lock.shield"
        case .resource: "gauge"
        case .live: "globe"
        }
    }
}

enum WorkbenchScenarioBehavior: Hashable {
    case cacheable
    case noStore
    case revalidation
    case vary
    case varyWildcard
    case slow
    case chunked
    case missingContentType
    case sameOriginRedirect
    case authenticated
    case authenticatedInvalid
    case authenticatedAccountB
    case onlyIfCachedMiss
    case status(Int)
    case wrongMIME
    case corruptImage
    case emptyImage
    case oversized
    case incompleteBody
    case deniedDestination
    case livePreset(String)
    case liveCustom
}

enum WorkbenchScenarioPresentation: Hashable {
    case standard
    case feed(initialLayout: WorkbenchFeedLayout)
}

enum WorkbenchExpectedOutcome: Hashable {
    case success
    case failure(reasonCode: String)
    case environmentDependent

    var title: String {
        switch self {
        case .success: "预期成功"
        case .failure(let reasonCode): "预期失败：\(reasonCode)"
        case .environmentDependent: "取决于外部服务"
        }
    }
}

enum WorkbenchFeedLayout: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }
    var title: String { self == .list ? "列表" : "网格" }
    var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}
