import Foundation
import ImageCraftCore

public struct PipelineConfiguration: Codable, Hashable, Sendable {
  public static let currentSchemaVersion: UInt16 = 1

  public let schemaVersion: UInt16
  public let memoryCostLimit: Int
  public let decodeLimits: DecodeLimits
  public let transportRetryPolicy: TransportRetryPolicy
  public let staleFallbackPolicy: StaleFallbackPolicy
  public let maximumTransportBytes: Int
  public let transportMemoryThreshold: Int
  public let maximumConcurrentFetches: Int
  public let maximumConcurrentDecodes: Int
  public let maximumDecodeWorkingSetBytes: Int
  public let maximumQueuedFetches: Int
  public let maximumQueuedDecodes: Int

  public init(
    schemaVersion: UInt16 = PipelineConfiguration.currentSchemaVersion,
    memoryCostLimit: Int = 64 * 1024 * 1024,
    decodeLimits: DecodeLimits = .coreV1,
    transportRetryPolicy: TransportRetryPolicy = .coreV1,
    staleFallbackPolicy: StaleFallbackPolicy = .disabled,
    maximumTransportBytes: Int = 64 * 1024 * 1024,
    transportMemoryThreshold: Int = 512 * 1024,
    maximumConcurrentFetches: Int = 6,
    maximumConcurrentDecodes: Int = 2,
    maximumDecodeWorkingSetBytes: Int = 192 * 1024 * 1024,
    maximumQueuedFetches: Int = 512,
    maximumQueuedDecodes: Int = 512
  ) {
    self.schemaVersion = schemaVersion
    self.memoryCostLimit = max(1, memoryCostLimit)
    self.decodeLimits = decodeLimits
    self.transportRetryPolicy = transportRetryPolicy
    self.staleFallbackPolicy = staleFallbackPolicy
    self.maximumTransportBytes = max(1, maximumTransportBytes)
    self.transportMemoryThreshold = max(1, min(transportMemoryThreshold, maximumTransportBytes))
    self.maximumConcurrentFetches = max(1, maximumConcurrentFetches)
    self.maximumConcurrentDecodes = max(1, maximumConcurrentDecodes)
    self.maximumDecodeWorkingSetBytes = max(1, maximumDecodeWorkingSetBytes)
    self.maximumQueuedFetches = max(0, maximumQueuedFetches)
    self.maximumQueuedDecodes = max(0, maximumQueuedDecodes)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case memoryCostLimit
    case decodeLimits
    case transportRetryPolicy
    case staleFallbackPolicy
    case maximumTransportBytes
    case transportMemoryThreshold
    case maximumConcurrentFetches
    case maximumConcurrentDecodes
    case maximumDecodeWorkingSetBytes
    case maximumQueuedFetches
    case maximumQueuedDecodes
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schemaVersion: try values.decode(UInt16.self, forKey: .schemaVersion),
      memoryCostLimit: try values.decode(Int.self, forKey: .memoryCostLimit),
      decodeLimits: try values.decode(DecodeLimits.self, forKey: .decodeLimits),
      transportRetryPolicy: try values.decode(
        TransportRetryPolicy.self, forKey: .transportRetryPolicy),
      staleFallbackPolicy: try values.decode(
        StaleFallbackPolicy.self, forKey: .staleFallbackPolicy),
      maximumTransportBytes: try values.decode(Int.self, forKey: .maximumTransportBytes),
      transportMemoryThreshold: try values.decode(Int.self, forKey: .transportMemoryThreshold),
      maximumConcurrentFetches: try values.decode(Int.self, forKey: .maximumConcurrentFetches),
      maximumConcurrentDecodes: try values.decode(Int.self, forKey: .maximumConcurrentDecodes),
      maximumDecodeWorkingSetBytes: try values.decodeIfPresent(
        Int.self,
        forKey: .maximumDecodeWorkingSetBytes
      ) ?? 192 * 1024 * 1024,
      maximumQueuedFetches: try values.decode(Int.self, forKey: .maximumQueuedFetches),
      maximumQueuedDecodes: try values.decode(Int.self, forKey: .maximumQueuedDecodes)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(schemaVersion, forKey: .schemaVersion)
    try values.encode(memoryCostLimit, forKey: .memoryCostLimit)
    try values.encode(decodeLimits, forKey: .decodeLimits)
    try values.encode(transportRetryPolicy, forKey: .transportRetryPolicy)
    try values.encode(staleFallbackPolicy, forKey: .staleFallbackPolicy)
    try values.encode(maximumTransportBytes, forKey: .maximumTransportBytes)
    try values.encode(transportMemoryThreshold, forKey: .transportMemoryThreshold)
    try values.encode(maximumConcurrentFetches, forKey: .maximumConcurrentFetches)
    try values.encode(maximumConcurrentDecodes, forKey: .maximumConcurrentDecodes)
    try values.encode(maximumDecodeWorkingSetBytes, forKey: .maximumDecodeWorkingSetBytes)
    try values.encode(maximumQueuedFetches, forKey: .maximumQueuedFetches)
    try values.encode(maximumQueuedDecodes, forKey: .maximumQueuedDecodes)
  }

  public var semanticFingerprint: String {
    fingerprint(domain: "pipeline-semantic-v1", fields: semanticFields)
  }

  public var fullFingerprint: String {
    fingerprint(domain: "pipeline-full-v1", fields: semanticFields + operationalFields)
  }

  package var transportPolicyFingerprint: String {
    fingerprint(
      domain: "transport-policy-v1",
      fields: [
        transportRetryPolicy.fingerprint,
        "maximumTransportBytes:\(maximumTransportBytes)",
        "staleFallback.enabled:\(staleFallbackPolicy.isEnabled)",
        "staleFallback.maximumSeconds:\(staleFallbackPolicy.maximumStalenessSeconds)",
      ]
    )
  }

  private var semanticFields: [String] {
    [
      "schemaVersion:\(schemaVersion)",
      "decode.maximumEncodedBytes:\(decodeLimits.maximumEncodedBytes)",
      "decode.maximumDimension:\(decodeLimits.maximumDimension)",
      "decode.maximumPixelCount:\(decodeLimits.maximumPixelCount)",
      "decode.maximumFrameCount:\(decodeLimits.maximumFrameCount)",
      "decode.maximumMetadataBytes:\(decodeLimits.maximumMetadataBytes)",
      "decode.maximumAuxiliaryAttachments:\(decodeLimits.maximumAuxiliaryAttachments)",
      "decode.allowedFormats:\(decodeLimits.allowedFormats.map(\.rawValue).sorted().joined(separator: ","))",
      "maximumTransportBytes:\(maximumTransportBytes)",
    ]
  }

  private var operationalFields: [String] {
    [
      "memoryCostLimit:\(memoryCostLimit)",
      "transportMemoryThreshold:\(transportMemoryThreshold)",
      "maximumConcurrentFetches:\(maximumConcurrentFetches)",
      "maximumConcurrentDecodes:\(maximumConcurrentDecodes)",
      "maximumDecodeWorkingSetBytes:\(maximumDecodeWorkingSetBytes)",
      "maximumQueuedFetches:\(maximumQueuedFetches)",
      "maximumQueuedDecodes:\(maximumQueuedDecodes)",
      "retry:\(transportRetryPolicy.fingerprint)",
    ]
  }

  private func fingerprint(domain: String, fields: [String]) -> String {
    var data = Data(domain.utf8)
    data.append(0)
    for field in fields {
      data.append(contentsOf: field.utf8)
      data.append(0)
    }
    return data.sha256Hex
  }
}
