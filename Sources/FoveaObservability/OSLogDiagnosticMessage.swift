import Foundation
import FoveaCore

/// 把结构化诊断事件编码成低基数、可解析且经过清洗的 OSLog 字段序列。
/// 所有自由文本都需限制字符集或长度，避免日志注入和意外记录敏感标识。
struct OSLogDiagnosticMessage: CustomStringConvertible {
    let event: DiagnosticEvent

    var description: String {
        var fields = [
            "schema=\(event.schemaVersion)",
            "kind=\(event.kind.rawValue)",
        ]
        append("trace", sanitizedDigest(event.keyDigest), to: &fields)
        append("status", event.statusCode, to: &fields)
        append("bytes", event.byteCount, to: &fields)
        append("items", event.itemCount, to: &fields)
        append("source-pixels", event.sourcePixelCount, to: &fields)
        append("output-pixels", event.outputPixelCount, to: &fields)
        append("target-width", event.targetWidth, to: &fields)
        append("target-height", event.targetHeight, to: &fields)
        append("reason", event.reason, to: &fields)
        append("attempt", event.attempt, to: &fields)
        append("retry-delay-ns", event.retryDelayNanoseconds, to: &fields)
        append("duration-ns", event.durationNanoseconds, to: &fields)
        append("transactions", event.transactionCount, to: &fields)
        if let protocols = sanitizedProtocols(event.networkProtocolNames), !protocols.isEmpty {
            fields.append("protocols=\(protocols.joined(separator: ","))")
        }
        append("reused", event.reusedConnectionCount, to: &fields)
        append("proxy", event.proxyConnectionCount, to: &fields)
        append("cellular", event.cellularTransactionCount, to: &fields)
        append("expensive", event.expensiveTransactionCount, to: &fields)
        append("constrained", event.constrainedTransactionCount, to: &fields)
        append("redirects", event.redirectCount, to: &fields)
        append("dns-ns", event.domainLookupDurationNanoseconds, to: &fields)
        append("connect-ns", event.connectionDurationNanoseconds, to: &fields)
        append("tls-ns", event.secureConnectionDurationNanoseconds, to: &fields)
        append("request-ns", event.requestDurationNanoseconds, to: &fields)
        append("ttfb-ns", event.timeToFirstByteNanoseconds, to: &fields)
        append("response-ns", event.responseDurationNanoseconds, to: &fields)
        append("requested-priority", priorityName(event.requestedPriority), to: &fields)
        append("effective-priority", priorityName(event.effectivePriority), to: &fields)
        append("failure-category", event.failureCategory?.rawValue, to: &fields)
        append("failure-stage", event.failureStage?.rawValue, to: &fields)
        append("failure-disposition", event.failureDisposition?.rawValue, to: &fields)
        return fields.joined(separator: " ")
    }

    private func append<T>(_ name: String, _ value: T?, to fields: inout [String]) {
        guard let value else { return }
        fields.append("\(name)=\(value)")
    }

    private func sanitizedDigest(_ digest: String?) -> String? {
        guard let digest else { return nil }
        let prefix = String(digest.prefix(16))
        guard prefix.count == 16,
            prefix.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            })
        else { return "invalid" }
        return prefix
    }

    private func sanitizedProtocols(_ protocols: [String]?) -> [String]? {
        guard let protocols else { return nil }
        var unique: [String] = []
        for value in protocols.prefix(8) {
            let bytes = value.utf8
            let sanitized: String
            if !bytes.isEmpty, bytes.count <= 16,
                bytes.allSatisfy({ byte in
                    (48...57).contains(byte) || (65...90).contains(byte)
                        || (97...122).contains(byte)
                        || byte == 45 || byte == 46 || byte == 47 || byte == 95
                })
            {
                sanitized = value.lowercased()
            } else {
                sanitized = "other"
            }
            if !unique.contains(sanitized) { unique.append(sanitized) }
        }
        return unique
    }

    private func priorityName(_ priority: ImageRequestPriority?) -> String? {
        switch priority {
        case .background: "background"
        case .low: "low"
        case .normal: "normal"
        case .high: "high"
        case .userInitiated: "user-initiated"
        case nil: nil
        }
    }
}
