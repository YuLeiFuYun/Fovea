import Foundation
import FoveaHTTP

public struct StaleFallbackPolicy: Codable, Hashable, Sendable {
  public let isEnabled: Bool
  public let maximumStalenessSeconds: UInt64

  public init(
    isEnabled: Bool,
    maximumStalenessSeconds: UInt64 = 0
  ) {
    self.isEnabled = isEnabled
    self.maximumStalenessSeconds = maximumStalenessSeconds
  }

  public static let disabled = StaleFallbackPolicy(isEnabled: false)

  public static func networkResilient(
    maximumStalenessSeconds: UInt64
  ) -> StaleFallbackPolicy {
    StaleFallbackPolicy(
      isEnabled: true,
      maximumStalenessSeconds: maximumStalenessSeconds
    )
  }

  package func permits(
    record: RepresentationRecord,
    at date: Date,
    after failure: PipelineFailure
  ) -> Bool {
    guard isEnabled,
      record.disposition != .noStore,
      let expiresAt = record.expiresAt,
      date >= expiresAt,
      failure.disposition == .retryable
    else { return false }

    let permittedFailure: Bool
    switch failure.category {
    case .transport:
      permittedFailure = true
    case .http:
      if let statusCode = failure.statusCode {
        permittedFailure =
          statusCode == 408 || statusCode == 425 || statusCode == 429
          || (500...599).contains(statusCode)
      } else {
        permittedFailure = false
      }
    default:
      permittedFailure = false
    }
    guard permittedFailure else { return false }

    let staleness = date.timeIntervalSince(expiresAt)
    guard staleness.isFinite, staleness >= 0 else { return false }
    return staleness <= Double(maximumStalenessSeconds)
  }
}
