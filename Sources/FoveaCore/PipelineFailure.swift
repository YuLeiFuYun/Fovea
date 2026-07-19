import Foundation
import FoveaHTTP
import ImageCraftCore

public struct PipelineFailure: Error, Equatable, Hashable, Codable, Sendable {
  public enum Category: String, Codable, Sendable {
    case authorization
    case transport
    case http
    case securityLimit
    case securityPolicy
    case resourceLimit
    case namespaceRevoked
    case cacheRead
    case cacheWrite
    case probe
    case decode
    case transform
    case cancelled
    case internalFailure
  }

  public enum Stage: String, Codable, Sendable {
    case requestValidation
    case cacheLookup
    case transport
    case responseValidation
    case probe
    case decode
    case transform
    case persistence
    case revocation
    case pipeline
  }

  public enum Disposition: String, Codable, Sendable {
    case terminal
    case retryable
    case cacheDegraded
    case cancelled
  }

  public let category: Category
  public let stage: Stage
  public let disposition: Disposition
  public let reasonCode: String
  public let statusCode: Int?

  public init(
    category: Category,
    stage: Stage,
    disposition: Disposition,
    reasonCode: String,
    statusCode: Int? = nil
  ) {
    self.category = category
    self.stage = stage
    self.disposition = disposition
    self.reasonCode = reasonCode
    self.statusCode = statusCode
  }

  static func authorization(reasonCode: String) -> PipelineFailure {
    PipelineFailure(
      category: .authorization,
      stage: .requestValidation,
      disposition: .terminal,
      reasonCode: reasonCode
    )
  }

  static let profileAccessDenied = PipelineFailure(
    category: .authorization,
    stage: .requestValidation,
    disposition: .terminal,
    reasonCode: "profile-access-denied"
  )

  static let missingAuthorizationContext = PipelineFailure(
    category: .authorization,
    stage: .requestValidation,
    disposition: .terminal,
    reasonCode: "missing-authorization-context"
  )

  static let namespaceRevoked = PipelineFailure(
    category: .namespaceRevoked,
    stage: .revocation,
    disposition: .terminal,
    reasonCode: "namespace-revoked"
  )

  static let namespaceCleanupFailed = PipelineFailure(
    category: .cacheWrite,
    stage: .revocation,
    disposition: .cacheDegraded,
    reasonCode: "namespace-cleanup-failed"
  )

  static let cacheMaintenanceUnavailable = PipelineFailure(
    category: .cacheWrite,
    stage: .persistence,
    disposition: .terminal,
    reasonCode: "cache-maintenance-unavailable"
  )

  static let onlyIfCachedMiss = PipelineFailure(
    category: .cacheRead,
    stage: .cacheLookup,
    disposition: .terminal,
    reasonCode: "only-if-cached-miss"
  )

  static let missingCachedBody = PipelineFailure(
    category: .cacheRead,
    stage: .cacheLookup,
    disposition: .terminal,
    reasonCode: "validated-record-missing-body"
  )

  static let nonImageResponse = PipelineFailure(
    category: .http,
    stage: .responseValidation,
    disposition: .terminal,
    reasonCode: "non-image-response"
  )

  static func unsupportedStatus(_ statusCode: Int) -> PipelineFailure {
    let retryable =
      statusCode == 408 || statusCode == 425 || statusCode == 429 || 500...599 ~= statusCode
    return PipelineFailure(
      category: .http,
      stage: .responseValidation,
      disposition: retryable ? .retryable : .terminal,
      reasonCode: "unsupported-http-status",
      statusCode: statusCode
    )
  }

  static func resourceLimit(stage: Stage, reasonCode: String) -> PipelineFailure {
    PipelineFailure(
      category: .resourceLimit,
      stage: stage,
      disposition: .terminal,
      reasonCode: reasonCode
    )
  }

  static func cancelled(stage: Stage) -> PipelineFailure {
    PipelineFailure(
      category: .cancelled,
      stage: stage,
      disposition: .cancelled,
      reasonCode: "cancelled"
    )
  }

  public static let incompleteProgressiveStream = PipelineFailure(
    category: .internalFailure,
    stage: .pipeline,
    disposition: .terminal,
    reasonCode: "progressive-stream-ended-without-final"
  )

  static let transformFailed = PipelineFailure(
    category: .transform,
    stage: .transform,
    disposition: .terminal,
    reasonCode: "transform-failed"
  )

  static let invalidContentDigest = PipelineFailure(
    category: .transport,
    stage: .transport,
    disposition: .terminal,
    reasonCode: "invalid-content-digest"
  )

  package static func transport(_ error: any Error) -> PipelineFailure {
    if let transportError = error as? TransportError {
      switch transportError {
      case .bodyTooLarge:
        return PipelineFailure(
          category: .securityLimit,
          stage: .transport,
          disposition: .terminal,
          reasonCode: "encoded-body-limit-exceeded"
        )
      case .invalidContentLength:
        return PipelineFailure(
          category: .http,
          stage: .responseValidation,
          disposition: .terminal,
          reasonCode: "invalid-content-length"
        )
      case .incompleteBody:
        return PipelineFailure(
          category: .transport,
          stage: .transport,
          disposition: .retryable,
          reasonCode: "incomplete-response-body"
        )
      case .nonHTTPResponse:
        return PipelineFailure(
          category: .http,
          stage: .transport,
          disposition: .terminal,
          reasonCode: "non-http-response"
        )
      case .insecureRedirect:
        return PipelineFailure(
          category: .securityPolicy,
          stage: .transport,
          disposition: .terminal,
          reasonCode: "insecure-redirect"
        )
      }
    }

    if let urlError = error as? URLError {
      if urlError.code == .cancelled { return cancelled(stage: .transport) }
      let retryableCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .networkConnectionLost,
        .dnsLookupFailed,
        .notConnectedToInternet,
        .resourceUnavailable,
        .backgroundSessionWasDisconnected,
      ]
      return PipelineFailure(
        category: .transport,
        stage: .transport,
        disposition: retryableCodes.contains(urlError.code) ? .retryable : .terminal,
        reasonCode: retryableCodes.contains(urlError.code)
          ? "url-session-transport"
          : "url-session-terminal"
      )
    }

    return PipelineFailure(
      category: .transport,
      stage: .transport,
      disposition: .terminal,
      reasonCode: "unclassified-transport-failure"
    )
  }

  package static func imageCraft(_ error: any Error, stage: Stage) -> PipelineFailure {
    guard let imageError = error as? ImageCraftError else {
      return PipelineFailure(
        category: stage == .probe ? .probe : .decode,
        stage: stage,
        disposition: .terminal,
        reasonCode: stage == .probe ? "probe-failure" : "decode-failure"
      )
    }

    switch imageError {
    case .invalidTarget:
      return PipelineFailure(
        category: .securityLimit,
        stage: .requestValidation,
        disposition: .terminal,
        reasonCode: "invalid-target-pixels"
      )
    case .targetLimitExceeded:
      return PipelineFailure(
        category: .securityLimit,
        stage: .requestValidation,
        disposition: .terminal,
        reasonCode: "target-limit-exceeded"
      )
    case .encodedBytesExceeded:
      return PipelineFailure(
        category: .securityLimit,
        stage: stage,
        disposition: .terminal,
        reasonCode: "encoded-bytes-limit-exceeded"
      )
    case .unsupportedFormat:
      return PipelineFailure(
        category: .securityLimit,
        stage: .probe,
        disposition: .terminal,
        reasonCode: "unsupported-image-format"
      )
    case .formatMismatch:
      return PipelineFailure(
        category: .securityLimit,
        stage: .probe,
        disposition: .terminal,
        reasonCode: "container-format-mismatch"
      )
    case .metadataLimitExceeded:
      return PipelineFailure(
        category: .securityLimit,
        stage: .probe,
        disposition: .terminal,
        reasonCode: "metadata-limit-exceeded"
      )
    case .auxiliaryAttachmentLimitExceeded:
      return PipelineFailure(
        category: .securityLimit,
        stage: .probe,
        disposition: .terminal,
        reasonCode: "auxiliary-attachment-limit-exceeded"
      )
    case .dimensionLimitExceeded:
      return PipelineFailure(
        category: .securityLimit,
        stage: stage,
        disposition: .terminal,
        reasonCode: "dimension-limit-exceeded"
      )
    case .pixelLimitExceeded:
      return PipelineFailure(
        category: .securityLimit,
        stage: stage,
        disposition: .terminal,
        reasonCode: "pixel-limit-exceeded"
      )
    case .frameLimitExceeded:
      return PipelineFailure(
        category: .securityLimit,
        stage: stage,
        disposition: .terminal,
        reasonCode: "frame-limit-exceeded"
      )
    case .unsupportedOrCorruptImage:
      return PipelineFailure(
        category: .probe,
        stage: .probe,
        disposition: .terminal,
        reasonCode: "unsupported-or-corrupt-image"
      )
    case .probeMismatch:
      return PipelineFailure(
        category: .probe,
        stage: .probe,
        disposition: .terminal,
        reasonCode: "probe-does-not-match-bitstream"
      )
    case .decodeFailed:
      return PipelineFailure(
        category: .decode,
        stage: .decode,
        disposition: .terminal,
        reasonCode: "decode-failed"
      )
    }
  }

  static func internalFailure(stage: Stage) -> PipelineFailure {
    PipelineFailure(
      category: .internalFailure,
      stage: stage,
      disposition: .terminal,
      reasonCode: "internal-failure"
    )
  }
}
