import ImageCraftCore

public struct PipelineConfiguration: Sendable {
  public let decodeLimits: DecodeLimits
  public let maximumTransportBytes: Int
  public let transportMemoryThreshold: Int
  public let maximumConcurrentFetches: Int
  public let maximumConcurrentDecodes: Int
  public let maximumQueuedFetches: Int
  public let maximumQueuedDecodes: Int

  public init(
    decodeLimits: DecodeLimits = .phase0a,
    maximumTransportBytes: Int = 64 * 1024 * 1024,
    transportMemoryThreshold: Int = 512 * 1024,
    maximumConcurrentFetches: Int = 6,
    maximumConcurrentDecodes: Int = 2,
    maximumQueuedFetches: Int = 512,
    maximumQueuedDecodes: Int = 512
  ) {
    self.decodeLimits = decodeLimits
    self.maximumTransportBytes = max(1, maximumTransportBytes)
    self.transportMemoryThreshold = max(1, min(transportMemoryThreshold, maximumTransportBytes))
    self.maximumConcurrentFetches = max(1, maximumConcurrentFetches)
    self.maximumConcurrentDecodes = max(1, maximumConcurrentDecodes)
    self.maximumQueuedFetches = max(0, maximumQueuedFetches)
    self.maximumQueuedDecodes = max(0, maximumQueuedDecodes)
  }
}
