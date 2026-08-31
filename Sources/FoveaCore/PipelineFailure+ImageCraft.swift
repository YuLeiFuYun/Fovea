import ImageCraftCore

/// 将 ImageCraft 解码与变换错误映射到 Fovea 的稳定失败代数，保留取消与资源上限的区别。
// 该边界只做分类与稳定 reason code 映射，不在此处重试、降级或吞掉未知错误。
extension PipelineFailure {
    package static func imageCraft(_ error: any Error, stage: Stage) -> PipelineFailure {
        if let geometryError = error as? TargetGeometryError {
            return targetGeometryFailure(geometryError)
        }
        if let contractError = error as? ImageCodecContractError {
            return imageCodecContractFailure(contractError, stage: stage)
        }
        guard let imageError = error as? ImageCraftError else {
            return unknownImageCraftFailure(stage: stage)
        }
        return imageCraftFailure(imageError, stage: stage)
    }

    private static func targetGeometryFailure(_ error: TargetGeometryError) -> PipelineFailure {
        switch error {
        case .invalidTarget:
            return securityFailure(
                stage: .requestValidation,
                reasonCode: "invalid-target-pixels"
            )
        case .limitExceeded:
            return securityFailure(
                stage: .requestValidation,
                reasonCode: "target-limit-exceeded"
            )
        }
    }

    private static func unknownImageCraftFailure(stage: Stage) -> PipelineFailure {
        PipelineFailure(
            category: stage == .probe ? .probe : .decode,
            stage: stage,
            disposition: .terminal,
            reasonCode: stage == .probe ? "probe-failure" : "decode-failure"
        )
    }

    private static func imageCodecContractFailure(
        _ error: ImageCodecContractError,
        stage: Stage
    ) -> PipelineFailure {
        switch error {
        case .unsupportedCapability:
            return Mapping(
                category: .decode,
                stage: stage,
                disposition: .terminal,
                reasonCode: "unsupported-codec-capability"
            ).failure
        case .invalidResourceEstimate:
            return internalContractFailure(
                stage: stage,
                reasonCode: "invalid-codec-resource-estimate"
            )
        }
    }

    private static func internalContractFailure(
        stage: Stage,
        reasonCode: String
    ) -> PipelineFailure {
        Mapping(
            category: .internalFailure,
            stage: stage,
            disposition: .terminal,
            reasonCode: reasonCode
        ).failure
    }

    private static func imageCraftFailure(
        _ error: ImageCraftError,
        stage: Stage
    ) -> PipelineFailure {
        if error == .invalidTarget {
            return requestLimitFailure(error)
        }
        if isDecodeLimitFailure(error) {
            return decodeLimitFailure(error, stage: stage)
        }
        if isProbeLimitFailure(error) {
            return probeLimitFailure(error)
        }
        if isExecutionFailure(error) {
            return executionFailure(error)
        }
        if error == .progressiveDecodingUnsupported {
            return Mapping(
                category: .decode,
                stage: stage,
                disposition: .terminal,
                reasonCode: "progressive-decoding-unsupported"
            ).failure
        }
        if error == .progressiveSessionFinished {
            return internalContractFailure(
                stage: stage,
                reasonCode: "progressive-session-finished"
            )
        }
        if error == .progressiveSessionCancelled {
            return cancelled(stage: stage)
        }
        // ImageCraft is an independently versioned exact-pin dependency. New public error cases
        // must fail closed without making a candidate pin source-incompatible with Fovea. Equality
        // classification avoids both an old-pin unreachable-default diagnostic and a newer-pin
        // non-exhaustive-switch diagnostic under warnings-as-errors.
        return unexpectedImageCraftFailure(error, stage: stage)
    }

    private static func isDecodeLimitFailure(_ error: ImageCraftError) -> Bool {
        error == .encodedBytesExceeded
            || error == .dimensionLimitExceeded
            || error == .pixelLimitExceeded
            || error == .frameLimitExceeded
    }

    private static func isProbeLimitFailure(_ error: ImageCraftError) -> Bool {
        error == .unsupportedFormat
            || error == .formatMismatch
            || error == .metadataLimitExceeded
            || error == .auxiliaryAttachmentLimitExceeded
    }

    private static func isExecutionFailure(_ error: ImageCraftError) -> Bool {
        error == .unsupportedOrCorruptImage
            || error == .probeMismatch
            || error == .decodeFailed
    }

    private static func requestLimitFailure(_ error: ImageCraftError) -> PipelineFailure {
        switch error {
        case .invalidTarget:
            return securityFailure(
                stage: .requestValidation,
                reasonCode: "invalid-target-pixels"
            )
        default:
            return unexpectedImageCraftFailure(error, stage: .requestValidation)
        }
    }

    private static func decodeLimitFailure(
        _ error: ImageCraftError,
        stage: Stage
    ) -> PipelineFailure {
        switch error {
        case .encodedBytesExceeded:
            return securityFailure(stage: stage, reasonCode: "encoded-bytes-limit-exceeded")
        case .dimensionLimitExceeded:
            return securityFailure(stage: stage, reasonCode: "dimension-limit-exceeded")
        case .pixelLimitExceeded:
            return securityFailure(stage: stage, reasonCode: "pixel-limit-exceeded")
        case .frameLimitExceeded:
            return securityFailure(stage: stage, reasonCode: "frame-limit-exceeded")
        default:
            return unexpectedImageCraftFailure(error, stage: stage)
        }
    }

    private static func probeLimitFailure(_ error: ImageCraftError) -> PipelineFailure {
        switch error {
        case .unsupportedFormat:
            return securityFailure(stage: .probe, reasonCode: "unsupported-image-format")
        case .formatMismatch:
            return securityFailure(stage: .probe, reasonCode: "container-format-mismatch")
        case .metadataLimitExceeded:
            return securityFailure(stage: .probe, reasonCode: "metadata-limit-exceeded")
        case .auxiliaryAttachmentLimitExceeded:
            return securityFailure(
                stage: .probe,
                reasonCode: "auxiliary-attachment-limit-exceeded"
            )
        default:
            return unexpectedImageCraftFailure(error, stage: .probe)
        }
    }

    private static func executionFailure(_ error: ImageCraftError) -> PipelineFailure {
        switch error {
        case .unsupportedOrCorruptImage:
            return Mapping(
                category: .probe,
                stage: .probe,
                disposition: .terminal,
                reasonCode: "unsupported-or-corrupt-image"
            ).failure
        case .probeMismatch:
            return Mapping(
                category: .probe,
                stage: .probe,
                disposition: .terminal,
                reasonCode: "probe-does-not-match-bitstream"
            ).failure
        case .decodeFailed:
            return Mapping(
                category: .decode,
                stage: .decode,
                disposition: .terminal,
                reasonCode: "decode-failed"
            ).failure
        default:
            return unexpectedImageCraftFailure(error, stage: .decode)
        }
    }

    private static func unexpectedImageCraftFailure(
        _ error: ImageCraftError,
        stage: Stage
    ) -> PipelineFailure {
        Mapping(
            category: .internalFailure,
            stage: stage,
            disposition: .terminal,
            reasonCode: "unexpected-imagecraft-error-\(String(describing: error))"
        ).failure
    }

    private static func securityFailure(
        stage: Stage,
        reasonCode: String
    ) -> PipelineFailure {
        Mapping(
            category: .securityLimit,
            stage: stage,
            disposition: .terminal,
            reasonCode: reasonCode
        ).failure
    }
}
