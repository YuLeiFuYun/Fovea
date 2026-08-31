import Foundation
import ImageCraftCore

/// Fovea 在调用 codec 前拥有的能力、请求和 complete-frame 资源准入代数。
package enum FoveaCodecAdmission {
    package static func capabilityRequest(
        for probe: ImageProbe
    ) -> ImageDecodeCapabilityRequest {
        ImageDecodeCapabilityRequest(
            format: probe.format,
            deliveryMode: .completeFrame,
            trackMode: .primaryFrame,
            requiredMetadata: [.orientation, .sourceColorProfile],
            dynamicRange: .standard,
            outputRepresentation: .coreGraphicsImage,
            cancellationMode: .operationBoundary
        )
    }

    package static func decodeRequest(for request: ImageRequest) -> ImageDecodeRequest {
        ImageDecodeRequest(
            target: request.target,
            contentMode: request.contentMode,
            colorPolicy: request.colorPolicy
        )
    }

    package static func workingSetBytes(
        codec: any ImageCodec,
        executor: DispatchWorkExecutor,
        probe: ImageProbe,
        request: ImageDecodeRequest
    ) async throws -> Int {
        let genericBytes = FoveaDecodeWorkingSetEstimator.estimatedBytes(
            probe: probe,
            request: request
        )
        let backendEstimate = try await executor.run {
            try codec.resourceEstimate(probe: probe, request: request)
        }
        return try ImageDecodeResourceEstimate.conservativeMaximum(
            genericBytes: genericBytes,
            backendBytes: backendEstimate.workingSetBytes
        ).workingSetBytes
    }

    package static func pixelCount(width: Int, height: Int) -> Int {
        let (result, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? Int.max : result
    }
}

/// Fovea 对第三方 codec 最终像素执行的宿主侧后验契约验证。
///
/// probe、descriptor 与 resource estimate 都是后端声明；真正返回的 CGImage 仍必须落在
/// host 已准入的 target、DecodeLimits 与 working-set 边界内。失败表示 codec contract 违规，
/// 不能把超界像素继续发布到缓存或 UI。
package enum FoveaCodecOutputContract {
    package static func validate(
        _ image: DecodedImage,
        probe: ImageProbe,
        request: ImageDecodeRequest,
        limits: DecodeLimits,
        admittedWorkingSetBytes: Int
    ) throws {
        try validateGeometry(image, request: request, limits: limits)
        guard image.estimatedByteCost <= admittedWorkingSetBytes else {
            throw failure("codec-output-exceeds-admitted-working-set")
        }
        guard image.colorDescription.sourceProfile == probe.sourceColorProfile else {
            throw failure("codec-output-source-profile-mismatch")
        }
    }

    package static func validateProgressive(
        _ image: DecodedImage,
        request: ImageDecodeRequest,
        limits: DecodeLimits,
        maximumResidentBytes: Int
    ) throws {
        try validateGeometry(image, request: request, limits: limits)
        guard image.estimatedByteCost <= maximumResidentBytes else {
            throw failure("codec-progressive-output-exceeds-working-set-limit")
        }
    }

    private static func validateGeometry(
        _ image: DecodedImage,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws {
        guard image.pixelWidth <= limits.maximumDimension,
            image.pixelHeight <= limits.maximumDimension
        else {
            throw failure("codec-output-exceeds-decode-limits")
        }
        let pixels = image.pixelWidth.multipliedReportingOverflow(by: image.pixelHeight)
        guard !pixels.overflow, pixels.partialValue <= limits.maximumPixelCount else {
            throw failure("codec-output-exceeds-decode-limits")
        }
        guard image.pixelWidth <= request.target.width,
            image.pixelHeight <= request.target.height
        else {
            throw failure("codec-output-exceeds-target")
        }
    }

    private static func failure(_ reasonCode: String) -> PipelineFailure {
        PipelineFailure(
            category: .internalFailure,
            stage: .decode,
            disposition: .terminal,
            reasonCode: reasonCode
        )
    }
}

/// 将 codec progressive session 的同步调用隔离到既有 decode executor，
/// 并在任何 preview 离开 codec 边界前执行 Fovea 的后验像素合同。
package enum ProgressiveDecodeStage {
    package static func makeSession(
        codec: any ImageCodec,
        descriptor: ImageCodecDescriptor,
        limits: DecodeLimits,
        request: ImageRequest,
        format: EncodedImageFormat
    ) throws -> (any ImageProgressiveDecodeSession)? {
        guard descriptor.capabilities.progressiveFormats.contains(format),
            let progressive = codec as? any ProgressiveImageDecoding
        else { return nil }
        return try progressive.makeProgressiveSession(
            format: format,
            request: FoveaCodecAdmission.decodeRequest(for: request),
            limits: limits
        )
    }

    package static func append(
        _ chunk: Data,
        to session: any ImageProgressiveDecodeSession,
        request: ImageRequest,
        limits: DecodeLimits,
        maximumResidentBytes: Int,
        executor: DispatchWorkExecutor
    ) async throws -> ImageProgressiveDecodeGeneration? {
        try Task.checkCancellation()
        let generation = try await executor.run {
            try session.append(chunk)
        }
        try Task.checkCancellation()
        if let generation {
            try FoveaCodecOutputContract.validateProgressive(
                generation.image,
                request: FoveaCodecAdmission.decodeRequest(for: request),
                limits: limits,
                maximumResidentBytes: maximumResidentBytes
            )
        }
        return generation
    }

    package static func finish(
        _ session: any ImageProgressiveDecodeSession,
        executor: DispatchWorkExecutor
    ) async throws {
        try Task.checkCancellation()
        try await executor.run {
            try session.finish()
        }
    }

    package static func finishWithPreparation(
        _ session: any ProgressiveImagePreparingSession,
        executor: DispatchWorkExecutor
    ) async throws -> ImageProgressiveDecodePreparationFinalization {
        try Task.checkCancellation()
        let finalization = try await executor.run {
            try session.finishWithPreparation()
        }
        try Task.checkCancellation()
        return finalization
    }

    package static func discardPreparation(
        _ preparation: ImageDecodePreparation,
        codec: any ImageCodec,
        executor: DispatchWorkExecutor
    ) async {
        guard let preparedDecoder = codec as? any PreparedImageDecoding else { return }
        _ = try? await executor.run {
            preparedDecoder.discard(preparation)
        }
    }

}
