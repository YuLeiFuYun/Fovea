import Foundation

public struct TransportRetryPolicy: Codable, Hashable, Sendable {
  public let maximumAttempts: Int
  public let baseDelayNanoseconds: UInt64
  public let maximumDelayNanoseconds: UInt64
  public let maximumTotalDelayNanoseconds: UInt64
  public let maximumAdditionalResponseBytes: Int
  public let jitterPermille: Int

  public init(
    maximumAttempts: Int = 2,
    baseDelayNanoseconds: UInt64 = 200_000_000,
    maximumDelayNanoseconds: UInt64 = 2_000_000_000,
    maximumTotalDelayNanoseconds: UInt64 = 5_000_000_000,
    maximumAdditionalResponseBytes: Int = 1 * 1024 * 1024,
    jitterPermille: Int = 200
  ) {
    self.maximumAttempts = max(1, maximumAttempts)
    self.baseDelayNanoseconds = baseDelayNanoseconds
    self.maximumDelayNanoseconds = max(baseDelayNanoseconds, maximumDelayNanoseconds)
    self.maximumTotalDelayNanoseconds = maximumTotalDelayNanoseconds
    self.maximumAdditionalResponseBytes = max(0, maximumAdditionalResponseBytes)
    self.jitterPermille = min(1_000, max(0, jitterPermille))
  }

  public static let coreV1 = TransportRetryPolicy()

  public var fingerprint: String {
    [
      "retry-v1",
      "attempts:\(maximumAttempts)",
      "base:\(baseDelayNanoseconds)",
      "max:\(maximumDelayNanoseconds)",
      "total:\(maximumTotalDelayNanoseconds)",
      "bytes:\(maximumAdditionalResponseBytes)",
      "jitter:\(jitterPermille)",
    ].joined(separator: "|")
  }

  package func delayNanoseconds(
    afterFailedAttempt failedAttempt: Int,
    retryAfterNanoseconds: UInt64?,
    jitterOffsetPermille: Int
  ) -> UInt64 {
    let exponential = exponentialDelay(failedAttempt: failedAttempt)
    let requested = retryAfterNanoseconds.map { max(exponential, $0) } ?? exponential
    let bounded = min(requested, maximumDelayNanoseconds)
    guard jitterPermille > 0, bounded > 0 else { return bounded }

    let clampedOffset = min(jitterPermille, max(-jitterPermille, jitterOffsetPermille))
    if clampedOffset >= 0 {
      let product = bounded.multipliedReportingOverflow(by: UInt64(clampedOffset))
      let addition = product.overflow ? UInt64.max : product.partialValue / 1_000
      return bounded.addingReportingOverflow(addition).overflow
        ? maximumDelayNanoseconds
        : min(maximumDelayNanoseconds, bounded + addition)
    }
    let magnitude = UInt64(-clampedOffset)
    let product = bounded.multipliedReportingOverflow(by: magnitude)
    let subtraction = product.overflow ? bounded : product.partialValue / 1_000
    return bounded > subtraction ? bounded - subtraction : 0
  }

  private func exponentialDelay(failedAttempt: Int) -> UInt64 {
    guard failedAttempt > 0, baseDelayNanoseconds > 0 else { return 0 }
    let shift = min(62, failedAttempt - 1)
    let multiplier = UInt64(1) << UInt64(shift)
    let product = baseDelayNanoseconds.multipliedReportingOverflow(by: multiplier)
    return product.overflow
      ? maximumDelayNanoseconds : min(maximumDelayNanoseconds, product.partialValue)
  }
}

package protocol RetrySleeping: Sendable {
  func sleep(nanoseconds: UInt64) async throws
}

package struct SystemRetrySleeper: RetrySleeping {
  package init() {}

  package func sleep(nanoseconds: UInt64) async throws {
    try await Task.sleep(nanoseconds: nanoseconds)
  }
}

package protocol RetryJittering: Sendable {
  func offsetPermille(maximumMagnitude: Int) async -> Int
}

package actor SystemRetryJitter: RetryJittering {
  package init() {}

  package func offsetPermille(maximumMagnitude: Int) -> Int {
    guard maximumMagnitude > 0 else { return 0 }
    return Int.random(in: -maximumMagnitude...maximumMagnitude)
  }
}
