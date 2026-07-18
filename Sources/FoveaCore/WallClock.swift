import Foundation

package protocol WallClock: Sendable {
  func now() async -> Date
}

package struct SystemWallClock: WallClock {
  package init() {}

  package func now() -> Date {
    Date()
  }
}
