import Foundation

public struct PipelineID: Hashable, Sendable, Codable, CustomStringConvertible {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue.uuidString.lowercased() }
}
