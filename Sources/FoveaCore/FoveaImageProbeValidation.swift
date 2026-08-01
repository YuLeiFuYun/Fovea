import ImageCraftCore

/// Fovea 在信任 codec 输出前独立重验探测事实，不能依赖组件包的 package-only validator。
extension ImageProbe {
    package func validateForFovea(under limits: DecodeLimits) throws {
        guard limits.allowedFormats.contains(format) else {
            throw ImageCraftError.unsupportedFormat
        }
        guard pixelWidth <= limits.maximumDimension, pixelHeight <= limits.maximumDimension else {
            throw ImageCraftError.dimensionLimitExceeded
        }
        let pixels = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !pixels.overflow, pixels.partialValue <= limits.maximumPixelCount else {
            throw ImageCraftError.pixelLimitExceeded
        }
        guard frameCount <= limits.maximumFrameCount else {
            throw ImageCraftError.frameLimitExceeded
        }
        guard metadataByteCount <= limits.maximumMetadataBytes else {
            throw ImageCraftError.metadataLimitExceeded
        }
        guard auxiliaryAttachmentCount <= limits.maximumAuxiliaryAttachments else {
            throw ImageCraftError.auxiliaryAttachmentLimitExceeded
        }
    }
}
