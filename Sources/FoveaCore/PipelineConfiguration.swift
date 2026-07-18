import ImageCraftCore

public struct PipelineConfiguration: Sendable {
  public let decodeLimits: DecodeLimits
  public let maximumTransportBytes: Int
  public let transportMemoryThreshold: Int

  public init(
    decodeLimits: DecodeLimits = .phase0a,
    maximumTransportBytes: Int = 64 * 1024 * 1024,
    transportMemoryThreshold: Int = 512 * 1024
  ) {
    self.decodeLimits = decodeLimits
    self.maximumTransportBytes = max(1, maximumTransportBytes)
    self.transportMemoryThreshold = max(1, min(transportMemoryThreshold, maximumTransportBytes))
  }
}
