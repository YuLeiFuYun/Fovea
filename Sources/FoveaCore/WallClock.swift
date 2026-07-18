import Foundation

public protocol WallClock: Sendable {
  func now() async -> Date
}

public struct SystemWallClock: WallClock {
  public init() {}

  public func now() -> Date {
    Date()
  }
}
