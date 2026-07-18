import Foundation

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
