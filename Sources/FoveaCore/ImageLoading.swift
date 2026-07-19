import Foundation
import ImageCraftCore

public protocol ImageLoading: Sendable {
  func image(for request: ImageRequest) async throws -> DecodedImage
}

public protocol EncodedDataLoading: Sendable {
  /// 返回仍在有效期内且已验证缓存中的原编码字节，或执行一次不持久化的新网络获取。
  /// 该入口忽略几何与颜色策略，且不触发容器探测或像素解码。
  func encodedData(for request: ImageRequest) async throws -> Data
}

public enum ImageLoadingEvent: Sendable {
  case preview(DecodedImage, quality: UInt16)
  case final(DecodedImage)
}

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
