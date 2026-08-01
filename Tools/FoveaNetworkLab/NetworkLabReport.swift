import Foundation

struct NetworkCaseResult: Codable, Sendable {
    let caseID: String
    let originLabel: String
    let expectedFailureReason: String?
    let expectationSatisfied: Bool
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
    let networkTimingObserved: Bool
    let networkTaskDurationNanoseconds: UInt64?
    let responseAnomalyObserved: Bool
    let networkTransactionCount: Int?
    let networkProtocolNames: [String]?
    let reusedConnectionCount: Int?
    let proxyConnectionCount: Int?
    let cellularTransactionCount: Int?
    let expensiveTransactionCount: Int?
    let constrainedTransactionCount: Int?
    let redirectCount: Int?
    let domainLookupDurationNanoseconds: UInt64?
    let connectionDurationNanoseconds: UInt64?
    let secureConnectionDurationNanoseconds: UInt64?
    let requestDurationNanoseconds: UInt64?
    let timeToFirstByteNanoseconds: UInt64?
    let responseDurationNanoseconds: UInt64?
    let failureCategory: String?
    let failureReason: String?
}

struct NetworkLabReport: Codable, Sendable {
    let schemaVersion: Int
    let mode: String
    let allSucceeded: Bool
    let allExpectationsSatisfied: Bool
    let allInvariantsSatisfied: Bool
    let cacheWasTemporary: Bool
    let cases: [NetworkCaseResult]
    let diagnosticCounts: [String: Int]
}
