import ImageCraftCore

public protocol ImageLoading: Sendable {
  func image(for request: ImageRequest) async throws -> DecodedImage
}
