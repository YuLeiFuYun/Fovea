import AkashicCore
import Foundation
import FoveaStorage

/// 持久化 Vary 字段值，或敏感值的不可逆指纹。
public enum HTTPVaryValue: Codable, Hashable, Sendable {
    /// 请求未包含选中的字段。
    case absent
    /// 归一化后的非敏感请求头值。
    case field(String)
    /// 敏感请求头值的小写 SHA-256 指纹。
    case fingerprint(String)

    package var canonicalValue: String {
        switch self {
        case .absent: "a:"
        case .field(let value): "v:\(value)"
        case .fingerprint(let value): "f:\(value)"
        }
    }
}

/// 规范 HTTP Vary 选择的验证失败。
public enum HTTPVarySelectionError: Error, Equatable, Sendable {
    /// 选择字段数超过持久化缓存配置允许的上限。
    case tooManyFields
    /// 选中字段名不是规范小写 HTTP token。
    case invalidFieldName(String)
    /// 选中字段缺少对应值，或出现未预期的值键。
    case valueSetMismatch
    /// 选中字段值格式错误、超限或包含不安全控制字符。
    case invalidFieldValue(String)
    /// 规范选择超过持久化元数据总预算。
    case metadataTooLarge
}

/// 用于标识一个 HTTP 表征的规范请求头选择。
public struct HTTPVarySelection: Codable, Hashable, Sendable {
    /// 不包含任何 Vary 字段的选择。
    public static let empty = HTTPVarySelection(canonicalFieldNames: [], values: [:])

    /// 参与表征选择、按序排列的小写字段名。
    public let fieldNames: [String]
    /// 按对应小写字段名索引的规范值。
    public let values: [String: HTTPVaryValue]

    /// 创建并验证有界、唯一的 Vary 选择表示。
    public init(fieldNames: [String], values: [String: HTTPVaryValue]) throws {
        let canonicalNames = try Self.canonicalFieldNames(fieldNames)
        let canonicalValues = try Self.canonicalValues(values)
        guard Set(canonicalValues.keys) == Set(canonicalNames) else {
            throw HTTPVarySelectionError.valueSetMismatch
        }
        guard
            let metadataBytes = HTTPMetadataLimits.persistentByteCount(
                fieldNames: canonicalNames,
                values: canonicalValues
            ), metadataBytes <= HTTPMetadataLimits.maximumHeaderBytes
        else {
            throw HTTPVarySelectionError.metadataTooLarge
        }
        self.init(canonicalFieldNames: canonicalNames, values: canonicalValues)
    }

    private static func canonicalFieldNames(_ fieldNames: [String]) throws -> [String] {
        guard fieldNames.count <= HTTPMetadataLimits.maximumVaryFieldCount else {
            throw HTTPVarySelectionError.tooManyFields
        }
        let names = Array(Set(fieldNames.map { $0.lowercased() })).sorted()
        guard names.count <= HTTPMetadataLimits.maximumVaryFieldCount else {
            throw HTTPVarySelectionError.tooManyFields
        }
        for name in names where !HTTPMetadataLimits.isValidFieldName(name) {
            throw HTTPVarySelectionError.invalidFieldName(name)
        }
        return names
    }

    private static func canonicalValues(
        _ values: [String: HTTPVaryValue]
    ) throws -> [String: HTTPVaryValue] {
        var result: [String: HTTPVaryValue] = [:]
        result.reserveCapacity(values.count)
        for (rawName, rawValue) in values {
            let name = rawName.lowercased()
            guard HTTPMetadataLimits.isValidFieldName(name) else {
                throw HTTPVarySelectionError.invalidFieldName(rawName)
            }
            guard result[name] == nil else {
                throw HTTPVarySelectionError.valueSetMismatch
            }
            result[name] = try canonicalValue(rawValue, named: name)
        }
        return result
    }

    private static func canonicalValue(
        _ value: HTTPVaryValue,
        named fieldName: String
    ) throws -> HTTPVaryValue {
        switch value {
        case .absent:
            return .absent
        case .field(let field):
            guard HTTPMetadataLimits.isValidFieldValue(field) else {
                throw HTTPVarySelectionError.invalidFieldValue(fieldName)
            }
            return .field(normalizedFieldValue(field, named: fieldName))
        case .fingerprint(let fingerprint):
            guard StoredContentIdentifier.isLowercaseSHA256(fingerprint) else {
                throw HTTPVarySelectionError.invalidFieldValue(fieldName)
            }
            return .fingerprint(fingerprint)
        }
    }

    /// 返回用于持久身份的字段值；仅对语法已知的列表字段执行逗号规范化。
    package static func normalizedFieldValue(_ value: String, named fieldName: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        switch fieldName {
        case "accept-encoding", "accept-language":
            return
                trimmed
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: ",")
                .lowercased()
        default:
            return trimmed
        }
    }

    private init(
        canonicalFieldNames: [String],
        values: [String: HTTPVaryValue]
    ) {
        self.fieldNames = canonicalFieldNames
        self.values = values
    }

    package var canonicalRequestVariants: [String: String] {
        Dictionary(
            uniqueKeysWithValues: fieldNames.compactMap { name in
                values[name].map { (name, $0.canonicalValue) }
            })
    }

    package var persistentMetadataByteCount: Int? {
        HTTPMetadataLimits.persistentByteCount(fieldNames: fieldNames, values: values)
    }

    private enum CodingKeys: String, CodingKey {
        case fieldNames
        case values
    }

    /// 只解码规范且有界的 Vary 选择。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fieldNames = try container.decode([String].self, forKey: .fieldNames)
        let values = try container.decode([String: HTTPVaryValue].self, forKey: .values)
        let canonicalNames = Array(Set(fieldNames.map { $0.lowercased() })).sorted()
        guard fieldNames == canonicalNames, Set(values.keys) == Set(fieldNames) else {
            throw DecodingError.dataCorruptedError(
                forKey: .fieldNames,
                in: container,
                debugDescription: "HTTP Vary selection is not canonical"
            )
        }
        do {
            let normalized = try HTTPVarySelection(fieldNames: fieldNames, values: values)
            guard normalized.fieldNames == fieldNames, normalized.values == values else {
                throw HTTPVarySelectionError.valueSetMismatch
            }
            self = normalized
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .fieldNames,
                in: container,
                debugDescription:
                    "HTTP Vary selection is not canonical or exceeds the metadata profile"
            )
        }
    }

    /// 编码规范字段顺序和值映射。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fieldNames, forKey: .fieldNames)
        try container.encode(values, forKey: .values)
    }
}

/// 敏感请求头值的已验证 SHA-256 指纹。
public struct HeaderVariantFingerprint: Codable, Hashable, Sendable, CustomStringConvertible {
    /// 64 字符小写 SHA-256 摘要。
    public let sha256Hex: String

    /// 从规范小写 SHA-256 摘要创建指纹。
    public init(sha256Hex: String) throws {
        guard StoredContentIdentifier.isLowercaseSHA256(sha256Hex) else {
            throw HeaderVariantFingerprintError.invalidSHA256
        }
        self.sha256Hex = sha256Hex
    }

    /// 规范摘要字符串。
    public var description: String { sha256Hex }

    private enum CodingKeys: String, CodingKey {
        case sha256Hex
    }

    /// 解码并重新验证规范摘要。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sha256Hex: container.decode(String.self, forKey: .sha256Hex))
    }

    /// 编码规范摘要。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sha256Hex, forKey: .sha256Hex)
    }
}

/// 敏感请求头指纹的验证失败。
public enum HeaderVariantFingerprintError: Error, Equatable, Sendable {
    /// 提供的值不是 64 字符小写 SHA-256 摘要。
    case invalidSHA256
}
