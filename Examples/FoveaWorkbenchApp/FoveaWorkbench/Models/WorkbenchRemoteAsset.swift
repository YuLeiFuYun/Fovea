import CoreGraphics
import Foundation
import ImageCraftCore

/// Workbench 使用的真实媒体素材。
/// 名称保留 RemoteAsset 以避免无意义迁移，但实例既可来自 HTTPS，也可来自 App Bundle。
struct WorkbenchRemoteAsset: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let category: WorkbenchRemoteAssetCategory
    let sourceKind: WorkbenchMediaSourceKind
    let fileName: String
    let bundledResourceName: String?
    let author: String
    let license: String
    private let licenseURLString: String
    private let sourcePageURLString: String
    let originalPixelWidth: Int
    let originalPixelHeight: Int
    let mimeType: String
    let ethicalReview: String
    let searchTerms: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case subtitle
        case category
        case sourceKind
        case fileName
        case bundledResourceName
        case author
        case license
        case licenseURLString = "licenseURL"
        case sourcePageURLString = "sourcePageURL"
        case originalPixelWidth
        case originalPixelHeight
        case mimeType
        case ethicalReview
        case searchTerms
    }

    var aspectRatio: CGFloat {
        CGFloat(originalPixelWidth) / CGFloat(originalPixelHeight)
    }

    var sourceTitle: String {
        sourceKind == .bundled ? "本地真实图片" : "网络真实图片"
    }

    var sourcePageURL: URL {
        URL(string: sourcePageURLString) ?? WorkbenchRemoteAssetCatalog.commonsRoot
    }

    var licenseURL: URL {
        URL(string: licenseURLString) ?? sourcePageURL
    }

    func remoteImageURL(width: Int) -> URL? {
        guard sourceKind == .remote else { return nil }
        return WorkbenchRemoteAssetCatalog.fileURL(fileName: fileName, width: width)
    }

    var bundledURL: URL? {
        guard sourceKind == .bundled, let bundledResourceName else { return nil }
        return Bundle.main.url(
            forResource: bundledResourceName,
            withExtension: nil,
            subdirectory: "LocalMedia"
        ) ?? Bundle.main.url(forResource: bundledResourceName, withExtension: nil)
    }

    func matches(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return ([title, subtitle, author, category.title, sourceTitle] + searchTerms)
            .contains { $0.lowercased().contains(normalized) }
    }
}

enum WorkbenchDeterministicFixture: String, CaseIterable {
    case mistyMountains
    case flamingStarNebula

    var resourceName: String {
        switch self {
        case .mistyMountains:
            "local-000-a-view-of-the-taunus-mountain-range-during-fog-3-png-0cbecba781.png"
        case .flamingStarNebula:
            "local-015-flaming-star-nebula-ic-405-png-11c3c5b390.png"
        }
    }

    var catalogAssetID: String {
        switch self {
        case .mistyMountains:
            "local-a-view-of-the-taunus-mountain-range-during-fog-3-png-0cbecba781"
        case .flamingStarNebula:
            "local-flaming-star-nebula-ic-405-png-11c3c5b390"
        }
    }

    var cacheIdentity: String {
        switch self {
        case .mistyMountains: "misty-mountains-v1"
        case .flamingStarNebula: "flaming-star-nebula-v1"
        }
    }

    var bundledURL: URL? {
        Bundle.main.url(
            forResource: resourceName,
            withExtension: nil,
            subdirectory: "LocalMedia"
        ) ?? Bundle.main.url(forResource: resourceName, withExtension: nil)
    }
}

enum WorkbenchMediaSourceKind: String, Codable, CaseIterable, Identifiable {
    case remote
    case bundled

    var id: String { rawValue }
    var title: String { self == .remote ? "网络" : "本地" }
    var symbol: String { self == .remote ? "network" : "shippingbox" }
}

enum WorkbenchRemoteAssetCategory: String, Codable, CaseIterable, Identifiable {
    case nature
    case plants
    case architecture
    case wildlife
    case plantFood
    case art
    case astronomy
    case mobility
    case objects
    case portraits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nature: "自然风景"
        case .plants: "植物与花卉"
        case .architecture: "城市与建筑"
        case .wildlife: "友善动物影像"
        case .plantFood: "植物性食物"
        case .art: "艺术与设计"
        case .astronomy: "天文与夜空"
        case .mobility: "交通与出行"
        case .objects: "物品与细节"
        case .portraits: "公有领域肖像"
        }
    }

    var symbol: String {
        switch self {
        case .nature: "mountain.2"
        case .plants: "leaf"
        case .architecture: "building.2"
        case .wildlife: "pawprint"
        case .plantFood: "carrot"
        case .art: "paintpalette"
        case .astronomy: "sparkles"
        case .mobility: "tram"
        case .objects: "camera.macro"
        case .portraits: "person.crop.rectangle"
        }
    }
}

enum WorkbenchRemoteAssetCatalog {
    static let commonsRoot = requiredHTTPSURL("https://commons.wikimedia.org")

    static let all: [WorkbenchRemoteAsset] = {
        guard
            let url = Bundle.main.url(
                forResource: "workbench-media-catalog", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let catalog = try? JSONDecoder().decode(WorkbenchMediaCatalogDocument.self, from: data),
            catalog.schemaVersion == 1,
            catalog.assets.count >= 300
        else {
            preconditionFailure("Workbench 真实媒体清单缺失、损坏或数量不足")
        }
        return catalog.assets
    }()

    static var remoteAssets: [WorkbenchRemoteAsset] {
        all.filter { $0.sourceKind == .remote }
    }

    static var bundledAssets: [WorkbenchRemoteAsset] {
        all.filter { $0.sourceKind == .bundled }
    }

    static var featured: WorkbenchRemoteAsset {
        remoteAssets.first(where: { $0.category == .nature }) ?? all[0]
    }

    static var allowedOriginURLs: [URL] {
        [
            commonsRoot,
            requiredHTTPSURL("https://upload.wikimedia.org"),
        ]
    }

    static func asset(id: String) -> WorkbenchRemoteAsset? {
        all.first { $0.id == id }
    }

    static func assets(
        category: WorkbenchRemoteAssetCategory?,
        sourceKind: WorkbenchMediaSourceKind?,
        query: String
    ) -> [WorkbenchRemoteAsset] {
        all.filter { asset in
            (category == nil || asset.category == category)
                && (sourceKind == nil || asset.sourceKind == sourceKind)
                && asset.matches(query)
        }
    }

    static func asset(forStableIndex index: Int) -> WorkbenchRemoteAsset {
        let normalized = index % all.count
        return all[normalized >= 0 ? normalized : normalized + all.count]
    }

    static func remoteAsset(forStableIndex index: Int) -> WorkbenchRemoteAsset {
        let normalized = index % remoteAssets.count
        return remoteAssets[normalized >= 0 ? normalized : normalized + remoteAssets.count]
    }

    static func requestWidth(for target: TargetPixels) -> Int {
        let desired = max(target.width, target.height)
        return [320, 480, 640, 960, 1_280, 1_600, 2_048].first(where: { $0 >= desired }) ?? 2_048
    }

    private static func requiredHTTPSURL(_ value: String) -> URL {
        guard let url = URL(string: value), url.scheme == "https", url.host != nil else {
            preconditionFailure("Workbench 内置 HTTPS origin 无法构造")
        }
        return url
    }

    static func fileURL(fileName: String, width: Int) -> URL? {
        let path =
            commonsRoot
            .appendingPathComponent("wiki/Special:Redirect/file", isDirectory: true)
            .appendingPathComponent(fileName)
        guard var components = URLComponents(url: path, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "width", value: String(max(64, width)))]
        return components.url
    }
}

private struct WorkbenchMediaCatalogDocument: Decodable {
    let schemaVersion: Int
    let assets: [WorkbenchRemoteAsset]
}
