public protocol ImageTransforming: Sendable {
  nonisolated var fingerprint: String { get }
  func transform(_ image: DecodedImage) async throws -> DecodedImage
}

public struct IdentityImageTransformer: ImageTransforming {
  public nonisolated let fingerprint = "identity-transform-v1"

  public init() {}

  public func transform(_ image: DecodedImage) async throws -> DecodedImage {
    image
  }
}
