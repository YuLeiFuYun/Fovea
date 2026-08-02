import Foundation
import FoveaHTTP

struct TimedTransportResponse: Sendable {
    let requestTime: Date
    let responseTime: Date
    let transport: TransportResponse

    var head: TransportResponseHead { transport.head }
}

/// 将图片请求和可选缓存记录转换为一次明确的 HTTP 执行输入。
enum FetchRequestPreparation {
    static func authorizedRequest(
        for request: ImageRequest,
        conditionalRecord: RepresentationRecord?
    ) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "GET"
        urlRequest.allowsCellularAccess = request.networkPolicy.allowsCellularAccess
        urlRequest.allowsConstrainedNetworkAccess =
            request.networkPolicy.allowsConstrainedNetworkAccess
        urlRequest.allowsExpensiveNetworkAccess = request.networkPolicy.allowsExpensiveNetworkAccess
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if let conditionalRecord {
            for (name, value) in HTTPCachePolicy.conditionalHeaders(for: conditionalRecord) {
                urlRequest.setValue(value, forHTTPHeaderField: name)
            }
        }
        return urlRequest
    }

    static func revalidationFingerprint(for record: RepresentationRecord?) -> String {
        guard let record else { return "unconditional" }
        let etag = record.etag ?? ""
        let lastModified = record.lastModified ?? ""
        return Data("etag:\(etag)\u{0}last-modified:\(lastModified)".utf8).sha256Hex
    }
}

extension ImageRequestPriority {
    var transportPriority: TransportPriority {
        switch self {
        case .background: .background
        case .low: .low
        case .normal: .normal
        case .high: .high
        case .userInitiated: .userInitiated
        }
    }
}

/// 将共享订阅的底层错误裁决为调用方可观察的稳定失败。
/// Namespace 撤销优先于普通取消；其余情况下，调用任务已经取消时不得把
/// 同时到达的 URLSession/HTTP 终态误报为业务失败。
package enum FetchSubscriptionFailureNormalizer {
    package static func normalize(
        _ error: any Error,
        namespaceIsActive: Bool,
        callerIsCancelled: Bool
    ) -> any Error {
        guard namespaceIsActive else { return PipelineFailure.namespaceRevoked }
        if callerIsCancelled || error is CancellationError {
            return PipelineFailure.cancelled(stage: .transport)
        }
        if let failure = error as? PipelineFailure, failure.disposition == .cancelled {
            return PipelineFailure.cancelled(stage: .transport)
        }
        return error
    }
}
