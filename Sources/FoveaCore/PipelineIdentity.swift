import Foundation

/// 一个管线配置及其组合上下文的确定性身份。

public struct PipelineID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }
}
