import Foundation
import ImageCraftCore

/// 为已验证的 ``ImageRequest`` 加载最终解码图像。

public protocol ImageLoading: Sendable {
    func image(for request: ImageRequest) async throws -> DecodedImage
}

/// 撤销加载器拥有的全部命名空间级进行中状态与可复用状态。
public protocol NamespaceRevoking: Sendable {
    func revoke(namespace: SecurityNamespaceID) async throws
}

/// 加载已验证编码字节，但不为显示执行解码。
public protocol EncodedDataLoading: Sendable {
    /// 返回仍在有效期内且已验证缓存中的原编码字节，或执行一次不持久化的新网络获取。
    /// 该入口忽略几何与颜色策略，且不触发容器探测或像素解码。
    func encodedData(for request: ImageRequest) async throws -> Data
}

/// 包含预览图或最终图的渐进图像加载事件。

public enum ImageLoadingEvent: Sendable {
    case preview(DecodedImage, quality: UInt16)
    case final(DecodedImage)
}

/// loader 可实现的渐进事件能力。
///
/// 生产 `FoveaPipeline` 在最终质量像素完成验证、目标解码、变换与命名空间围栏后，
/// 可先发送 `UInt16.max` preview；持久化发布完成后再发送 final。自定义 loader 也可
/// 发送多个质量严格上升的 preview，UI 适配层只消费显式提供此能力的 loader。
public protocol ProgressiveImageLoading: ImageLoading {
    func events(for request: ImageRequest) -> AsyncThrowingStream<ImageLoadingEvent, Error>
}

extension ProgressiveImageLoading {
    public func image(for request: ImageRequest) async throws -> DecodedImage {
        for try await event in events(for: request) {
            if case .final(let image) = event { return image }
        }
        throw PipelineFailure.incompleteProgressiveStream
    }
}
