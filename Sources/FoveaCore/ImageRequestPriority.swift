import Foundation

/// 贯穿获取、解码与传输工作的可比较调度优先级。

public enum ImageRequestPriority: Int, CaseIterable, Codable, Hashable, Sendable, Comparable {
    case background = 0
    case low = 1
    case normal = 2
    case high = 3
    case userInitiated = 4

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
