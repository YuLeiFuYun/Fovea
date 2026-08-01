/// 为常见失败路径提供单一构造入口，避免各阶段产生不一致的 reasonCode 或处置策略。
extension PipelineFailure {
    static func authorization(reasonCode: String) -> PipelineFailure {
        PipelineFailure(
            category: .authorization,
            stage: .requestValidation,
            disposition: .terminal,
            reasonCode: reasonCode
        )
    }

    static let profileAccessDenied = PipelineFailure(
        category: .authorization,
        stage: .requestValidation,
        disposition: .terminal,
        reasonCode: "profile-access-denied"
    )

    static let missingAuthorizationContext = PipelineFailure(
        category: .authorization,
        stage: .requestValidation,
        disposition: .terminal,
        reasonCode: "missing-authorization-context"
    )

    static let namespaceRevoked = PipelineFailure(
        category: .namespaceRevoked,
        stage: .revocation,
        disposition: .terminal,
        reasonCode: "namespace-revoked"
    )

    static let namespaceCleanupFailed = PipelineFailure(
        category: .cacheWrite,
        stage: .revocation,
        disposition: .cacheDegraded,
        reasonCode: "namespace-cleanup-failed"
    )

    package static let namespaceGenerationPersistenceFailed = PipelineFailure(
        category: .cacheWrite,
        stage: .revocation,
        disposition: .terminal,
        reasonCode: "namespace-generation-persistence-failed"
    )

    static let cacheMaintenanceUnavailable = PipelineFailure(
        category: .cacheWrite,
        stage: .persistence,
        disposition: .terminal,
        reasonCode: "cache-maintenance-unavailable"
    )

    static let onlyIfCachedMiss = PipelineFailure(
        category: .cacheRead,
        stage: .cacheLookup,
        disposition: .terminal,
        reasonCode: "only-if-cached-miss"
    )

    static let missingCachedBody = PipelineFailure(
        category: .cacheRead,
        stage: .cacheLookup,
        disposition: .terminal,
        reasonCode: "validated-record-missing-body"
    )

    static let nonImageResponse = PipelineFailure(
        category: .http,
        stage: .responseValidation,
        disposition: .terminal,
        reasonCode: "non-image-response"
    )

    static func unsupportedStatus(_ statusCode: Int) -> PipelineFailure {
        let retryable =
            statusCode == 408 || statusCode == 425 || statusCode == 429 || 500...599 ~= statusCode
        return PipelineFailure(
            category: .http,
            stage: .responseValidation,
            disposition: retryable ? .retryable : .terminal,
            reasonCode: "unsupported-http-status",
            statusCode: statusCode
        )
    }

    package static func resourceLimit(stage: Stage, reasonCode: String) -> PipelineFailure {
        PipelineFailure(
            category: .resourceLimit,
            stage: stage,
            disposition: .terminal,
            reasonCode: reasonCode
        )
    }

    static func cancelled(stage: Stage) -> PipelineFailure {
        PipelineFailure(
            category: .cancelled,
            stage: stage,
            disposition: .cancelled,
            reasonCode: "cancelled"
        )
    }

    public static let incompleteProgressiveStream = PipelineFailure(
        category: .internalFailure,
        stage: .pipeline,
        disposition: .terminal,
        reasonCode: "progressive-stream-ended-without-final"
    )

    static let transformFailed = PipelineFailure(
        category: .transform,
        stage: .transform,
        disposition: .terminal,
        reasonCode: "transform-failed"
    )

    static let invalidContentDigest = PipelineFailure(
        category: .transport,
        stage: .transport,
        disposition: .terminal,
        reasonCode: "invalid-content-digest"
    )

    package static func internalFailure(stage: Stage) -> PipelineFailure {
        PipelineFailure(
            category: .internalFailure,
            stage: stage,
            disposition: .terminal,
            reasonCode: "internal-failure"
        )
    }
}
