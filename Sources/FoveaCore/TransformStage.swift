import Foundation
import ImageCraftCore

/// 对变换器增加稳定指纹、取消语义和变换后资源上限，形成独立管线阶段。
/// 即使自定义变换器返回“成功”，输出尺寸、像素数和估算内存仍必须重新验证。
package struct TransformStage: Sendable {
    package nonisolated let fingerprint: String
    private let transformer: any ImageTransforming
    private let limits: DecodeLimits
    private let maximumOutputBytes: Int

    package init(
        transformer: any ImageTransforming,
        limits: DecodeLimits,
        maximumOutputBytes: Int
    ) {
        self.transformer = transformer
        self.limits = limits
        self.maximumOutputBytes = max(1, maximumOutputBytes)
        self.fingerprint =
            Data(
                "fovea-transform-fingerprint-v1\0\(transformer.fingerprint)".utf8
            ).sha256Hex
    }

    package func image(from decoded: DecodedImage) async throws -> DecodedImage {
        do {
            let image = try await transformer.transform(decoded)
            try validate(image)
            return image
        } catch is CancellationError {
            throw PipelineFailure.cancelled(stage: .transform)
        } catch let failure as PipelineFailure {
            throw failure
        } catch {
            throw PipelineFailure.transformFailed
        }
    }

    private func validate(_ image: DecodedImage) throws {
        guard image.pixelWidth > 0, image.pixelHeight > 0,
            image.pixelWidth <= limits.maximumDimension,
            image.pixelHeight <= limits.maximumDimension
        else {
            throw PipelineFailure.resourceLimit(
                stage: .transform,
                reasonCode: "transform-output-limit-exceeded"
            )
        }
        let pixels = image.pixelWidth.multipliedReportingOverflow(by: image.pixelHeight)
        guard !pixels.overflow,
            pixels.partialValue <= limits.maximumPixelCount,
            image.estimatedByteCost > 0,
            image.estimatedByteCost <= maximumOutputBytes
        else {
            throw PipelineFailure.resourceLimit(
                stage: .transform,
                reasonCode: "transform-output-limit-exceeded"
            )
        }
    }
}
