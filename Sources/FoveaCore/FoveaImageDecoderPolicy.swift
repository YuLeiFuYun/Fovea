import ImageCraftCore

extension ImageCodecCapabilities {
    /// Fovea 对未声明插件能力的旧 decoder 使用的最小保守能力面。
    package static let foveaLegacyBaseline = ImageCodecCapabilities(
        formats: Set(EncodedImageFormat.allCases),
        deliveryModes: [.completeFrame],
        trackModes: [.primaryFrame],
        metadata: [.orientation, .sourceColorProfile],
        dynamicRanges: [.standard],
        outputRepresentations: [.coreGraphicsImage],
        cancellationMode: .operationBoundary
    )
}

/// Fovea 对未采用完整 `ImageCodec` 契约的旧 decoder 使用的宿主兼容策略。
extension ImageDecoding {
    package var pipelineCodecDescriptor: ImageCodecDescriptor {
        if let provider = self as? any ImageCodec {
            return provider.codecDescriptor
        }
        return ImageCodecDescriptor(
            identifier: ImageCodecIdentifier(
                rawValue: "legacy:\(String(reflecting: type(of: self)))"
            ),
            implementationVersion: 1,
            capabilities: .foveaLegacyBaseline
        )
    }

    package func pipelineResourceEstimate(
        probe: ImageProbe,
        request: ImageDecodeRequest
    ) throws -> ImageDecodeResourceEstimate {
        if let provider = self as? any ImageCodec {
            return try provider.resourceEstimate(probe: probe, request: request)
        }
        return try ImageDecodeResourceEstimate(
            workingSetBytes: FoveaDecodeWorkingSetEstimator.estimatedBytes(
                probe: probe,
                request: request
            )
        )
    }
}
