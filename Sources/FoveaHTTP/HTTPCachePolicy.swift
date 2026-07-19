import Foundation

package enum HTTPCachePolicy {
  package static func disposition(
    headers: [String: String],
    isPrivateNamespace: Bool,
    varySelectionAvailable: Bool = true
  ) -> CacheDisposition {
    let directives = cacheControlDirectives(in: headers)
    let vary = varyFieldNames(in: headers)
    if directives.contains(where: { $0.name == "no-store" })
      || vary == .wildcard
      || !varySelectionAvailable
    {
      return .noStore
    }
    return isPrivateNamespace ? .privateNamespace : .reusable
  }

  package static func expiration(
    requestTime: Date,
    responseTime: Date,
    headers: [String: String]
  ) -> Date? {
    let directives = cacheControlDirectives(in: headers)
    if directives.contains(where: { $0.name == "no-cache" }) {
      return responseTime
    }

    let dateValue = responseDate(in: headers)
    let ageValue: TimeInterval
    if let rawAge = header("Age", in: headers) {
      guard let parsedAge = TimeInterval(rawAge), parsedAge.isFinite, parsedAge >= 0 else {
        return responseTime
      }
      ageValue = parsedAge
    } else {
      ageValue = 0
    }
    let apparentAge = max(0, dateValue.map { responseTime.timeIntervalSince($0) } ?? 0)
    let responseDelay = max(0, responseTime.timeIntervalSince(requestTime))
    let correctedInitialAge = max(apparentAge, ageValue + responseDelay)

    let freshnessLifetime: TimeInterval?
    if let maxAge = maxAge(in: directives) {
      freshnessLifetime = maxAge
    } else if let expires = header("Expires", in: headers).flatMap(HTTPDateParser.date) {
      freshnessLifetime = max(0, expires.timeIntervalSince(dateValue ?? responseTime))
    } else {
      freshnessLifetime = nil
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
    if let numeric = TimeInterval(raw), numeric.isFinite, numeric >= 0 {
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
    let sensitive = CredentialHeaderPolicy.sensitiveHeaderNames.union(
      additionalSensitiveNames.map { $0.lowercased() }
    )
    var values: [String: HTTPVaryValue] = [:]
    for field in fields {
      if sensitive.contains(field) {
        guard let fingerprint = sensitiveFingerprints[field] else { return nil }
        values[field] = .fingerprint(fingerprint.sha256Hex)
      } else if let value = requestHeaders[field] {
        values[field] = .field(normalizedFieldValue(value, named: field))
      } else {
        values[field] = .absent
      }
    }
    return HTTPVarySelection(fieldNames: fields, values: values)
  }

  package static func varyFieldNames(in headers: [String: String]) -> VaryFieldNames {
    guard let value = header("Vary", in: headers) else { return .fields([]) }
    let fields = value.split(separator: ",", omittingEmptySubsequences: false).compactMap { raw in
      let field = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return field.isEmpty ? nil : field
    }
    if fields.contains("*") { return .wildcard }
    return .fields(Array(Set(fields)).sorted())
  }

  package static func header(_ name: String, in headers: [String: String]) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  package enum VaryFieldNames: Equatable, Sendable {
    case wildcard
    case fields([String])
  }

  private struct CacheControlDirective {
    let name: String
    let value: String?
  }

  private static func normalizedFieldValue(_ value: String, named fieldName: String) -> String {
    let commaNormalized =
      value
      .split(separator: ",", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .joined(separator: ",")
    switch fieldName {
    case "accept-encoding", "accept-language":
      return commaNormalized.lowercased()
    default:
      return commaNormalized
    }
  }

  private static func cacheControlDirectives(in headers: [String: String])
    -> [CacheControlDirective]
  {
    guard let value = header("Cache-Control", in: headers) else { return [] }
    return value.split(separator: ",").compactMap { rawDirective in
      let parts =
        rawDirective
        .trimmingCharacters(in: .whitespaces)
        .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard let name = parts.first?.lowercased(), !name.isEmpty else { return nil }
      let value =
        parts.count == 2
        ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
        : nil
      return CacheControlDirective(name: name, value: value)
    }
  }

  private static func maxAge(in directives: [CacheControlDirective]) -> TimeInterval? {
    guard let raw = directives.first(where: { $0.name == "max-age" })?.value,
      let seconds = TimeInterval(raw),
      seconds.isFinite
    else { return nil }
    return max(0, seconds)
  }
}

enum HTTPDateParser {
  static func date(from string: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    return formatter.date(from: string)
  }
}
