import Foundation
import FoveaStorage

/// ``AkashicOriginalEncodedStore`` 使用的宿主侧字节硬限制与软限制。

package struct OriginalEncodedStoreLimits: Equatable, Sendable {
    private static let maximumSoftTotalBytes = 1024 * 1024 * 1024 * 1024
    private static let maximumSupportedBlobBytes = 1024 * 1024 * 1024

    /// 机会式 LRU 裁剪后的近似编码字节目标。
    public let softTotalBytes: Int
    /// 单个原始编码载荷的硬上限。
    public let maximumBlobBytes: Int

    /// 创建归一化存储限制，并将单数据块上限钳制到总预算内。
    public init(
        softTotalBytes: Int = 128 * 1024 * 1024,
        maximumBlobBytes: Int = 64 * 1024 * 1024
    ) {
        let normalizedTotal = min(
            Self.maximumSoftTotalBytes,
            max(1, softTotalBytes)
        )
        self.softTotalBytes = normalizedTotal
        self.maximumBlobBytes = min(
            Self.maximumSupportedBlobBytes,
            max(1, min(maximumBlobBytes, normalizedTotal))
        )
    }
}
