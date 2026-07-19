import Foundation

struct NetworkCaseResult: Codable, Sendable {
  let urlHost: String
  let urlDigest: String
  let success: Bool
  let firstPixelWidth: Int?
  let firstPixelHeight: Int?
  let concurrentElapsedNanoseconds: UInt64
  let repeatElapsedNanoseconds: UInt64?
  let concurrentFetchStarted: Int
  let concurrentFetchJoined: Int
  let repeatFetchStarted: Int
  let repeatMemoryHit: Int
  let repeatOriginalEncodedHit: Int
  let singleFlightObserved: Bool
  let targetPixelInvariantSatisfied: Bool
  let networkMetricsObserved: Bool
  let networkTransactionCount: Int?
  let networkProtocolNames: [String]?
  let reusedConnectionCount: Int?
  let proxyConnectionCount: Int?
  let cellularTransactionCount: Int?
  let expensiveTransactionCount: Int?
  let constrainedTransactionCount: Int?
  let failureCategory: String?
  let failureReason: String?
}

struct NetworkLabReport: Codable, Sendable {
  let schemaVersion: Int
  let mode: String
  let allSucceeded: Bool
  let allInvariantsSatisfied: Bool
  let cacheWasTemporary: Bool
  let cases: [NetworkCaseResult]
  let diagnosticCounts: [String: Int]
}
