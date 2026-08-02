import ImageCraftCore

/// 转换解码图像，并提供稳定的转换身份。
public protocol ImageTransforming: Sendable {
    /// 参与渲染缓存键计算的稳定转换身份。
    nonisolated var fingerprint: String { get }
    /// 生成不可变转换图像；失败时抛错且不发布结果。
    func transform(_ image: DecodedImage) async throws -> DecodedImage
}

/// 原样返回输入图像的转换器。

public struct IdentityImageTransformer: ImageTransforming {
    /// 恒等转换的稳定指纹。
    public nonisolated let fingerprint = "identity-transform-v1"

    /// 创建无状态恒等转换器。
    public init() {}

    /// 不进行额外分配，直接返回原始不可变图像。
    public func transform(_ image: DecodedImage) async throws -> DecodedImage {
        image
    }
}
