import Foundation

package enum HTTPCachePolicy {
  package static func disposition(headers: [String: String], isPrivateNamespace: Bool)
    -> CacheDisposition
  {
    let directives = cacheControlDirectives(in: headers)
    let vary =
      header("Vary", in: headers)?
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
      ?? []
    if directives.contains(where: { $0.name == "no-store" }) || vary.contains("*") {
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

    let dateValue = header("Date", in: headers).flatMap(HTTPDateParser.date)
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

  package static func conditionalHeaders(for record: RepresentationRecord) -> [String: String] {
    var result: [String: String] = [:]
    if let etag = record.etag { result["If-None-Match"] = etag }
    if let lastModified = record.lastModified { result["If-Modified-Since"] = lastModified }
    return result
  }

  package static func header(_ name: String, in headers: [String: String]) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  private struct CacheControlDirective {
    let name: String
    let value: String?
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
