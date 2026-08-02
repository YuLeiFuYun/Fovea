import Foundation

struct WorkbenchFeedItem: Identifiable, Hashable {
    let id: Int
    let assetID: Int
    let delayMilliseconds: Int

    var expectedVariantTitle: String {
        WorkbenchRemoteAssetCatalog.remoteAsset(forStableIndex: assetID).title
    }

    static func makeItems(
        count: Int,
        uniqueAssetCount: Int,
        delayed: Bool
    ) -> [WorkbenchFeedItem] {
        let count = max(1, min(2_000, count))
        let uniqueAssetCount = max(
            1, min(WorkbenchRemoteAssetCatalog.remoteAssets.count, uniqueAssetCount))
        return (0..<count).map { index in
            let assetID = index % uniqueAssetCount
            return WorkbenchFeedItem(
                id: index,
                assetID: assetID,
                delayMilliseconds: delayed ? 40 + (assetID % 5) * 45 : 0
            )
        }
    }
}
