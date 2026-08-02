import Foundation

/// 稳定的结构化失败契约，供策略、诊断和界面恢复逻辑共同使用。
public struct PipelineFailure: Error, Equatable, Hashable, Codable, Sendable {
    /// 用于策略归类和遥测聚合的失败大类。
    public enum Category: String, Codable, Sendable {
        case authorization
        case transport
        case http
        case securityLimit
        case securityPolicy
        case resourceLimit
        case namespaceRevoked
        case cacheRead
        case cacheWrite
        case probe
        case decode
        case transform
        case cancelled
        case internalFailure
    }

    /// 首次确认或产生失败的管线阶段。
    public enum Stage: String, Codable, Sendable {
        case requestValidation
        case cacheLookup
        case transport
        case responseValidation
        case probe
        case decode
        case transform
        case persistence
        case revocation
        case pipeline
    }

    /// 调用方可依赖的稳定处置语义。
    public enum Disposition: String, Codable, Sendable {
        case terminal
        case retryable
        case cacheDegraded
        case cancelled
    }

    /// 失败大类。
    public let category: Category
    /// 失败阶段。
    public let stage: Stage
    /// 稳定处置语义。
    public let disposition: Disposition
    /// 有界、可机器读取且不含自由文本的原因码。
    public let reasonCode: String
    /// 失败源自 HTTP 响应时的状态码。
    public let statusCode: Int?

    /// 由经过验证的分类字段创建结构化失败。
    public init(
        category: Category,
        stage: Stage,
        disposition: Disposition,
        reasonCode: String,
        statusCode: Int? = nil
    ) {
        self.category = category
        self.stage = stage
        self.disposition = disposition
        self.reasonCode = Self.sanitizedReasonCode(reasonCode)
        self.statusCode = statusCode.flatMap { (100...599).contains($0) ? $0 : nil }
    }

    private enum CodingKeys: String, CodingKey {
        case category
        case stage
        case disposition
        case reasonCode
        case statusCode
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            category: try values.decode(Category.self, forKey: .category),
            stage: try values.decode(Stage.self, forKey: .stage),
            disposition: try values.decode(Disposition.self, forKey: .disposition),
            reasonCode: try values.decode(String.self, forKey: .reasonCode),
            statusCode: try values.decodeIfPresent(Int.self, forKey: .statusCode)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(category, forKey: .category)
        try values.encode(stage, forKey: .stage)
        try values.encode(disposition, forKey: .disposition)
        try values.encode(reasonCode, forKey: .reasonCode)
        try values.encodeIfPresent(statusCode, forKey: .statusCode)
    }

    /// 将底层错误稳定映射为公开失败契约的内部值对象。
    struct Mapping {
        let category: Category
        let stage: Stage
        let disposition: Disposition
        let reasonCode: String

        var failure: PipelineFailure {
            PipelineFailure(
                category: category,
                stage: stage,
                disposition: disposition,
                reasonCode: reasonCode
            )
        }
    }

    private static func sanitizedReasonCode(_ reasonCode: String) -> String {
        let bytes = reasonCode.utf8
        guard !bytes.isEmpty, bytes.count <= 96,
            bytes.allSatisfy({ byte in
                (48...57).contains(byte) || (97...122).contains(byte) || byte == 45
            })
        else {
            return "invalid-reason-code"
        }
        return reasonCode
    }
}
