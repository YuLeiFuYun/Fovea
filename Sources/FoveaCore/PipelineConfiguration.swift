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
    self.maximumQueuedFetches = max(0, maximumQueuedFetches)
    self.maximumQueuedDecodes = max(0, maximumQueuedDecodes)
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
