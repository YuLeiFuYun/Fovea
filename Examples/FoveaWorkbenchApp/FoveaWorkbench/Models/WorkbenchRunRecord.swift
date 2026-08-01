import Foundation
import FoveaCore

struct WorkbenchRunEvidence: Equatable {
    var originRequests = 0
    var eventCounts: [DiagnosticEventKind: Int] = [:]
    var statusCounts: [Int: Int] = [:]
    var finalReasonCode: String?
    var targetWidth: Int?
    var targetHeight: Int?

    func count(_ kind: DiagnosticEventKind) -> Int {
        eventCounts[kind, default: 0]
    }

    func count(statusCode: Int) -> Int {
        statusCounts[statusCode, default: 0]
    }

    var cacheDegraded: Bool { count(.cacheWriteFailed) > 0 }

    var summary: String {
        let origin = "origin \(originRequests)"
        let joins = "join \(count(.fetchJoined) + count(.decodeJoined))"
        let memory = "memory \(count(.renderedMemoryHit))"
        let encoded = "disk \(count(.originalEncodedHit))"
        return [origin, joins, memory, encoded].joined(separator: " · ")
    }
}

struct WorkbenchRunRecord: Identifiable {
    enum State: Equatable {
        case running
        case success
        case environmentSuccess
        case expectedFailure(String)
        case environmentFailure(String)
        case unexpectedFailure(String)
        case unexpectedSuccess(String)
        case cancelled

        var title: String {
            switch self {
            case .running: "运行中"
            case .success: "成功"
            case .environmentSuccess: "外部服务响应成功"
            case .expectedFailure(let reason): "按预期失败：\(reason)"
            case .environmentFailure(let reason): "外部服务/网络失败：\(reason)"
            case .unexpectedFailure(let reason): "非预期失败：\(reason)"
            case .unexpectedSuccess(let expectation): "非预期成功：\(expectation)"
            case .cancelled: "已取消"
            }
        }

        var isFinished: Bool { self != .running }
        var isUnexpected: Bool {
            switch self {
            case .unexpectedFailure, .unexpectedSuccess: true
            default: false
            }
        }
    }

    let id: UUID
    let scenarioID: String
    let scenarioTitle: String
    let startedAt: Date
    var finishedAt: Date?
    var requestCount: Int
    var completedCount: Int
    var state: State
    var evidence = WorkbenchRunEvidence()

    var durationMilliseconds: Int? {
        guard let finishedAt else { return nil }
        return Int(finishedAt.timeIntervalSince(startedAt) * 1_000)
    }
}
