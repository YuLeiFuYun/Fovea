import Foundation

public enum HTTPCachePolicy {
  public static func disposition(headers: [String: String], isPrivateNamespace: Bool)
    -> CacheDisposition
  {
    let cacheControl = header("Cache-Control", in: headers)?.lowercased() ?? ""
    if cacheControl.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(
      "no-store")
    {
      return .noStore
    }
    return isPrivateNamespace ? .privateNamespace : .reusable
  }

  public static func expiration(responseTime: Date, headers: [String: String]) -> Date? {
    if let value = header("Cache-Control", in: headers)?.lowercased() {
      for directive in value.split(separator: ",") {
        let parts = directive.trimmingCharacters(in: .whitespaces).split(
          separator: "=", maxSplits: 1)
        if parts.count == 2, parts[0] == "max-age", let seconds = TimeInterval(parts[1]) {
          return responseTime.addingTimeInterval(max(0, seconds))
        }
      }
    }
    if let expires = header("Expires", in: headers) {
      return HTTPDateParser.date(from: expires)
    }
    return nil
  }

  public static func conditionalHeaders(for record: RepresentationRecord) -> [String: String] {
    var result: [String: String] = [:]
    if let etag = record.etag { result["If-None-Match"] = etag }
    if let lastModified = record.lastModified { result["If-Modified-Since"] = lastModified }
    return result
  }

  public static func header(_ name: String, in headers: [String: String]) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
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
