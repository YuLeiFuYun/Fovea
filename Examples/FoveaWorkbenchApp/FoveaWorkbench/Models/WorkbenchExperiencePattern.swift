import Foundation

/// 由真实移动应用任务归纳出的图片使用模式，而不是底层协议分类。
enum WorkbenchExperiencePattern: String, CaseIterable, Identifiable {
    case socialFeed
    case chat
    case commerce
    case article
    case stories
    case photoLibrary
    case searchResults
    case travel
    case profile
    case notifications
    case offlineHybrid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .socialFeed: "社交时间线"
        case .chat: "聊天与附件"
        case .commerce: "商品目录与详情"
        case .article: "新闻与长文章"
        case .stories: "Stories 与轮播"
        case .photoLibrary: "照片库与瀑布流"
        case .searchResults: "图片搜索结果"
        case .travel: "旅行与地点卡片"
        case .profile: "个人主页与作品墙"
        case .notifications: "通知与活动列表"
        case .offlineHybrid: "离线优先混合源"
        }
    }

    var summary: String {
        switch self {
        case .socialFeed: "头像、正文主图、多图帖子、快速滚动与重复资源。"
        case .chat: "小头像、左右消息、图片附件、离屏取消和回屏复用。"
        case .commerce: "高密度商品网格、详情主图、缩略图与放大检查。"
        case .article: "大幅头图、正文内嵌图、不同宽度和阅读顺序。"
        case .stories: "横向头像入口、全幅内容卡片和提前加载下一项。"
        case .photoLibrary: "大量本地/网络缩略图、不同长宽比和快速定位。"
        case .searchResults: "查询结果缩略图、相关性文本和增量加载。"
        case .travel: "目的地 Hero、城市卡片、地图附近结果的图片复用。"
        case .profile: "封面、头像、置顶内容与个人作品网格。"
        case .notifications: "头像、微型预览、同一资源在多个活动中重复出现。"
        case .offlineHybrid: "本地可用内容立即显示，网络内容随后补齐。"
        }
    }

    var symbol: String {
        switch self {
        case .socialFeed: "rectangle.stack"
        case .chat: "message"
        case .commerce: "bag"
        case .article: "newspaper"
        case .stories: "circle.dashed.inset.filled"
        case .photoLibrary: "photo.on.rectangle.angled"
        case .searchResults: "magnifyingglass"
        case .travel: "map"
        case .profile: "person.crop.rectangle.stack"
        case .notifications: "bell.badge"
        case .offlineHybrid: "icloud.and.arrow.down"
        }
    }

    var preferredCategories: Set<WorkbenchRemoteAssetCategory> {
        switch self {
        case .socialFeed: [.portraits, .nature, .architecture, .art]
        case .chat: [.portraits, .wildlife, .objects, .plants]
        case .commerce: [.plantFood, .objects, .art, .plants]
        case .article: [.nature, .architecture, .astronomy, .mobility]
        case .stories: [.portraits, .nature, .architecture, .art]
        case .photoLibrary: Set(WorkbenchRemoteAssetCategory.allCases)
        case .searchResults: Set(WorkbenchRemoteAssetCategory.allCases)
        case .travel: [.nature, .architecture, .mobility]
        case .profile: [.portraits, .art, .architecture, .plants]
        case .notifications: [.portraits, .wildlife, .objects]
        case .offlineHybrid: Set(WorkbenchRemoteAssetCategory.allCases)
        }
    }
}

enum WorkbenchStudioSourceMode: String, CaseIterable, Identifiable {
    case remote
    case bundled
    case mixed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .remote: "网络"
        case .bundled: "本地"
        case .mixed: "混合"
        }
    }
}
