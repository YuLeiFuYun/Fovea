import Foundation

/// 请求、响应、Vary 与持久化 HTTP 元数据共享的边界和验证规则。
package enum HTTPMetadataLimits {
    package static let maximumURLBytes = 16 * 1024
    package static let maximumHeaderCount = 64
    package static let maximumHeaderBytes = 64 * 1024
    package static let maximumFieldNameBytes = 256
    package static let maximumFieldValueBytes = 16 * 1024
    package static let maximumVaryFieldCount = 32
    package static let maximumRepresentationCandidateCount = 256
    package static let maximumPersistentRecordBytes = 128 * 1024

    package static func isValidFieldName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maximumFieldNameBytes else { return false }
        let allowedPunctuation = Set("!#$%&'*+-.^_`|~".unicodeScalars.map(\.value))
        return name.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (48...57).contains(value)
                || (65...90).contains(value)
                || (97...122).contains(value)
                || allowedPunctuation.contains(value)
        }
    }

    package static func isValidFieldValue(_ value: String) -> Bool {
        guard value.utf8.count <= maximumFieldValueBytes else { return false }
        return !value.unicodeScalars.contains { scalar in
            let codePoint = scalar.value
            return (codePoint < 0x20 && codePoint != 0x09) || codePoint == 0x7F
        }
    }

    package static func normalizedHeaders(
        _ headers: [String: String]
    ) throws -> [String: String] {
        guard headers.count <= maximumHeaderCount else {
            throw TransportError.responseHeadersTooLarge
        }

        var totalBytes = 0
        var result: [String: String] = [:]
        let items = headers.map {
            (normalized: $0.key.lowercased(), original: $0.key, value: $0.value)
        }.sorted {
            if $0.normalized != $1.normalized { return $0.normalized < $1.normalized }
            if $0.original != $1.original { return $0.original < $1.original }
            return $0.value < $1.value
        }
        for item in items {
            guard isValidFieldName(item.normalized), isValidFieldValue(item.value) else {
                throw TransportError.invalidResponseHeader
            }
            guard result[item.normalized] == nil else { continue }
            let addition = item.normalized.utf8.count + item.value.utf8.count + 4
            let next = totalBytes.addingReportingOverflow(addition)
            guard !next.overflow, next.partialValue <= maximumHeaderBytes else {
                throw TransportError.responseHeadersTooLarge
            }
            totalBytes = next.partialValue
            result[item.normalized] = item.value
        }
        return result
    }

    package static func persistentByteCount(
        fieldNames: [String],
        values: [String: HTTPVaryValue]
    ) -> Int? {
        var total = 0
        for name in fieldNames {
            guard let value = values[name] else { return nil }
            let valueBytes: Int
            switch value {
            case .absent:
                valueBytes = 1
            case .field(let field), .fingerprint(let field):
                valueBytes = field.utf8.count
            }
            let next = total.addingReportingOverflow(name.utf8.count + valueBytes + 8)
            guard !next.overflow else { return nil }
            total = next.partialValue
        }
        return total
    }
}
