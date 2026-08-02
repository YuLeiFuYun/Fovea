import Foundation

/// 实现 HTTP 表征的缓存准入、新鲜度、再验证与 Vary 选择规则。
/// 解析含糊、字段超限或敏感值缺少指纹时一律失败关闭，不猜测服务器意图。
package enum HTTPCachePolicy {
    package static func disposition(
        headers: [String: String],
        isPrivateNamespace: Bool,
        varySelectionAvailable: Bool = true
    ) -> CacheDisposition {
        guard let directives = cacheControlDirectives(in: headers) else { return .noStore }
        let vary = varyFieldNames(in: headers)
        if case .invalid = maxAge(in: directives) { return .noStore }
        if directives.contains(where: { $0.name == "no-store" })
            || vary == .wildcard
            || vary == .unrepresentable
            || !varySelectionAvailable
        {
            return .noStore
        }
        return isPrivateNamespace ? .privateNamespace : .reusable
    }

    package static func requiresRevalidation(headers: [String: String]) -> Bool {
        guard let directives = cacheControlDirectives(in: headers) else { return true }
        return directives.contains { directive in
            directive.name == "no-cache" || directive.name == "must-revalidate"
        }
    }

    package static func expiration(
        requestTime: Date,
        responseTime: Date,
        headers: [String: String]
    ) -> Date? {
        guard let directives = cacheControlDirectives(in: headers) else { return responseTime }
        if directives.contains(where: { $0.name == "no-cache" }) {
            return responseTime
        }

        let dateValue = responseDate(in: headers)
        let ageValue: TimeInterval
        if let rawAge = header("Age", in: headers) {
            guard let parsedAge = deltaSeconds(rawAge) else { return responseTime }
            ageValue = parsedAge
        } else {
            ageValue = 0
        }
        let apparentAge = max(0, dateValue.map { responseTime.timeIntervalSince($0) } ?? 0)
        let responseDelay = max(0, responseTime.timeIntervalSince(requestTime))
        let correctedInitialAge = max(apparentAge, ageValue + responseDelay)

        let freshnessLifetime: TimeInterval?
        switch maxAge(in: directives) {
        case .value(let maxAge):
            freshnessLifetime = maxAge
        case .invalid:
            return responseTime
        case .absent:
            if let expires = header("Expires", in: headers).flatMap(HTTPDateParser.date) {
                freshnessLifetime = max(0, expires.timeIntervalSince(dateValue ?? responseTime))
            } else {
                freshnessLifetime = nil
            }
        }

        guard let freshnessLifetime else { return nil }
        let remaining = max(0, freshnessLifetime - correctedInitialAge)
        guard remaining.isFinite else { return .distantFuture }
        let representable = max(0, Date.distantFuture.timeIntervalSince(responseTime))
        return responseTime.addingTimeInterval(min(remaining, representable))
    }

    package static func retryAfterNanoseconds(
        in headers: [String: String],
        now: Date,
        maximum: UInt64
    ) -> UInt64? {
        guard
            let raw = header("Retry-After", in: headers)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }

        let seconds: TimeInterval?
        if let numeric = deltaSeconds(raw) {
            seconds = numeric
        } else if let date = HTTPDateParser.date(from: raw) {
            seconds = max(0, date.timeIntervalSince(now))
        } else {
            seconds = nil
        }
        guard let seconds else { return nil }
        let nanoseconds = seconds * 1_000_000_000
        guard nanoseconds.isFinite, nanoseconds >= 0 else { return maximum }
        return min(maximum, UInt64(min(nanoseconds, Double(UInt64.max))))
    }

    package static func responseDate(in headers: [String: String]) -> Date? {
        header("Date", in: headers).flatMap(HTTPDateParser.date)
    }

    package static func conditionalHeaders(for record: RepresentationRecord) -> [String: String] {
        var result: [String: String] = [:]
        if let etag = record.etag { result["If-None-Match"] = etag }
        if let lastModified = record.lastModified { result["If-Modified-Since"] = lastModified }
        return result
    }

    package static func selectRecord(
        from candidates: [RepresentationRecord],
        requestHeaders: [String: String],
        additionalSensitiveNames: Set<String>,
        sensitiveFingerprints: [String: HeaderVariantFingerprint]
    ) -> RepresentationRecord? {
        let matching = candidates.filter { record in
            guard record.disposition != .noStore,
                let current = varySelection(
                    fieldNames: record.vary.fieldNames,
                    requestHeaders: requestHeaders,
                    additionalSensitiveNames: additionalSensitiveNames,
                    sensitiveFingerprints: sensitiveFingerprints
                )
            else { return false }
            return current == record.vary
        }

        guard !matching.isEmpty else { return nil }
        let hasExplicitVary = matching.contains { !$0.vary.fieldNames.isEmpty }
        return
            matching
            .filter { !hasExplicitVary || !$0.vary.fieldNames.isEmpty }
            .max { lhs, rhs in lhs.recencyDate < rhs.recencyDate }
    }

    package static func varySelection(
        fieldNames: [String],
        requestHeaders: [String: String],
        additionalSensitiveNames: Set<String>,
        sensitiveFingerprints: [String: HeaderVariantFingerprint]
    ) -> HTTPVarySelection? {
        let fields = Array(Set(fieldNames.map { $0.lowercased() })).sorted()
        var values: [String: HTTPVaryValue] = [:]
        for field in fields {
            if CredentialHeaderPolicy.isSensitiveHeaderName(
                field,
                additionalSensitiveNames: additionalSensitiveNames
            ) {
                guard let fingerprint = sensitiveFingerprints[field] else { return nil }
                values[field] = .fingerprint(fingerprint.sha256Hex)
            } else if let value = requestHeaders[field] {
                values[field] = .field(HTTPVarySelection.normalizedFieldValue(value, named: field))
            } else {
                values[field] = .absent
            }
        }
        return try? HTTPVarySelection(fieldNames: fields, values: values)
    }

    package static func varyFieldNames(in headers: [String: String]) -> VaryFieldNames {
        guard let value = header("Vary", in: headers) else { return .fields([]) }
        let fields = value.split(separator: ",", omittingEmptySubsequences: false).compactMap {
            raw in
            let field = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return field.isEmpty ? nil : field
        }
        if fields.contains("*") { return .wildcard }
        let canonical = Array(Set(fields)).sorted()
        guard canonical.count <= HTTPMetadataLimits.maximumVaryFieldCount,
            canonical.allSatisfy({
                $0 == $0.lowercased() && HTTPMetadataLimits.isValidFieldName($0)
            })
        else {
            return .unrepresentable
        }
        return .fields(canonical)
    }

    package static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    package enum VaryFieldNames: Equatable, Sendable {
        case wildcard
        case unrepresentable
        case fields([String])
    }

    private struct CacheControlDirective {
        let name: String
        let value: String?
    }

    private static func cacheControlDirectives(in headers: [String: String])
        -> [CacheControlDirective]?
    {
        guard let value = header("Cache-Control", in: headers) else { return [] }
        guard let items = splitHTTPList(value) else { return nil }
        var directives: [CacheControlDirective] = []
        directives.reserveCapacity(items.count)
        for rawDirective in items {
            let parts =
                rawDirective
                .trimmingCharacters(in: .whitespaces)
                .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = parts.first else { return nil }
            let name = rawName.lowercased()
            guard HTTPMetadataLimits.isValidFieldName(name) else { return nil }
            let directiveValue: String?
            if parts.count == 2 {
                guard let normalized = normalizedDirectiveValue(String(parts[1])) else {
                    return nil
                }
                directiveValue = normalized
            } else {
                directiveValue = nil
            }
            directives.append(CacheControlDirective(name: name, value: directiveValue))
        }
        return directives
    }

    private enum MaxAgeResult {
        case absent
        case value(TimeInterval)
        case invalid
    }

    private static func maxAge(in directives: [CacheControlDirective]) -> MaxAgeResult {
        let values = directives.filter { $0.name == "max-age" }
        guard !values.isEmpty else { return .absent }
        guard values.count == 1,
            let raw = values[0].value,
            let seconds = deltaSeconds(raw)
        else { return .invalid }
        return .value(seconds)
    }

    private static func deltaSeconds(_ raw: String) -> TimeInterval? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
            value.utf8.allSatisfy({ (48...57).contains($0) }),
            let seconds = UInt64(value)
        else { return nil }
        return TimeInterval(seconds)
    }

    private static func splitHTTPList(_ value: String) -> [Substring]? {
        var result: [Substring] = []
        var start = value.startIndex
        var index = value.startIndex
        var quoted = false
        var escaped = false
        while index < value.endIndex {
            let character = value[index]
            if escaped {
                escaped = false
            } else if quoted, character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ",", !quoted {
                result.append(value[start..<index])
                start = value.index(after: index)
            }
            index = value.index(after: index)
        }
        guard !quoted, !escaped else { return nil }
        result.append(value[start..<value.endIndex])
        return result
    }

    private static func normalizedDirectiveValue(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.first == "\"" else { return trimmed.lowercased() }
        guard trimmed.count >= 2, trimmed.last == "\"" else { return nil }

        var result = ""
        var escaped = false
        for character in trimmed.dropFirst().dropLast() {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        guard !escaped else { return nil }
        return result.lowercased()
    }
}

package enum HTTPDateParser {
    private static let formats = [
        "EEE',' dd MMM yyyy HH':'mm':'ss z",
        "EEEE',' dd-MMM-yy HH':'mm':'ss z",
        "EEE MMM d HH':'mm':'ss yyyy",
    ]

    package static func date(from string: String) -> Date? {
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.isLenient = false
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
