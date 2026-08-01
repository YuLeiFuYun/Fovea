import Foundation
import FoveaHTTP

/// 将传输层错误压缩为稳定、低基数的管线失败语义。
/// 映射决定重试、遥测和用户可见分类，未知错误必须失败关闭而非泄漏底层描述。
extension PipelineFailure {
    package static func transport(_ error: any Error) -> PipelineFailure {
        if let transportError = error as? TransportError {
            return transportFailure(transportError)
        }
        if let urlError = error as? URLError {
            return urlSessionFailure(urlError)
        }
        return PipelineFailure(
            category: .transport,
            stage: .transport,
            disposition: .terminal,
            reasonCode: "unclassified-transport-failure"
        )
    }

    private static func transportFailure(_ error: TransportError) -> PipelineFailure {
        let mapping: PipelineFailure.Mapping
        switch error {
        case .invalidRequestLimits:
            mapping = PipelineFailure.Mapping(
                category: .resourceLimit,
                stage: .requestValidation,
                disposition: .terminal,
                reasonCode: "invalid-transport-limits"
            )
        case .invalidCredentialHeaderMetadata:
            mapping = PipelineFailure.Mapping(
                category: .securityLimit,
                stage: .requestValidation,
                disposition: .terminal,
                reasonCode: "invalid-credential-header-metadata"
            )
        case .invalidResponseStatus:
            mapping = PipelineFailure.Mapping(
                category: .http,
                stage: .responseValidation,
                disposition: .terminal,
                reasonCode: "invalid-http-status"
            )
        case .invalidResponseURL:
            mapping = PipelineFailure.Mapping(
                category: .securityPolicy,
                stage: .responseValidation,
                disposition: .terminal,
                reasonCode: "invalid-response-url"
            )
        case .invalidResponseHeader:
            mapping = PipelineFailure.Mapping(
                category: .http,
                stage: .responseValidation,
                disposition: .terminal,
                reasonCode: "invalid-response-header"
            )
        case .responseHeadersTooLarge:
            mapping = PipelineFailure.Mapping(
                category: .securityLimit,
                stage: .responseValidation,
                disposition: .terminal,
                reasonCode: "response-header-limit-exceeded"
            )
        case .bodyTooLarge:
            mapping = PipelineFailure.Mapping(
                category: .securityLimit,
                stage: .transport,
                disposition: .terminal,
                reasonCode: "encoded-body-limit-exceeded"
            )
        case .invalidContentLength:
            mapping = PipelineFailure.Mapping(
                category: .http,
                stage: .responseValidation,
                disposition: .terminal,
                reasonCode: "invalid-content-length"
            )
        case .incompleteBody:
            mapping = PipelineFailure.Mapping(
                category: .transport,
                stage: .transport,
                disposition: .retryable,
                reasonCode: "incomplete-response-body"
            )
        case .nonHTTPResponse:
            mapping = PipelineFailure.Mapping(
                category: .http,
                stage: .transport,
                disposition: .terminal,
                reasonCode: "non-http-response"
            )
        case .insecureRedirect:
            mapping = PipelineFailure.Mapping(
                category: .securityPolicy,
                stage: .transport,
                disposition: .terminal,
                reasonCode: "insecure-redirect"
            )
        case .destinationDisallowed:
            mapping = PipelineFailure.Mapping(
                category: .securityPolicy,
                stage: .transport,
                disposition: .terminal,
                reasonCode: "destination-disallowed"
            )
        case .proxyMetricsUnavailable:
            mapping = PipelineFailure.Mapping(
                category: .securityPolicy,
                stage: .transport,
                disposition: .terminal,
                reasonCode: "proxy-metrics-unavailable"
            )
        case .proxyConnectionDisallowed:
            mapping = PipelineFailure.Mapping(
                category: .securityPolicy,
                stage: .transport,
                disposition: .terminal,
                reasonCode: "proxy-connection-disallowed"
            )
        }
        return mapping.failure
    }

    private static func urlSessionFailure(_ error: URLError) -> PipelineFailure {
        if error.code == .cancelled { return cancelled(stage: .transport) }
        let retryableCodes: Set<URLError.Code> = [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .resourceUnavailable,
            .backgroundSessionWasDisconnected,
        ]
        let isRetryable = retryableCodes.contains(error.code)
        return PipelineFailure(
            category: .transport,
            stage: .transport,
            disposition: isRetryable ? .retryable : .terminal,
            reasonCode: isRetryable ? "url-session-transport" : "url-session-terminal"
        )
    }
}
